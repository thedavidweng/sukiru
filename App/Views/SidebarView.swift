import SwiftUI

/// The surface sidebar (architecture §4.3). Every row carries its D21 token
/// (`sukiru.sidebar.<surface>`) via an `AXToken` carrier so the tree prints
/// e.g. `outline row sukiru.sidebar.library Library` — token AND localized
/// title on the same row line.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Binding var selection: AppState.Surface

    var body: some View {
        List(selection: $selection) {
            row("Library", surface: .library, icon: "books.vertical")
            row("Health", surface: .health, icon: "stethoscope")
                .badge(state.report?.findings.count ?? 0)
            row("Pending Changes", surface: .pending, icon: "list.bullet.rectangle")
                .badge(state.pendingBatch?.commands.count ?? 0)
            row("Snapshots", surface: .snapshots, icon: "camera.on.rectangle")
            row("Search", surface: .search, icon: "magnifyingglass")
        }
        .listStyle(.sidebar)
    }

    private func row(
        _ title: LocalizedStringKey, surface: AppState.Surface, icon: String
    ) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.\(surface.rawValue)")
            Label(title, systemImage: icon)
        }
        .tag(surface)
    }
}
