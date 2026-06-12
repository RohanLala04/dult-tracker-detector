import Foundation

/// The co-travel verdict for one device: a following probability plus the
/// observation stats behind it.
struct FollowingAssessment: Equatable {
    /// Probability (0.0-1.0) that this device is following the user.
    let score: Double
    let firstSeen: Date
    let lastSeen: Date
    let sightingCount: Int
    let distinctLocations: Int
    /// Fraction of sightings where the tracker reported separated (0.0-1.0).
    let separatedRatio: Double

    /// How long the device has been traveling with the user.
    var trackedDuration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
}

/// Periodically extracts per-device features from the sightings database and
/// scores them. The underlying heuristic: a follower was seen at 2+ distinct
/// locations or continuously for 10+ minutes within the current session,
/// reported separated in more than half of its sightings, and was seen
/// within the last 60 seconds (still nearby).
final class CoTravelDetector {

    static let checkInterval: TimeInterval = 10
    static let recencyWindow: TimeInterval = 60
    static let minContinuousDuration: TimeInterval = 600
    static let minDistinctLocations = 2
    static let minSeparatedRatio = 0.5
    /// Scores above this are alerts (red); scores at or above
    /// elevatedThreshold are borderline (amber); below is clean (green).
    static let alertThreshold = 0.7
    static let elevatedThreshold = 0.4

    /// Called on the main queue after every check with assessments for all
    /// recently seen devices, keyed by peripheral UUID string.
    var onUpdate: (([String: FollowingAssessment]) -> Void)?

    private let database: DatabaseManager
    /// The trained Core AI model on macOS 27+; rule-based bands on macOS 26.
    private let scorer: FollowingScorer = {
        if #available(macOS 27.0, *), let coreAI = CoreAIScorer() {
            print("[CoTravelDetector] scoring with the Core AI model")
            return coreAI
        }
        print("[CoTravelDetector] scoring with rules (Core AI needs macOS 27)")
        return RuleBasedScorer()
    }()
    /// The continuity rule only counts time within this run of the app, so
    /// sightings logged by earlier sessions cannot satisfy it alone.
    private let sessionStart = Date()
    private let queue = DispatchQueue(label: "DULTDetector.cotravel", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(database: DatabaseManager) {
        self.database = database
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // First check shortly after launch so a probability appears within
        // seconds rather than after a full interval, then every interval.
        timer.schedule(deadline: .now() + 3, repeating: Self.checkInterval)
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        let featuresByDevice = database.deviceFeatures(
            recencyWindow: Self.recencyWindow,
            sessionStart: sessionStart
        )
        var assessments: [String: FollowingAssessment] = [:]
        for (continuityKey, features) in featuresByDevice {
            // Core AI on-device inference — WWDC 2026. Replaces Core ML per
            // Apple deprecation announcement June 9 2026.
            // Falls back to RuleBasedScorer where the Core AI runtime is
            // unavailable (macOS 26.x).
            let score = scorer.score(features)
            assessments[continuityKey] = FollowingAssessment(
                score: score,
                firstSeen: features.firstSeen,
                lastSeen: features.lastSeen,
                sightingCount: features.sightingCount,
                distinctLocations: features.distinctLocations,
                separatedRatio: features.separatedRatio
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(assessments)
        }
    }
}
