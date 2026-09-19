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
                // Quick Look in place (VAL-HEALTH-023/030). ⌘Y mirrors the
                // Finder convention; the shortcut label in this menu is the
                // in-app discoverability surface.
                Button("Quick Look Selected Skill") {
                    state.quickLookSelectedSkill()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!state.canQuickLookSelectedSkill())
                // D16 deep-link without a mouse (Full Keyboard Access off
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
                // D16 reveal without a mouse (VAL-CROSS-004 keyboard path;
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
                // Project-root management without a mouse: the Settings
                // Add/Remove buttons are not Tab stops either. Add opens the
                // folder picker (⌘⇧A); Remove acts on the Settings list
                // selection (⌘⌫).
                Button("Add Project Root…") {
                    state.addProjectRootViaPanel()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Remove Selected Project Root") {
                    if let root = state.selectedProjectRoot {
                        state.removeProjectRoot(root)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.selectedProjectRoot == nil)
                Divider()
                Button("Refresh") {
                    state.rescan()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // The M5 search/install flow, keyboard-operable (story 29): the
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
            // The M4 repair flow, fully keyboard-operable (VAL-CROSS-019).
            // Full Keyboard Access off means the Pending/Snapshots buttons
            // are not Tab stops, so every step — fix deep-link, decision,
            // per-command review, execute, discard, rollback — has a menu
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
                Button("Toggle Review of Selected Command") {
                    state.toggleSelectedCommandReview()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.pendingBatch == nil || state.selectedCommandIndex == nil)
                Button("Execute Batch") {
                    state.executePendingBatch()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!state.canExecutePendingBatch)
                Button("Discard Batch") {
                    state.discardPendingBatch()
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
    }

    /// A repair-decision menu command: enabled only while a draft is open
    /// AND the decision is available (never capability-blocked — a blocked
    /// decision shows its hint in Pending Changes instead, VAL-REPAIR-049).
    private func decisionCommand(
        _ title: LocalizedStringKey, action: DecisionAction, key: KeyEquivalent
    ) -> some View {
        Button(title) {
            state.chooseRepair(action)
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(!state.repairActionAvailable(action))
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
