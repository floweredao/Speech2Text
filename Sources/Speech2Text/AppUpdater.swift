import Foundation
import Sparkle

/// Checks the GitHub release appcast with Sparkle. Only a packaged `.app` gets an updater;
/// `swift run` and tests have no bundle to replace.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            controller = nil
            return
        }
        // Starts the scheduled daily check configured in Info.plist.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
