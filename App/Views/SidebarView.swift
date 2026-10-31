import SukiruCore
import SwiftUI

/// The system sidebar presents the library and Sukiru's own tools first, then
/// the user's projects, then one expandable row per agent holding its skills,
/// plugins, hooks, extensions, and MCP servers. One destination is selected
/// at a time.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SidebarArrangement.projectsKey) private var projects = SidebarArrangement.standard
    @AppStorage(SidebarArrangement.agentsKey) private var agents = SidebarArrangement.standard
    /// Agent ids, comma-separated; agents start expanded.
    @SceneStorage("sidebarCollapsedAgents") private var collapsedAgents = ""
    @Environment(\.openSettings) private var openSettings

    private enum Destination: Hashable {
        case surface(AppState.Surface)
        case userLibrary
        case project(String)
        case agentSkills(SidebarAgent)
        case plugins(PluginHost)
        case hooks(HookHost)
        case extensions(ExtensionHost)
        case mcpServers(ExtensionHost)
    }

    private var selection: Binding<Destination?> {
        Binding(
            get: {
                if state.surface == .plugins { return .plugins(state.pluginHost) }
                if state.surface == .hooks { return .hooks(state.hookState.host) }
                if state.surface == .extensions {
                    let host = state.hookState.extensionHost
                    return state.hookState.showsMCP ? .mcpServers(host) : .extensions(host)
                }
                guard state.surface == .library else { return .surface(state.surface) }
                switch state.libraryScope {
                case .all: return .surface(.library)
                case .user: return .userLibrary
                case .project(let root): return .project(root)
                case .agent(let agent): return .agentSkills(agent)
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
                    showLibrary(.user)
                case .project(let root):
                    showLibrary(.project(root))
                case .agentSkills(let agent):
                    showLibrary(.agent(agent))
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
                case .extensions(let host), .mcpServers(let host):
                    state.hookState.extensionHost = host
                    state.hookState.showsMCP = destination == .mcpServers(host)
                    state.hookState.selectedExtensionID = nil
                    state.surface = .extensions
                }
            })
    }

    var body: some View {
        let shownAgents = agents.shown(SidebarAgent.all, available: state.isAvailable)
        let counts = SkillCounts(state: state, agents: shownAgents)
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
            if !shownAgents.isEmpty {
                Section("Agents") {
                    ForEach(shownAgents, id: \.self) { agent in
                        DisclosureGroup(isExpanded: expansion(of: agent)) {
                            agentItems(agent, skillCount: counts.agents[agent.id, default: 0])
                        } label: {
                            HostLabel(name: agent.name, agentID: agent.id)
                                .accessibilityIdentifier("sukiru.sidebar.agent.\(agent.id)")
                                .contextMenu { agentMenu(agent) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.projectRoots) { _, roots in
            // Fixture homes and explicit roots never rewrite the user's saved folders.
            if !state.environment.homeIsOverridden && state.environment.projectRoots.isEmpty {
                projects.retain(roots)
            }
        }
        .onChange(of: projects) { _, arrangement in
            if case .project(let root) = state.libraryScope, !arrangement.isShown(root) {
                state.libraryScope = .all
                state.selectedSkillIDs = []
            }
        }
        .onChange(of: agents) { _, arrangement in
            guard let agent = state.openAgent,
                !arrangement.isShown(agent, available: state.isAvailable(agent))
            else { return }
            state.selectedPluginIDs = []
            state.hookState.selectedID = nil
            state.hookState.selectedExtensionID = nil
            state.selectedSkillIDs = []
            state.libraryScope = .all
            state.surface = .library
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
}

extension SidebarView {
    private func row(
        _ title: LocalizedStringKey, surface: AppState.Surface, icon: String
    ) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.\(surface.rawValue)")
            Label(title, systemImage: icon)
        }
    }

    private var shownProjects: [String] { projects.shown(state.projectRoots.sorted()) }

    private func showLibrary(_ scope: AppState.LibraryScope) {
        state.libraryScope = scope
        state.selectedSkillIDs = []
        state.surface = .library
    }

    private func expansion(of agent: SidebarAgent) -> Binding<Bool> {
        Binding(
            get: { !collapsedAgents.split(separator: ",").contains(Substring(agent.id)) },
            set: { expanded in
                var ids = collapsedAgents.split(separator: ",").map(String.init)
                ids.removeAll { $0 == agent.id }
                if !expanded { ids.append(agent.id) }
                collapsedAgents = ids.joined(separator: ",")
            })
    }

    /// One row per kind of item the agent has, each its own destination.
    @ViewBuilder
    private func agentItems(_ agent: SidebarAgent, skillCount: Int) -> some View {
        if agent.readsSkills {
            agentItem(
                "Skills", icon: "square.stack", token: "skills.\(agent.id)",
                help: "Show the user skills this agent reads", agent: agent
            )
            .badge(skillCount)
            .tag(Destination.agentSkills(agent))
        }
        if let host = agent.plugins {
            agentItem(
                "Plugins", icon: "puzzlepiece.extension", token: "plugins.\(host.rawValue)",
                help: "Show plugins managed by this host", agent: agent
            )
            .badge(state.pluginInstallations(for: host).count)
            .tag(Destination.plugins(host))
        }
        if let host = agent.hooks {
            agentItem(
                "Hooks", icon: "bolt.horizontal", token: "hooks.\(host.rawValue)",
                help: "Inspect lifecycle hooks configured for this host", agent: agent
            )
            .badge(state.hooks(for: host).count)
            .tag(Destination.hooks(host))
        }
        if let host = agent.addOns {
            agentItem(
                "Extensions", icon: "shippingbox", token: "extensions.\(host.rawValue)",
                help: "Inspect extensions, packages, and plugins this host loads", agent: agent
            )
            .badge(state.extensions(for: host, mcp: false).count)
            .tag(Destination.extensions(host))
        }
        if let host = agent.mcp {
            agentItem(
                "MCP Servers", icon: "server.rack", token: "mcp.\(host.rawValue)",
                help: "Inspect MCP servers this host declares", agent: agent
            )
            .badge(state.extensions(for: host, mcp: true).count)
            .tag(Destination.mcpServers(host))
        }
    }

    private func agentItem(
        _ title: LocalizedStringKey, icon: String, token: String, help: LocalizedStringKey,
        agent: SidebarAgent
    ) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.sidebar.\(token)")
            Label(title, systemImage: icon)
        }
        .accessibilityIdentifier("sukiru.sidebar.\(token)")
        .help(help)
        .contextMenu { agentMenu(agent) }
    }

    /// Reordering stays in the menu and in Settings: the system's drag image
    /// for a vibrant sidebar row drops the vibrancy and renders black in Dark
    /// Mode, while Settings' plain list drags correctly.
    private func agentMenu(_ agent: SidebarAgent) -> some View {
        arrangementMenu(
            agent, in: SidebarAgent.all, arrangement: $agents, available: state.isAvailable)
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
        _ item: Item, in items: [Item], arrangement: Binding<SidebarArrangement>,
        available: @escaping (Item) -> Bool = { _ in true }
    ) -> some View {
        let shown = arrangement.wrappedValue.shown(items, available: available)
        Button("Move Up") {
            arrangement.wrappedValue.move(item, by: -1, in: items, available: available)
        }
        .disabled(shown.first == item)
        Button("Move Down") {
            arrangement.wrappedValue.move(item, by: 1, in: items, available: available)
        }
        .disabled(shown.last == item)
        Divider()
        Button("Hide from Sidebar") { arrangement.wrappedValue.set(item, shown: false, in: items) }
        Button("Customize Sidebar…") { openSettings() }
    }
}

/// Skill totals per sidebar scope, counted the same way the Library list
/// groups them so a badge always matches the rows it leads to.
private struct SkillCounts {
    var all = 0
    var user = 0
    var projects: [String: Int] = [:]
    var agents: [String: Int] = [:]

    @MainActor
    init(state: AppState, agents shownAgents: [SidebarAgent]) {
        let readers = shownAgents.filter(\.readsSkills)
        for skill in state.report?.skills ?? [] {
            if skill.scope == .user {
                user += 1
                all += 1
                for agent in readers where agent.reads(skill, roots: state.agentSkillRoots) {
                    agents[agent.id, default: 0] += 1
                }
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
