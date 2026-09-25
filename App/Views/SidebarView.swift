import SwiftUI

/// The system sidebar presents library scopes like folders, with the other
/// surfaces grouped beneath them. One destination is selected at a time.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    private enum Destination: Hashable {
        case surface(AppState.Surface)
        case userLibrary
        case project(String)
    }

    private var selection: Binding<Destination?> {
        Binding(
            get: {
                guard state.surface == .library else { return .surface(state.surface) }
                switch state.libraryScope {
                case .all: return .surface(.library)
                case .user: return .userLibrary
                case .project(let root): return .project(root)
                }
            },
            set: { destination in
                guard let destination else { return }
                switch destination {
                case .surface(let surface):
                    state.surface = surface
                    if surface == .library {
                        state.libraryScope = .all
                    }
                case .userLibrary:
                    state.libraryScope = .user
                    state.selectedSkillID = nil
                    state.surface = .library
                case .project(let root):
                    state.libraryScope = .project(root)
                    state.selectedSkillID = nil
                    state.surface = .library
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section("Workspaces") {
                row("Library", surface: .library, icon: "books.vertical")
                    .tag(Destination.surface(.library))
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.sidebar.userLibrary")
                    Label("User Library", systemImage: "person.crop.square")
                }
                .help("Show user-scope skills")
                .tag(Destination.userLibrary)
                ForEach(state.projectRoots.sorted(), id: \.self) { root in
                    HStack(spacing: 0) {
                        AXToken(token: "sukiru.sidebar.project.\(AXTokens.path(root))")
                        Label(URL(fileURLWithPath: root).lastPathComponent, systemImage: "folder")
                    }
                    .lineLimit(1)
                    .help(root)
                    .tag(Destination.project(root))
                }
            }
            Section("Tools") {
                row("Health", surface: .health, icon: "stethoscope")
                    .badge(state.report?.findings.count ?? 0)
                    .tag(Destination.surface(.health))
                row("Pending Changes", surface: .pending, icon: "list.bullet.rectangle")
                    .badge(state.pendingBatch?.commands.count ?? 0)
                    .tag(Destination.surface(.pending))
                row("Snapshots", surface: .snapshots, icon: "camera.on.rectangle")
                    .tag(Destination.surface(.snapshots))
                row("Search", surface: .search, icon: "magnifyingglass")
                    .tag(Destination.surface(.search))
            }
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
    }
}
