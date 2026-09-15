import AppKit
import SwiftUI

@main
struct SukiruApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Sukiru") {
            PlaceholderView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// Launching the built binary directly (Scripts/run-app.sh, never `open`) does
/// not go through LaunchServices, so the process starts as an unactivated
/// accessory. Without an explicit regular activation policy the window never
/// becomes an accessibility window and computer-use AX reads stay blocked.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
