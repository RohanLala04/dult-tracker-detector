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
            // location_label uses its 'unknown' default until the location
            // feature exists, so it is not bound here.
            sqlite3_bind_int(statement, 4, isDULT ? 1 : 0)
            if let nearOwnerBit {
                sqlite3_bind_int(statement, 5, Int32(nearOwnerBit))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            if let networkID {
                sqlite3_bind_int(statement, 6, Int32(networkID))
            } else {
                sqlite3_bind_null(statement, 6)
            }
            if let rawPayload, !rawPayload.isEmpty {
                rawPayload.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, 7, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(statement, 7)
            }

            if sqlite3_step(statement) != SQLITE_DONE {
                print("[DatabaseManager] insert failed: \(self.lastErrorMessage())")
            }
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
                (peripheral_uuid, rssi, timestamp, is_dult, near_owner_bit, network_id, raw_payload)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite("prepare failed: \(lastErrorMessage())")
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
