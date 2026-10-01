import AppKit
import SukiruCore
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
            CommandGroup(replacing: .appInfo) {
                Button("About Sukiru") {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
                }
            }
            SidebarCommands()
            // Sidebar switching shortcuts. Visible in the View
            // menu, so the shortcuts are discoverable in-app.
            CommandGroup(after: .sidebar) {
                sidebarCommand("Library", surface: .library, key: "1")
                sidebarCommand("Health", surface: .health, key: "2")
                sidebarCommand("Pending Changes", surface: .pending, key: "3")
                sidebarCommand("Snapshots", surface: .snapshots, key: "4")
                sidebarCommand("Search", surface: .search, key: "5")
                Divider()
                // Quick Look in place. ⌘Y mirrors the
                // Finder convention; the shortcut label in this menu is the
                // in-app discoverability surface.
                Button("Quick Look Selected Skill") {
                    state.quickLookSelectedSkill()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!state.canQuickLookSelectedSkill())
                // Deep-link without a mouse (Full Keyboard Access off
                // means Tab never reaches the detail button, but menu items
                // stay reachable via ⌘⇧F and Help-menu search).
                Button("Show Findings for Selected Skill") {
                    if let skill = state.selectedSkill() {
                        state.showFindings(for: skill)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(state.selectedSkill() == nil)
                Button("Show All Findings") {
                    state.clearHealthFocus()
                }
                .disabled(state.healthFocus == nil)
                Divider()
                // Reveal without a mouse (keyboard path;
                // Full Keyboard Access off means Tab never reaches the
                // finding-row buttons, but menu items stay reachable).
                Button("Reveal Selected Finding in Library") {
                    if let finding = state.selectedFinding() {
                        state.revealInLibrary(for: finding)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(
                    state.selectedFinding().flatMap { state.skill(matching: $0) } == nil)
                Button("Toggle Selected Finding Evidence") {
                    state.toggleSelectedFindingEvidence()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.selectedFinding() == nil)
                Divider()
                // Workspace filter without a mouse (keyboard-access audit):
                // the filter-bar option buttons are not Tab stops with Full
                // Keyboard Access off, so ⌥⌘←/→ cycle the filter across
                // "All" and every workspace in report order.
                Button("Show Next Workspace") {
                    state.cycleWorkspaceFilter(step: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!state.canCycleWorkspaceFilter)
                Button("Show Previous Workspace") {
                    state.cycleWorkspaceFilter(step: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!state.canCycleWorkspaceFilter)
                Divider()
                // Project-root management from the menu bar. Remove has no
                // ⌘⌫ shortcut: it would beat the search field's own ⌘⌫.
                Button("Add Project Root…") {
                    state.addProjectRootViaPanel()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Remove Selected Project Root") {
                    if case .project(let root) = state.libraryScope {
                        state.removeProjectRoot(root)
                    }
                }
                .disabled(!state.isProjectScopeSelected)
                Divider()
                Button("Refresh") {
                    state.rescan()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // The search/install flow, keyboard-operable: the
            // search field's onSubmit (Return in the field) runs the query;
            // ⌘K re-runs the current query from anywhere, ⌘⇧I opens the
            // installer-choice sheet for the selected result.
            CommandMenu("Search") {
                Button("Run Search") {
                    state.performSearch()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(
                    state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
                Button("Install Selected Skill…") {
                    state.presentInstallSheet()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(state.selectedSearchResult() == nil)
            }
            // The repair flow, fully keyboard-operable.
            // Full Keyboard Access off means the Pending/Snapshots buttons
            // are not Tab stops, so every step — fix deep-link, decision,
            // batch confirmation, execute, discard, rollback — has a menu
            // command here.
            CommandMenu("Repair") {
                Button("Fix Selected Finding…") {
                    if let finding = state.selectedFinding() {
                        state.beginRepair(for: finding)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(
                    state.selectedFinding().flatMap { state.skill(matching: $0) } == nil)
                Divider()
                decisionCommand("Update via Owning CLI", action: .update, key: "u")
                decisionCommand("Clean Up", action: .cleanup, key: "d")
                decisionCommand("Adopt into GitHub Ledger…", action: .adopt, key: "a")
                decisionCommand("Choose Surviving Ledger…", action: .arbitrate, key: "t")
                decisionCommand("Leave As-Is", action: .leave, key: "l")
                Divider()
                Button("Execute Batch") {
                    state.executePendingBatch()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!state.canExecutePendingBatch)
                Button("Discard Batch") {
                    state.dismissBatchConfirm()
                }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(state.pendingBatch == nil || state.batchMutationInFlight)
                Divider()
                Button("Roll Back Selected Batch") {
                    state.rollbackSelectedBatch()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!state.canRollbackSelectedBatch)
            }
        }
        // The standard macOS Settings scene (⌘,): settings live in their own
        // window like any native app, not in the sidebar.
        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }

    /// A repair-decision menu command: enabled only while a draft is open
    /// AND the decision is available (never capability-blocked — a blocked
    /// decision shows its hint in Pending Changes instead).
    private func decisionCommand(
        _ title: LocalizedStringKey, action: DecisionAction, key: KeyEquivalent
    ) -> some View {
        Button(title) {
            state.chooseRepair(action)
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(!state.repairActionAvailable(action))
    }

    /// The standard About panel takes name, icon, version, and copyright from
    /// Info.plist; the credits add only the project homepage.
    private static var aboutCredits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: "github.com/thedavidweng/sukiru",
            attributes: [
                .link: "https://github.com/thedavidweng/sukiru",
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraph
            ])
    }

    private func sidebarCommand(
        _ title: LocalizedStringKey, surface: AppState.Surface, key: KeyEquivalent
    ) -> some View {
        Button(title) {
            if surface == .library { state.libraryScope = .all }
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
