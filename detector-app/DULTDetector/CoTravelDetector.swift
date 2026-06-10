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

    static let checkInterval: TimeInterval = 30
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
    private let scorer: FollowingScorer = PlaceholderScorer()
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
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
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
        for (uuid, features) in featuresByDevice {
            // Core AI on-device inference — WWDC 2026. Replaces Core ML per
            // Apple deprecation announcement June 9 2026.
            // PlaceholderScorer stands in until the Python pipeline delivers
            // a trained model to load through a Core AI session.
            let score = scorer.score(features)
            assessments[uuid] = FollowingAssessment(
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
