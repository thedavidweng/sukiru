import Sparkle
import SwiftUI

/// Sparkle's standard updater (ADR 0015): the App menu checks on demand and
/// Settings mirrors the automatic-check preference. Debug builds never start
/// it, so a development build is never replaced by a release.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG
            let starting = false
        #else
            let starting = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: starting, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
