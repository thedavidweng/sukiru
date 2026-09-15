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
            SidebarView(selection: $state.surface)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            detail
        }
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
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.surface {
        case .library:
            LibraryDetailView()
        case .health, .pending, .snapshots, .search, .settings:
            DetailPlaceholderView()
        }
    }
}

/// Empty detail column for surfaces without a detail pane in M3.
struct DetailPlaceholderView: View {
    var body: some View {
        Text("Nothing selected")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
