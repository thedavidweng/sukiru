import Observation
import Sparkle
import SwiftUI

/// Sparkle's standard updater (ADR 0015): the App menu checks on demand and
/// Settings mirrors the automatic-check preference. Debug builds never start
/// it, so a development build is never replaced by a release.
@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Sparkle reports session changes by KVO only; the mirror above keeps
    /// SwiftUI's observation of the menu item and its label.
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init() {
        #if DEBUG
            let starting = false
        #else
            let starting = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: starting, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
