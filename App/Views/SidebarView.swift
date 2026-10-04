import SukiruCore
import SwiftUI

/// The system sidebar presents the library and Sukiru's own tools first, then
/// the user's projects, then each agent host's plugins and hooks. One
/// destination is selected at a time.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SidebarArrangement.projectsKey) private var projects = SidebarArrangement.standard
    @AppStorage(SidebarArrangement.pluginHostsKey) private var pluginHosts =
        SidebarArrangement.standard
    @AppStorage(SidebarArrangement.hookHostsKey) private var hookHosts =
        SidebarArrangement.standard
    @Environment(\.openSettings) private var openSettings

    private enum Destination: Hashable {
        case surface(AppState.Surface)
        case userLibrary
        case project(String)
        case plugins(PluginHost)
        case hooks(PluginHost)
    }

    private var selection: Binding<Destination?> {
        Binding(
            get: {
                if state.surface == .plugins { return .plugins(state.pluginHost) }
                if state.surface == .hooks { return .hooks(state.hookState.host) }
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
                        state.selectedPluginIDs = []
                    }
                    state.surface = .plugins
                case .hooks(let host):
                    state.hookState.host = host
                    state.hookState.selectedID = nil
                    state.surface = .hooks
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
            Section("Tools") {
                row("Health", surface: .health, icon: "stethoscope")
                    .badge(
                        state.attentionFindingCount
                            + (state.report?.pluginInventory?.healthFindings.count ?? 0)
                            + state.hookProblemCount
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
            if !shownProjects.isEmpty {
                Section("Projects") {
                    ForEach(shownProjects, id: \.self) { root in
                        projectRow(root)
                            .badge(counts.projects[root, default: 0])
                            .tag(Destination.project(root))
                    }
                }
            }
            if !pluginHosts.shown(PluginHost.allCases).isEmpty {
                Section("Plugins") {
                    ForEach(pluginHosts.shown(PluginHost.allCases), id: \.self) { host in
                        pluginRow(host)
                            .badge(state.pluginInstallations(for: host).count)
                            .tag(Destination.plugins(host))
                    }
                }
            }
            if !hookHosts.shown(PluginHost.hookHosts).isEmpty {
                Section("Hooks") {
                    ForEach(hookHosts.shown(PluginHost.hookHosts), id: \.self) { host in
                        hookRow(host)
                            .badge(state.hooks(for: host).count)
                            .tag(Destination.hooks(host))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.projectRoots) { _, roots in
            // A SUKIRU_ROOTS session never rewrites the user's saved folders.
            if state.environment.projectRoots.isEmpty { projects.retain(roots) }
        }
        .onChange(of: projects) { _, arrangement in
            if case .project(let root) = state.libraryScope, !arrangement.isShown(root) {
                state.libraryScope = .all
                state.selectedSkillID = nil
            }
        }
        .onChange(of: pluginHosts) { _, arrangement in
            if state.surface == .plugins && !arrangement.isShown(state.pluginHost) {
                state.selectedPluginIDs = []
                state.surface = .library
            }
        }
        .onChange(of: hookHosts) { _, arrangement in
            if state.surface == .hooks && !arrangement.isShown(state.hookState.host) {
                state.hookState.selectedID = nil
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

    private var shownProjects: [String] { projects.shown(state.projectRoots.sorted()) }

    /// Reordering stays in the menu and in Settings: the system's drag image
    /// for a vibrant sidebar row drops the vibrancy and renders black in Dark
    /// Mode, while Settings' plain list drags correctly.
    private func pluginRow(_ host: PluginHost) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.plugins.\(host.rawValue)")
            hostLabel(host)
        }
        .help("Show plugins managed by this host")
        .contextMenu {
            arrangementMenu(host, in: PluginHost.allCases, arrangement: $pluginHosts)
        }
    }

    private func hookRow(_ host: PluginHost) -> some View {
        hostLabel(host)
            .accessibilityIdentifier("sukiru.sidebar.hooks.\(host.rawValue)")
            .help("Inspect lifecycle hooks configured for this host")
            .contextMenu {
                arrangementMenu(host, in: PluginHost.hookHosts, arrangement: $hookHosts)
            }
    }

    private func hostLabel(_ host: PluginHost) -> some View {
        Label {
            Text(verbatim: host.displayName)
        } icon: {
            AgentLogo(hostID: host.agentID, size: 16)
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
            arrangementMenu(root, in: state.projectRoots.sorted(), arrangement: $projects)
            Divider()
            Button("Remove Project", role: .destructive) {
                state.removeProjectRoot(root)
            }
        }
    }

    @ViewBuilder
    private func arrangementMenu<Item: SidebarItem>(
        _ item: Item, in items: [Item], arrangement: Binding<SidebarArrangement>
    ) -> some View {
        let shown = arrangement.wrappedValue.shown(items)
        Button("Move Up") { arrangement.wrappedValue.move(item, by: -1, in: items) }
            .disabled(shown.first == item)
        Button("Move Down") { arrangement.wrappedValue.move(item, by: 1, in: items) }
            .disabled(shown.last == item)
        Divider()
        Button("Hide from Sidebar") { arrangement.wrappedValue.set(item, shown: false) }
        Button("Customize Sidebar…") { openSettings() }
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
}
