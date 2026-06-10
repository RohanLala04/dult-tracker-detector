import Foundation

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
    /// True once the device has ever advertised the DULT service UUID 0xFCB2.
    var isDULT: Bool
}
