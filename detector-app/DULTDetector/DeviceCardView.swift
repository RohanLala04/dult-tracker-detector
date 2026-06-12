import SwiftUI

/// One dashboard card for a discovered BLE device. Devices advertising the
/// DULT service (0xFCB2) get a shield and an accent highlight; a DULT device
/// reporting "separated" (away from its owner) gets a warning color instead.
struct DeviceCardView: View {
    let device: DiscoveredDevice

    private static let warningColor = Color.orange

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    /// Color band for a following probability: green below the elevated
    /// threshold, amber up to the alert threshold, red above it.
    static func scoreColor(_ score: Double) -> Color {
        if score > CoTravelDetector.alertThreshold { return .red }
        if score >= CoTravelDetector.elevatedThreshold { return .orange }
        return .green
    }

    /// nil for ordinary devices; accent for near-owner DULT; warning for
    /// separated; the score band color once the probability is elevated.
    private var highlightColor: Color? {
        if let score = device.assessment?.score, score >= CoTravelDetector.elevatedThreshold {
            return Self.scoreColor(score)
        }
        guard device.isDULT else { return nil }
        return device.isSeparated ? Self.warningColor : Color.accentColor
    }

    var body: some View {
        VStack(spacing: 10) {
            if let assessment = device.assessment,
               assessment.score >= CoTravelDetector.elevatedThreshold {
                probabilityBanner(assessment)
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlightColor.map { $0.opacity(0.14) } ?? Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    highlightColor.map { $0.opacity(0.7) } ?? Color.white.opacity(0.08),
                    lineWidth: device.isDULT || device.isFlagged ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
    }

    private func probabilityBanner(_ assessment: FollowingAssessment) -> some View {
        // Score comes from the periodic co-travel assessment; the duration and
        // sighting count come from the live device so the banner keeps ticking
        // every refresh, including after the card turns red.
        let tracked = max(device.lastSeen.timeIntervalSince(device.firstSeen), 60)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Following: \(Self.percent(assessment.score))")
                .font(.caption.weight(.heavy))
                .kerning(0.5)
            Spacer()
            Text("Tracked \(Self.durationFormatter.string(from: tracked) ?? "-")  ·  Seen \(device.sightingCount)×")
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Self.scoreColor(assessment.score), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static func percent(_ score: Double) -> String {
        "\(Int((score * 100).rounded()))%"
    }

    private var content: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(highlightColor ?? Color.secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(device.name ?? "Unknown Device")
                        .font(.headline)
                        .lineLimit(1)
                    if let dult = device.dult {
                        badge("DULT", color: highlightColor ?? .accentColor)
                            .help("Raw DULT payload: \(dult.rawHexString)")
                        if dult.source.isTest {
                            chip("TEST")
                                .help("Emulator beacon on 0xFC99 (Android strips 0xFCB2)")
                        }
                        chip(dult.network.displayName)
                        statusChip(for: dult)
                        if let assessment = device.assessment,
                           assessment.score < CoTravelDetector.elevatedThreshold {
                            Text("Following: \(Self.percent(assessment.score))")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.18), in: Capsule())
                                .foregroundStyle(.green)
                        }
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
                SignalBarsView(rssi: device.rssi, litColor: highlightColor ?? .green)
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
    }

    private var iconName: String {
        if device.isFlagged || device.isSeparated { return "exclamationmark.shield.fill" }
        if device.isDULT { return "shield.fill" }
        return "dot.radiowaves.left.and.right"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.1), in: Capsule())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func statusChip(for dult: DULTStatus) -> some View {
        switch dult.isNearOwner {
        case false?:
            badge("Separated", color: Self.warningColor)
        case true?:
            chip("Near Owner")
        case nil:
            // Status byte missing from the advertisement (non-compliant tracker).
            chip("Status N/A")
        }
    }
}

/// Three-bar signal strength indicator driven by RSSI.
/// Stronger than -60 dBm lights 3 bars, stronger than -75 lights 2, else 1.
struct SignalBarsView: View {
    let rssi: Int
    var litColor: Color = .green

    private var litBars: Int {
        if rssi >= -60 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < litBars ? litColor : Color.white.opacity(0.15))
                    .frame(width: 4, height: CGFloat(7 + index * 5))
            }
        }
        .animation(.easeOut(duration: 0.25), value: litBars)
    }
}

#Preview("Cards", traits: .fixedLayout(width: 620, height: 560)) {
    VStack(spacing: 10) {
        DeviceCardView(device: DiscoveredDevice(
            id: UUID(), name: nil, rssi: -42,
            firstSeen: .now.addingTimeInterval(-1500), lastSeen: .now,
            sightingCount: 1240,
            dult: DULTStatus(serviceData: Data([0x01, 0x00]), source: .dult),
            assessment: FollowingAssessment(
                score: 0.85,
                firstSeen: .now.addingTimeInterval(-1500), lastSeen: .now,
                sightingCount: 1240, distinctLocations: 2, separatedRatio: 0.97
            )
        ))
        DeviceCardView(device: DiscoveredDevice(
            id: UUID(), name: "Tag Mate 3", rssi: -64,
            firstSeen: .now.addingTimeInterval(-700), lastSeen: .now,
            sightingCount: 410,
            dult: DULTStatus(serviceData: Data([0x02, 0x00]), source: .testBeacon),
            assessment: FollowingAssessment(
                score: 0.45,
                firstSeen: .now.addingTimeInterval(-700), lastSeen: .now,
                sightingCount: 410, distinctLocations: 1, separatedRatio: 0.92
            )
        ))
        DeviceCardView(device: DiscoveredDevice(
            id: UUID(), name: nil, rssi: -48,
            firstSeen: .now.addingTimeInterval(-300), lastSeen: .now,
            sightingCount: 212,
            dult: DULTStatus(serviceData: Data([0x01, 0x01, 0xAB, 0xCD]), source: .dult),
            assessment: FollowingAssessment(
                score: 0.05,
                firstSeen: .now.addingTimeInterval(-300), lastSeen: .now,
                sightingCount: 212, distinctLocations: 1, separatedRatio: 0.0
            )
        ))
        DeviceCardView(device: DiscoveredDevice(
            id: UUID(), name: "Living Room TV", rssi: -78,
            firstSeen: .now.addingTimeInterval(-1200), lastSeen: .now.addingTimeInterval(-4),
            sightingCount: 56,
            dult: nil
        ))
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
