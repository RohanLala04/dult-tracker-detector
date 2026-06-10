import Foundation

/// A device the co-travel heuristic has flagged as potentially following the user.
struct FollowerFlag: Equatable {
    let firstSeen: Date
    let lastSeen: Date
    let sightingCount: Int
    let distinctLocations: Int
    /// Fraction of sightings where the tracker reported separated (0.0-1.0).
    let separatedRatio: Double

    /// How long the device has been traveling with the user.
    var trackedDuration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
}

/// Periodically evaluates the sightings database against the co-travel
/// heuristic. A device is a candidate follower when ALL of these hold:
///   - it was seen at 2+ distinct locations, OR continuously for 10+ minutes
///     within the current session, and
///   - it reported separated (near-owner bit = 0) in more than half of its
///     sightings, and
///   - it was seen within the last 60 seconds (still nearby).
final class CoTravelDetector {

    static let checkInterval: TimeInterval = 30
    static let recencyWindow: TimeInterval = 60
    static let minContinuousDuration: TimeInterval = 600
    static let minDistinctLocations = 2
    static let minSeparatedRatio = 0.5

    /// Called on the main queue after every check with the full current set
    /// of flagged devices, keyed by peripheral UUID string.
    var onUpdate: (([String: FollowerFlag]) -> Void)?

    private let database: DatabaseManager
    /// The 10-minute continuity rule only counts time within this run of the
    /// app, so sightings logged by earlier sessions cannot satisfy it alone.
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
        let flags = database.followerCandidates(
            recencyWindow: Self.recencyWindow,
            sessionStart: sessionStart,
            minContinuousDuration: Self.minContinuousDuration,
            minDistinctLocations: Self.minDistinctLocations,
            minSeparatedRatio: Self.minSeparatedRatio
        )
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(flags)
        }
    }
}
