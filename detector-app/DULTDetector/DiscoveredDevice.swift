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

    let network: Network
    /// nil when the advertisement was too short to include the status byte
    /// (non-compliant tracker, or a truncated advertisement).
    let isNearOwner: Bool?
    /// The full raw service data bytes, kept for logging and later features.
    let rawServiceData: Data

    /// Fails only if the service data is completely empty.
    init?(serviceData: Data) {
        let bytes = [UInt8](serviceData)
        guard let networkID = bytes.first else { return nil }
        switch networkID {
        case 0x01: network = .apple
        case 0x02: network = .google
        default: network = .unknown(networkID)
        }
        isNearOwner = bytes.count >= 2 ? (bytes[1] & 0x01) == 1 : nil
        rawServiceData = serviceData
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
    /// Set while the co-travel heuristic considers this device a candidate
    /// follower; cleared automatically once it no longer qualifies.
    var followerFlag: FollowerFlag? = nil

    var isDULT: Bool { dult != nil }
    var isFlagged: Bool { followerFlag != nil }
    /// True when the tracker reports it is away from its owner - the state
    /// that matters for unwanted-tracking detection.
    var isSeparated: Bool { dult?.isNearOwner == false }
}
