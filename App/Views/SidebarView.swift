import SukiruCore
import SwiftUI

/// The system sidebar presents library scopes like folders, with the other
/// surfaces grouped beneath them. One destination is selected at a time.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SidebarPluginHosts.defaultsKey) private var pluginHosts = SidebarPluginHosts.all

    private enum Destination: Hashable {
        case surface(AppState.Surface)
        case userLibrary
        case project(String)
        case plugins(PluginHost)
    }

    private var selection: Binding<Destination?> {
        Binding(
            get: {
                if state.surface == .plugins { return .plugins(state.pluginHost) }
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
                case .plugins(let host):
                    if state.pluginHost != host {
                        state.pluginHost = host
                        state.selectedPluginID = nil
                    }
                    state.surface = .plugins
                }
            })
    }

    var body: some View {
        let counts = SkillCounts(state: state)
        List(selection: selection) {
            Section("Library") {
                row("All Skills", surface: .library, icon: "square.stack")
                    .badge(counts.all)
                    .tag(Destination.surface(.library))
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.sidebar.userLibrary")
                    Label("User Library", systemImage: "person.crop.circle")
                }
                .badge(counts.user)
                .help("Show user-scope library items")
                .tag(Destination.userLibrary)
            }
            if !state.projectRoots.isEmpty {
                Section("Projects") {
                    ForEach(state.projectRoots.sorted(), id: \.self) { root in
                        projectRow(root)
                            .badge(counts.projects[root, default: 0])
                            .tag(Destination.project(root))
                    }
                }
            }
            if !pluginHosts.hosts.isEmpty {
                Section("Plugins") {
                    ForEach(pluginHosts.hosts, id: \.self) { host in
                        pluginRow(host)
                            .badge(state.pluginInstallations(for: host).count)
                            .tag(Destination.plugins(host))
                            .pluginHostDraggable(host)
                    }
                    .dropDestination(for: String.self) { pluginHosts.drop($0, at: $1) }
                }
            }
            Section("Tools") {
                row("Health", surface: .health, icon: "stethoscope")
                    .badge(
                        state.attentionFindingCount
                            + (state.report?.pluginInventory?.healthFindings.count ?? 0)
                    )
                    .tag(Destination.surface(.health))
                row("Pending Changes", surface: .pending, icon: "list.bullet.rectangle")
                    .badge(state.queuedChangeCount)
                    .tag(Destination.surface(.pending))
                row("Snapshots", surface: .snapshots, icon: "camera.on.rectangle")
                    .tag(Destination.surface(.snapshots))
                row("Discover", surface: .search, icon: "safari")
                    .tag(Destination.surface(.search))
            }
        }
        .listStyle(.sidebar)
        .onChange(of: pluginHosts) { _, pinned in
            if state.surface == .plugins && !pinned.hosts.contains(state.pluginHost) {
                state.selectedPluginID = nil
                state.surface = .library
            }
        }
        .sidebarFooter {
            Button {
                state.addProjectRootViaPanel()
            } label: {
                Label("Add Project…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Add a project folder whose skills Sukiru should read")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func row(
        _ title: LocalizedStringKey, surface: AppState.Surface, icon: String
    ) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.\(surface.rawValue)")
            Label(title, systemImage: icon)
        }
    }

    /// Drag reorders the section; the menu offers the same moves for
    /// keyboard and VoiceOver users, and Settings restores hidden hosts.
    private func pluginRow(_ host: PluginHost) -> some View {
        let index = pluginHosts.hosts.firstIndex(of: host) ?? 0
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.plugins.\(host.rawValue)")
            Label {
                Text(verbatim: host.displayName)
            } icon: {
                AgentLogo(hostID: host.agentID, size: 16)
            }
        }
        .help("Show plugins managed by this host")
        .contextMenu {
            Button("Move Up") {
                pluginHosts.move(from: [index], to: index - 1)
            }
            .disabled(index == 0)
            Button("Move Down") {
                pluginHosts.move(from: [index], to: index + 2)
            }
            .disabled(index == pluginHosts.hosts.count - 1)
            Divider()
            Button("Remove from Sidebar") {
                pluginHosts.set(host, pinned: false)
            }
            SettingsLink {
                Text("Customize Sidebar…")
            }
        }
    }

    private func projectRow(_ root: String) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.project.\(AXTokens.path(root))")
            Label(URL(fileURLWithPath: root).lastPathComponent, systemImage: "folder")
        }
        .lineLimit(1)
        .help(root)
        .contextMenu {
            Button("Show in Finder") {
                state.revealInFinder([root])
            }
            Divider()
            Button("Remove Project", role: .destructive) {
                state.removeProjectRoot(root)
            }
        }
    }
}

/// Skill totals per sidebar scope, counted the same way the Library list
/// groups them so a badge always matches the rows it leads to.
private struct SkillCounts {
    var all = 0
    var user = 0
    var projects: [String: Int] = [:]

    @MainActor
    init(state: AppState) {
        for skill in state.report?.skills ?? [] {
            if skill.scope == .user {
                user += 1
                all += 1
            } else if skill.scope == .project, let root = state.projectRoot(of: skill) {
                projects[root, default: 0] += 1
                all += 1
            }
        }
    }
}

extension View {
    /// Pins the sidebar's footer controls; on macOS 26+ as a bar, so the list
    /// keeps the system's bottom scroll-edge treatment.
    @ViewBuilder
    fileprivate func sidebarFooter<Bar: View>(@ViewBuilder _ footer: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: footer)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: footer)
        }
    }

    /// Drags a plugin host row by its raw value. The system's snapshot of a
    /// sidebar row loses its vibrant styling and renders as a black
    /// silhouette, so the preview draws the label on a semantic background.
    func pluginHostDraggable(_ host: PluginHost) -> some View {
        draggable(host.rawValue) {
            Label {
                Text(verbatim: host.displayName)
            } icon: {
                AgentLogo(hostID: host.agentID, size: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background, in: .rect(cornerRadius: 6))
        }
    }
}
