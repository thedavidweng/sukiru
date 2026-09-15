import AppKit
import SwiftUI

@main
struct SukiruApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Sukiru") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 940, idealWidth: 1120, minHeight: 540, idealHeight: 680)
                .onAppear { state.start() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Sidebar switching shortcuts (VAL-CROSS-003). Visible in the View
            // menu, so the shortcuts are discoverable in-app.
            CommandGroup(after: .sidebar) {
                sidebarCommand("Library", surface: .library, key: "1")
                sidebarCommand("Health", surface: .health, key: "2")
                sidebarCommand("Pending Changes", surface: .pending, key: "3")
                sidebarCommand("Snapshots", surface: .snapshots, key: "4")
                sidebarCommand("Search", surface: .search, key: "5")
                sidebarCommand("Settings", surface: .settings, key: "6")
                Divider()
                Button("Refresh") {
                    state.rescan()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func sidebarCommand(
        _ title: LocalizedStringKey, surface: AppState.Surface, key: KeyEquivalent
    ) -> some View {
        Button(title) {
            state.surface = surface
        }
        .keyboardShortcut(key, modifiers: .command)
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
