import SwiftUI

/// The app shell: a three-column navigation split —
/// sidebar (surfaces), content (the selected surface), detail (selection
/// detail for Library, Snapshots, and Search). State lives in `AppState`, so selection and
/// disclosure state survive surface switches and resizes.
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
                .toolbar(content: refreshToolbar)
        } detail: {
            detail
                .toolbar(content: detailToolbar)
        }
        .sheet(isPresented: $state.showingBatchConfirm, onDismiss: state.dismissBatchConfirm) {
            BatchConfirmSheet()
        }
        .sheet(isPresented: showingSourceSheet) {
            if let skill = state.sourceSheetSkill {
                OrphanSourceSheet(skill: skill)
            }
        }
        .sheet(isPresented: showingPinSheet) {
            if let skill = state.pinSheetSkill {
                PinSheet(skill: skill)
            }
        }
        .modifier(HistoryConfirmations())
        .sheet(isPresented: $state.pluginManagement.showingSheet) {
            PluginManagementSheet()
        }
    }

    private var showingSourceSheet: Binding<Bool> {
        Binding(
            get: { state.sourceSheetSkill != nil },
            set: { if !$0 { state.sourceSheetSkill = nil } })
    }

    private var showingPinSheet: Binding<Bool> {
        Binding(
            get: { state.pinSheetSkill != nil },
            set: { if !$0 { state.pinSheetSkill = nil } })
    }

    /// Finder-style Refresh, shared by every surface: the no-watchers model
    /// means external changes appear only after it.
    @ToolbarContentBuilder
    private func refreshToolbar() -> some ToolbarContent {
        ToolbarItem {
            Button {
                state.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .axButtonToken("sukiru.toolbar.refresh", disabled: state.healthCheckRunning)
            .disabled(state.healthCheckRunning)
            .help(
                "Re-reads the library and snapshots from disk (⌘R). External changes appear only after Refresh."
            )
        }
    }

    /// On macOS 26+, a detail column that declares no toolbar items lets the
    /// content column's whole-surface actions drift to the window's trailing
    /// edge, where they read as acting on the selected item. A flexible
    /// spacer keeps them over the list. Library, Plugins, and Search detail
    /// columns declare their own items, so they need none.
    @ToolbarContentBuilder
    private func detailToolbar() -> some ToolbarContent {
        if #available(macOS 26.0, *), ![.library, .plugins, .search].contains(state.surface) {
            ToolbarSpacer(.flexible)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.surface {
        case .library:
            LibraryView()
        case .plugins:
            PluginLibraryView()
        case .health:
            HealthView()
                .navigationTitle("Health")
        case .pending:
            PendingChangesView()
                .navigationTitle("Pending Changes")
        case .snapshots:
            SnapshotsView()
                .navigationTitle("Snapshots")
        case .search:
            SearchView()
                .navigationTitle("Discover")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.surface {
        case .library:
            LibraryDetailView()
        case .plugins:
            PluginDetailView()
        case .snapshots:
            // Post-run diff / itemized rollback record.
            SnapshotsDetailView()
        case .search:
            SearchDetailView()
        case .health:
            HealthDetailView()
        case .pending:
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
