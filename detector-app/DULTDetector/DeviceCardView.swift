import SwiftUI

/// One dashboard card for a discovered BLE device. Devices that have
/// advertised the DULT service (0xFCB2) get an accent highlight and shield.
struct DeviceCardView: View {
    let device: DiscoveredDevice

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.isDULT ? "shield.fill" : "dot.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(device.isDULT ? Color.accentColor : Color.secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(device.name ?? "Unknown Device")
                        .font(.headline)
                        .lineLimit(1)
                    if device.isDULT {
                        Text("DULT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text(device.id.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("First seen \(Self.timeFormatter.string(from: device.firstSeen))  ·  Last seen \(Self.timeFormatter.string(from: device.lastSeen))  ·  Seen \(device.sightingCount)×")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                SignalBarsView(rssi: device.rssi, accent: device.isDULT)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(device.rssi)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("dBm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(device.isDULT ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    device.isDULT ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08),
                    lineWidth: device.isDULT ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
    }
}

/// Three-bar signal strength indicator driven by RSSI.
/// Stronger than -60 dBm lights 3 bars, stronger than -75 lights 2, else 1.
struct SignalBarsView: View {
    let rssi: Int
    var accent = false

    private var litBars: Int {
        if rssi >= -60 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < litBars
                          ? (accent ? Color.accentColor : Color.green)
                          : Color.white.opacity(0.15))
                    .frame(width: 4, height: CGFloat(7 + index * 5))
            }
        }
        .animation(.easeOut(duration: 0.25), value: litBars)
    }
}

#Preview("Cards", traits: .fixedLayout(width: 560, height: 240)) {
    VStack(spacing: 10) {
        DeviceCardView(device: DiscoveredDevice(
            id: UUID(), name: nil, rssi: -48,
            firstSeen: .now.addingTimeInterval(-300), lastSeen: .now,
            sightingCount: 212, isDULT: true
        ))
        DeviceCardView(device: DiscoveredDevice(
            id: UUID(), name: "Living Room TV", rssi: -78,
            firstSeen: .now.addingTimeInterval(-1200), lastSeen: .now.addingTimeInterval(-4),
            sightingCount: 56, isDULT: false
        ))
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
