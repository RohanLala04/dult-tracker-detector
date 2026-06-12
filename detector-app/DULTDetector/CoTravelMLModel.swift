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

/// Runs the trained classifier (bundled Core AI asset) through the Core AI
/// runtime. Available on macOS 27 and later only; on macOS 26 the detector
/// falls back to RuleBasedScorer.
@available(macOS 27.0, *)
final class CoreAIScorer: FollowingScorer {

    /// Bridges results out of the async inference task; the semaphore
    /// guarantees the value is written before it is read.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    private let modelURL: URL
    /// Loaded lazily on the first score call (model loading is async and the
    /// scorer runs on a utility queue, so blocking there is acceptable).
    private var function: InferenceFunction?
    private var loadFailed = false

    /// Fails (returning nil) if the bundled asset is missing, in which case
    /// the caller falls back to the rule-based scorer.
    ///
    /// The asset ships in the bundle as cotravel.coreaiasset: the .aimodel
    /// format declares minimum OS 27, so Xcode's resource compiler rejects it
    /// in a deployment-target-26 app. Shipping it under a neutral extension
    /// and restoring the .aimodel name in Application Support at first load
    /// sidesteps the build rule without touching the asset contents.
    init?() {
        guard let bundled = Bundle.main.url(forResource: "cotravel", withExtension: "coreaiasset") else {
            print("[CoreAIScorer] cotravel.coreaiasset missing from app bundle")
            return nil
        }
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("DULTDetector", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let url = support.appendingPathComponent("cotravel.aimodel", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: bundled, to: url)
            modelURL = url
        } catch {
            print("[CoreAIScorer] failed to stage model asset: \(error)")
            return nil
        }
    }

    func score(_ features: DeviceFeatures) -> Double {
        guard let function = loadedFunction() else {
            return RuleBasedScorer().score(features)
        }

        // Order must match FEATURES in the training pipeline: rssi_mean,
        // rssi_var, duration_s, distinct_locations, persistence_per_min,
        // separated_ratio.
        let values: [Float] = [
            Float(features.rssiMean),
            Float(features.rssiVariance),
            Float(features.duration),
            Float(features.distinctLocations),
            Float(features.persistence),
            Float(features.separatedRatio),
        ]
        var input = NDArray(shape: [1, values.count], scalarType: .float32)
        do {
            var view = input.mutableView(as: Float.self)
            view.copyElements(fromContentsOf: values)
        }

        // The scorer protocol is synchronous (called on a utility queue every
        // 30 seconds), so block this thread on the async inference call.
        let result = Box<Double>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                var output = NDArray(shape: [1], scalarType: .float32)
                var outputViews = InferenceFunction.MutableViews()
                outputViews.insert(&output, for: "probability")
                _ = try await function.run(
                    inputs: ["features": input],
                    outputViews: consume outputViews
                )
                let probability = output.view(as: Float.self).withUnsafePointer { pointer, _, _ in
                    pointer[0]
                }
                result.value = Double(probability)
            } catch {
                print("[CoreAIScorer] inference failed: \(error)")
            }
        }
        semaphore.wait()
        return result.value ?? RuleBasedScorer().score(features)
    }

    /// Loads the inference function once; subsequent calls reuse it.
    /// Thread safety comes from the caller (CoTravelDetector's serial queue).
    private func loadedFunction() -> InferenceFunction? {
        if let function { return function }
        if loadFailed { return nil }

        let loaded = Box<InferenceFunction>()
        let semaphore = DispatchSemaphore(value: 0)
        let url = modelURL
        Task {
            defer { semaphore.signal() }
            do {
                let model = try await AIModel(contentsOf: url)
                loaded.value = try model.loadFunction(named: "main")
            } catch {
                print("[CoreAIScorer] failed to load model: \(error)")
            }
        }
        semaphore.wait()

        if let value = loaded.value {
            function = value
            print("[CoreAIScorer] Core AI model loaded")
        } else {
            loadFailed = true
            print("[CoreAIScorer] falling back to rules (model load failed)")
        }
        return loaded.value
    }
}

/// Rule-based scorer: the macOS 26 fallback, and the stand-in wherever the
/// Core AI model cannot load. Maps the co-travel heuristic onto three fixed
/// probability bands. Reporting separated (away from its owner) is required
/// for any elevated score: a device that is not separated is an ambient
/// device or an owner-present tag, not a follower, no matter how long it is
/// seen.
///   0.85  separated and traveling: candidate follower
///   0.45  separated but not yet traveling: worth watching
///   0.05  not separated: not a co-travel threat
struct RuleBasedScorer: FollowingScorer {
    func score(_ features: DeviceFeatures) -> Double {
        let mostlySeparated = features.separatedRatio > CoTravelDetector.minSeparatedRatio
        guard mostlySeparated else { return 0.05 }
        let traveled = features.distinctLocations >= CoTravelDetector.minDistinctLocations
            || features.sessionDuration >= CoTravelDetector.minContinuousDuration
        return traveled ? 0.85 : 0.45
    }
}
