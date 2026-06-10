import SwiftUI

@main
struct DULTDetectorApp: App {
    // One scanner for the whole app; created at launch so scanning
    // starts as soon as Bluetooth is ready.
    @StateObject private var scanner = BLEScanner()

    var body: some Scene {
        WindowGroup("DULT Detector") {
            ContentView()
                .environmentObject(scanner)
        }
        .defaultSize(width: 720, height: 640)
    }
}
