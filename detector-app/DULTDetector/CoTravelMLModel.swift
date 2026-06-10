import Foundation
import CoreAI

/// The six features the co-travel classifier consumes, computed per device
/// from the sightings database, plus context carried along for display.
struct DeviceFeatures {
    let rssiMean: Double
    let rssiVariance: Double
    /// Seconds between the device's first and last sighting.
    let duration: TimeInterval
    let distinctLocations: Int
    /// Sightings per minute over the observation window (min window 1 min).
    let persistence: Double
    /// Fraction of sightings where the near-owner bit reported separated.
    let separatedRatio: Double

    let sightingCount: Int
    let firstSeen: Date
    let lastSeen: Date
    /// Seconds of the observation window that fall within the current app
    /// session; the continuity rule only credits this portion.
    let sessionDuration: TimeInterval
}

/// Turns a device's feature vector into a following probability (0.0-1.0).
protocol FollowingScorer {
    func score(_ features: DeviceFeatures) -> Double
}

/// Stand-in scorer used until the Python pipeline delivers a trained model
/// to run through Core AI. Maps the rule-based heuristic onto three fixed
/// probability bands so the scoring pipeline and UI are exercised end to end:
///   0.85  meets the full co-travel heuristic
///   0.45  borderline - meets exactly one of the two main conditions
///   0.05  clean
struct PlaceholderScorer: FollowingScorer {
    func score(_ features: DeviceFeatures) -> Double {
        let traveled = features.distinctLocations >= CoTravelDetector.minDistinctLocations
            || features.sessionDuration >= CoTravelDetector.minContinuousDuration
        let mostlySeparated = features.separatedRatio > CoTravelDetector.minSeparatedRatio
        switch (traveled, mostlySeparated) {
        case (true, true): return 0.85
        case (true, false), (false, true): return 0.45
        case (false, false): return 0.05
        }
    }
}
