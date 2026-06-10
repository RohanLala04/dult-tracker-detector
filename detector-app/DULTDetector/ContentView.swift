import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scanner: BLEScanner

    /// Strongest signal first; DULT count drives the header stat.
    private var sortedDevices: [DiscoveredDevice] {
        scanner.devices.sorted { $0.rssi > $1.rssi }
    }

    private var dultCount: Int {
        scanner.devices.filter(\.isDULT).count
    }

    private var flaggedDevices: [DiscoveredDevice] {
        sortedDevices.filter(\.isFlagged)
    }

    private var unflaggedDevices: [DiscoveredDevice] {
        sortedDevices.filter { !$0.isFlagged }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(Color.white.opacity(0.08))
            deviceList
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.14),
                         Color(red: 0.04, green: 0.04, blue: 0.06)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .frame(minWidth: 620, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DULT Detector")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(scanner.isScanning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(scanner.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statView(value: scanner.devices.count, label: "Devices")
            statView(value: scanner.advertisementCount, label: "Signals")
            statView(value: dultCount, label: "DULT", highlighted: dultCount > 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func statView(value: Int, label: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 52)
    }

    @ViewBuilder
    private var deviceList: some View {
        if sortedDevices.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Listening for nearby Bluetooth LE devices...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if !flaggedDevices.isEmpty {
                        sectionHeader("Alerts (\(flaggedDevices.count))",
                                      systemImage: "exclamationmark.triangle.fill",
                                      color: .red)
                        ForEach(flaggedDevices) { device in
                            DeviceCardView(device: device)
                        }
                        sectionHeader("All Devices",
                                      systemImage: "antenna.radiowaves.left.and.right",
                                      color: .secondary)
                    }
                    ForEach(unflaggedDevices) { device in
                        DeviceCardView(device: device)
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.45, dampingFraction: 0.85),
                           value: sortedDevices.map(\.id))
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEScanner())
}
