import SwiftUI

/// The app shell (architecture §4.3): a three-column navigation split —
/// sidebar (surfaces), content (the selected surface), detail (selection
/// detail for Library/Health). State lives in `AppState`, so selection and
/// disclosure state survive surface switches (VAL-HEALTH-045) and resizes
/// (VAL-HEALTH-040).
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            detail
        }
        .toolbar(content: toolbar)
    }

    /// The window toolbar: the global Refresh action (Finder-style; the
    /// no-watchers model means external changes appear only after it) and
    /// the Library-contextual Quick Look. On macOS 26+ the two groups are
    /// separated by a fixed `ToolbarSpacer`, which the system renders as a
    /// Liquid Glass divider between the grouped buttons (the same
    /// availability-gated pattern as any standard SwiftUI app).
    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup {
                refreshToolbarButton
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .automatic) {
                quickLookToolbarButton
            }
        } else {
            ToolbarItemGroup {
                refreshToolbarButton
                quickLookToolbarButton
            }
        }
    }

    private var refreshToolbarButton: some View {
        Button {
            state.rescan()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .axButtonToken("sukiru.toolbar.refresh", disabled: state.healthCheckRunning)
        .disabled(state.healthCheckRunning)
        .help("Re-reads the library from disk (⌘R). External changes appear only after Refresh.")
    }

    private var quickLookToolbarButton: some View {
        Button {
            state.quickLookSelectedSkill()
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        .axButtonToken(
            "sukiru.toolbar.quicklook", disabled: !state.canQuickLookSelectedSkill()
        )
        .disabled(!state.canQuickLookSelectedSkill())
        .help("Quick Look the selected skill's SKILL.md (⌘Y).")
    }

    @ViewBuilder
    private var content: some View {
        switch state.surface {
        case .library:
            LibraryView()
        case .health:
            HealthView()
        case .pending:
            PendingChangesView()
        case .snapshots:
            SnapshotsView()
        case .search:
            SearchView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.surface {
        case .library:
            LibraryDetailView()
        case .pending:
            // Per-command inspection view (VAL-REPAIR-006/047).
            PendingCommandDetailView()
        case .snapshots:
            // Post-run diff / itemized rollback record (VAL-REPAIR-046).
            SnapshotsDetailView()
        case .health, .search:
            DetailPlaceholderView()
        }
    }
}

/// Empty detail column for surfaces without a detail pane.
struct DetailPlaceholderView: View {
    var body: some View {
        Text("Nothing selected")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
