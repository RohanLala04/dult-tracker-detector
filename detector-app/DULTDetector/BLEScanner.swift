import Foundation
import CoreBluetooth

/// Scans for nearby Bluetooth LE devices and maintains a live, observable
/// collection of `DiscoveredDevice` records for the dashboard.
///
/// Note: Core Bluetooth never exposes a device's real MAC address. The
/// `peripheral.identifier` UUID used as the device key is a randomized,
/// per-session identifier assigned by macOS.
final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {

    /// The DULT location-enabled advertisement service UUID (spec section 3.6).
    static let dultServiceUUID = CBUUID(string: "FCB2")

    /// Core Bluetooth reports +127 when it could not read a valid RSSI.
    private static let invalidRSSI = 127

    // Published values drive the SwiftUI dashboard; refreshed once per
    // flushInterval rather than per advertisement to keep the UI smooth.
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var advertisementCount = 0
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage = "Starting Bluetooth..."

    private var central: CBCentralManager!
    /// Persists every sighting; this is the dataset the ML pipeline trains on.
    let database = DatabaseManager()
    private var coTravelDetector: CoTravelDetector?
    /// Latest co-travel verdicts, keyed by peripheral UUID string (main queue).
    private var followerFlags: [String: FollowerFlag] = [:]
    /// Working state, mutated on every advertisement (main queue).
    private var deviceMap: [UUID: DiscoveredDevice] = [:]
    private var receivedCount = 0
    private var flushTimer: Timer?
    private let flushInterval: TimeInterval = 1.0

    override init() {
        super.init()
        // Passing queue: nil delivers delegate callbacks on the main queue,
        // which keeps all state access and @Published updates thread-safe.
        central = CBCentralManager(delegate: self, queue: nil)
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        let detector = CoTravelDetector(database: database)
        detector.onUpdate = { [weak self] flags in
            self?.followerFlags = flags
            self?.flush()
        }
        detector.start()
        coTravelDetector = detector
    }

    deinit {
        flushTimer?.invalidate()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusMessage = "Scanning"
            startScan()
        case .poweredOff:
            stopScan(status: "Bluetooth is off - turn it on in System Settings > Bluetooth")
        case .unauthorized:
            stopScan(status: "Permission denied - allow in System Settings > Privacy & Security > Bluetooth")
        case .unsupported:
            stopScan(status: "This Mac does not support Bluetooth LE")
        case .resetting:
            stopScan(status: "Bluetooth is resetting - waiting...")
        case .unknown:
            stopScan(status: "Bluetooth state unknown - waiting...")
        @unknown default:
            stopScan(status: "Unrecognized Bluetooth state (\(central.state.rawValue))")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        receivedCount += 1
        let now = Date()
        let rssiValue = RSSI.intValue
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        // Parse the DULT payload if this advertisement carries 0xFCB2 service
        // data. DULTStatus.init returns nil for empty (unparseable) data.
        let dultStatus = serviceData?[Self.dultServiceUUID].flatMap(DULTStatus.init(serviceData:))

        database.insertSighting(
            peripheralUUID: peripheral.identifier.uuidString,
            rssi: rssiValue,
            timestamp: now,
            isDULT: dultStatus != nil,
            nearOwnerBit: dultStatus?.isNearOwner.map { $0 ? 1 : 0 },
            networkID: dultStatus.map { Int($0.networkIDByte) },
            rawPayload: dultStatus?.rawServiceData
        )

        if var device = deviceMap[peripheral.identifier] {
            if rssiValue != Self.invalidRSSI {
                device.rssi = rssiValue
            }
            device.lastSeen = now
            device.sightingCount += 1
            if let name { device.name = name }
            // Latest DULT status wins (the near-owner bit changes over time);
            // ads without DULT data leave the previous status in place.
            if let dultStatus { device.dult = dultStatus }
            deviceMap[peripheral.identifier] = device
        } else {
            deviceMap[peripheral.identifier] = DiscoveredDevice(
                id: peripheral.identifier,
                name: name,
                rssi: rssiValue == Self.invalidRSSI ? -100 : rssiValue,
                firstSeen: now,
                lastSeen: now,
                sightingCount: 1,
                dult: dultStatus
            )
        }
    }

    // MARK: - Scanning

    private func startScan() {
        guard central.state == .poweredOn else { return }
        // Scan for ALL devices (withServices: nil) so we can see everything
        // nearby. Allow duplicates so RSSI and last-seen keep updating live.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
    }

    private func stopScan(status: String) {
        if central.isScanning {
            central.stopScan()
        }
        isScanning = false
        statusMessage = status
    }

    /// Pushes the working state to the published properties (once per second).
    private func flush() {
        devices = deviceMap.values.map { device in
            var device = device
            device.followerFlag = followerFlags[device.id.uuidString]
            return device
        }
        advertisementCount = receivedCount
    }
}
