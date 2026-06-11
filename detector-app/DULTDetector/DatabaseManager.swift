import Foundation
import SQLite3

/// Tells SQLite to make its own copy of bound text/blob buffers, which is
/// required when passing Swift-managed memory.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Logs every BLE sighting to a SQLite database in the app's sandboxed
/// Application Support directory. This is the raw dataset the ML pipeline
/// will later train on, so one row = one received advertisement.
///
/// All database access is funneled through a serial queue: inserts are
/// fire-and-forget from the Bluetooth callback, reads block briefly.
final class DatabaseManager {

    /// Where the database lives, or nil if setup failed (status says why).
    private(set) var databaseURL: URL?
    private(set) var setupError: String?

    private var db: OpaquePointer?
    private var insertStatement: OpaquePointer?
    private let queue = DispatchQueue(label: "DULTDetector.database")

    init() {
        do {
            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("DULTDetector", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let url = supportDir.appendingPathComponent("sightings.sqlite")
            try openAndPrepare(at: url)
            deleteSimulatedRows()
            databaseURL = url
            print("[DatabaseManager] logging sightings to \(url.path)")
        } catch {
            setupError = "\(error)"
            print("[DatabaseManager] FAILED to set up database: \(error)")
        }
    }

    deinit {
        sqlite3_finalize(insertStatement)
        sqlite3_close(db)
    }

    /// Queues one sighting row; safe to call from the Core Bluetooth callback.
    func insertSighting(peripheralUUID: String,
                        rssi: Int,
                        timestamp: Date,
                        locationLabel: String,
                        isDULT: Bool,
                        nearOwnerBit: Int?,
                        networkID: Int?,
                        rawPayload: Data?) {
        queue.async { [self] in
            guard let statement = insertStatement else { return }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            sqlite3_bind_text(statement, 1, peripheralUUID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(rssi))
            sqlite3_bind_double(statement, 3, timestamp.timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, locationLabel, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 5, isDULT ? 1 : 0)
            if let nearOwnerBit {
                sqlite3_bind_int(statement, 6, Int32(nearOwnerBit))
            } else {
                sqlite3_bind_null(statement, 6)
            }
            if let networkID {
                sqlite3_bind_int(statement, 7, Int32(networkID))
            } else {
                sqlite3_bind_null(statement, 7)
            }
            if let rawPayload, !rawPayload.isEmpty {
                rawPayload.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, 8, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(statement, 8)
            }

            if sqlite3_step(statement) != SQLITE_DONE {
                print("[DatabaseManager] insert failed: \(self.lastErrorMessage())")
            }
        }
    }

    /// Computes the per-device feature vector for the co-travel classifier,
    /// covering devices seen within recencyWindow. Rows with RSSI 127
    /// (invalid readings) are excluded from the statistics.
    func deviceFeatures(recencyWindow: TimeInterval,
                        sessionStart: Date) -> [String: DeviceFeatures] {
        queue.sync {
            guard let db else { return [:] }
            let sql = """
                SELECT peripheral_uuid,
                       COUNT(*),
                       AVG(rssi),
                       AVG(rssi * rssi) - AVG(rssi) * AVG(rssi),
                       MIN(timestamp),
                       MAX(timestamp),
                       COUNT(DISTINCT location_label),
                       AVG(CASE WHEN near_owner_bit = 0 THEN 1.0 ELSE 0.0 END)
                FROM sightings
                WHERE rssi != 127
                GROUP BY peripheral_uuid
                HAVING MAX(timestamp) >= ?1;
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                print("[DatabaseManager] feature query prepare failed: \(lastErrorMessage())")
                return [:]
            }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970 - recencyWindow)

            let sessionStartTime = sessionStart.timeIntervalSince1970
            var features: [String: DeviceFeatures] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let uuidText = sqlite3_column_text(statement, 0) else { continue }
                let count = Int(sqlite3_column_int64(statement, 1))
                let first = sqlite3_column_double(statement, 4)
                let last = sqlite3_column_double(statement, 5)
                let duration = max(last - first, 0)
                features[String(cString: uuidText)] = DeviceFeatures(
                    rssiMean: sqlite3_column_double(statement, 2),
                    // Floating-point rounding can push tiny variances below 0.
                    rssiVariance: max(sqlite3_column_double(statement, 3), 0),
                    duration: duration,
                    distinctLocations: Int(sqlite3_column_int64(statement, 6)),
                    persistence: Double(count) / max(duration / 60.0, 1.0),
                    separatedRatio: sqlite3_column_double(statement, 7),
                    sightingCount: count,
                    firstSeen: Date(timeIntervalSince1970: first),
                    lastSeen: Date(timeIntervalSince1970: last),
                    sessionDuration: max(last - max(first, sessionStartTime), 0)
                )
            }
            return features
        }
    }

    /// Total rows logged so far (blocks until pending inserts finish).
    func sightingCount() -> Int? {
        queue.sync {
            guard let db else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sightings;", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - Setup

    private enum DatabaseError: Error {
        case sqlite(String)
    }

    private func openAndPrepare(at url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite("open failed: \(lastErrorMessage())")
        }

        // WAL keeps frequent small inserts fast and crash-safe.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS sightings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                peripheral_uuid TEXT NOT NULL,
                rssi INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                location_label TEXT NOT NULL DEFAULT 'unknown',
                is_dult INTEGER NOT NULL DEFAULT 0,
                near_owner_bit INTEGER,
                network_id INTEGER,
                raw_payload BLOB
            );
            """)

        let insertSQL = """
            INSERT INTO sightings
                (peripheral_uuid, rssi, timestamp, location_label, is_dult, near_owner_bit, network_id, raw_payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite("prepare failed: \(lastErrorMessage())")
        }
    }

    /// Removes simulated rows left by follower-detection testing so a fresh
    /// launch starts with only real sightings. Runs once at startup, before
    /// scanning begins; failures here are non-fatal.
    private func deleteSimulatedRows() {
        let sql = "DELETE FROM sightings WHERE location_label LIKE 'test-%';"
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                print("[DatabaseManager] removed \(deleted) simulated test rows")
            }
        } else {
            print("[DatabaseManager] simulated-row cleanup failed: \(lastErrorMessage())")
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite("exec failed for [\(sql)]: \(lastErrorMessage())")
        }
    }

    private func lastErrorMessage() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database handle"
    }
}
