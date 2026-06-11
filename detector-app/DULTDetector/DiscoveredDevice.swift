import Foundation

/// Parsed contents of a DULT location-enabled advertisement's service data
/// (docs/dult-spec.txt Table 1 and sections 3.7-3.9). Core Bluetooth strips
/// the TLV header and the 0xFCB2 UUID, so the Data it delivers starts at the
/// Network ID byte:
///   byte 0      Network ID (0x01 = Apple, 0x02 = Google, Table 24)
///   byte 1      status byte; near-owner bit is the LEAST significant bit
///               (1 = owner nearby, 0 = separated, Table 3)
///   bytes 2...  proprietary company payload (optional, variable length)
struct DULTStatus: Equatable {
    enum Network: Equatable {
        case apple
        case google
        case unknown(UInt8)

        var displayName: String {
            switch self {
            case .apple: return "Apple"
            case .google: return "Google"
            case .unknown(let id): return String(format: "Unknown (0x%02X)", id)
            }
        }
    }

    /// Which service UUID carried the payload. A test beacon (0xFC99) is
    /// parsed and treated identically to a real DULT advertisement; the
    /// distinction exists only so the UI can label it. The test UUID is a
    /// workaround for Android stripping 0xFCB2 from app advertisements.
    enum Source: Equatable {
        case dult        // 0xFCB2 - a real DULT tracker
        case testBeacon  // 0xFC99 - the project's emulator beacon

        var isTest: Bool { self == .testBeacon }
    }

    let network: Network
    /// nil when the advertisement was too short to include the status byte
    /// (non-compliant tracker, or a truncated advertisement).
    let isNearOwner: Bool?
    /// The full raw service data bytes, kept for logging and later features.
    let rawServiceData: Data
    let source: Source

    /// Fails only if the service data is completely empty.
    init?(serviceData: Data, source: Source) {
        let bytes = [UInt8](serviceData)
        guard let networkID = bytes.first else { return nil }
        switch networkID {
        case 0x01: network = .apple
        case 0x02: network = .google
        default: network = .unknown(networkID)
        }
        isNearOwner = bytes.count >= 2 ? (bytes[1] & 0x01) == 1 : nil
        rawServiceData = serviceData
        self.source = source
    }

    var rawHexString: String {
        rawServiceData.map { String(format: "%02X", $0) }.joined()
    }

    /// The raw network ID byte (always present - init fails on empty data).
    var networkIDByte: UInt8 {
        [UInt8](rawServiceData)[0]
    }
}

/// One nearby BLE device, accumulated across every advertisement heard from it.
/// Keyed by the peripheral UUID Core Bluetooth assigns for this session
/// (the real MAC address is never exposed by Core Bluetooth).
struct DiscoveredDevice: Identifiable {
    let id: UUID
    var name: String?
    /// Most recent valid RSSI in dBm (readings of +127 mean "invalid" and are skipped).
    var rssi: Int
    let firstSeen: Date
    var lastSeen: Date
    var sightingCount: Int
    /// Most recent parsed DULT payload, if the device has ever advertised
    /// the DULT service UUID 0xFCB2.
    var dult: DULTStatus?
    /// Latest co-travel assessment; nil until the device has been scored
    /// (assessments cover devices seen within the recency window).
    var assessment: FollowingAssessment? = nil

    var isDULT: Bool { dult != nil }
    /// True when the following probability is in the alert (red) band.
    var isFlagged: Bool {
        (assessment?.score ?? 0) > CoTravelDetector.alertThreshold
    }

    /// Key used to merge sightings across MAC rotations for co-travel
    /// detection. A DULT device is keyed by its service-data payload so
    /// rotated peripheral UUIDs collapse to one logical tracker; everything
    /// else is keyed by its peripheral UUID. Must match the `continuity_key`
    /// expression in DatabaseManager.deviceFeatures.
    var continuityKey: String {
        if let dult { return "p:" + dult.rawHexString }
        return "u:" + id.uuidString
    }
    /// True when the tracker reports it is away from its owner - the state
    /// that matters for unwanted-tracking detection.
    var isSeparated: Bool { dult?.isNearOwner == false }
}
