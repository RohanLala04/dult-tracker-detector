import SwiftUI
import AppKit

@main
struct DULTDetectorApp: App {
    // One scanner for the whole app; created at launch so scanning
    // starts as soon as Bluetooth is ready.
    @StateObject private var scanner = BLEScanner()

    init() {
        Self.terminateIfAlreadyRunning()
    }

    /// Quits this copy at launch when another copy is already running.
    /// Every copy scans independently and inserts rows into the shared
    /// sightings database, each stamped with its own geocoded location
    /// label, so concurrent copies interleave conflicting labels and
    /// inflate the distinct-location count the co-travel scorer relies on.
    /// Runs before the scanner exists, so the duplicate never opens the
    /// database or starts scanning.
    private static func terminateIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current && !$0.isTerminated }
        guard let existing = others.first else { return }

        let alert = NSAlert()
        alert.messageText = "DULT Detector is already running"
        alert.informativeText = """
            Switching to the copy that is already open. Running two copies \
            at once would write conflicting rows into the sightings database.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Hand focus to the running copy so this feels like a window
        // switch rather than a failed launch.
        NSApplication.shared.yieldActivation(to: existing)
        existing.activate()
        exit(0)
    }

    var body: some Scene {
        WindowGroup("DULT Detector") {
            ContentView()
                .environmentObject(scanner)
        }
        .defaultSize(width: 720, height: 640)
    }
}
