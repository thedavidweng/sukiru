import Foundation
import SukiruCore

/// An item a sidebar section can order and hide, keyed by a stable string.
protocol SidebarItem: Hashable {
    var sidebarID: String { get }
}

extension String: SidebarItem {
    var sidebarID: String { self }
}

/// One agent in the sidebar, with every kind of item Sukiru reads for it, so
/// the agent appears once however many kinds it has.
struct SidebarAgent: SidebarItem {
    /// The host table id, also used for agent artwork.
    let id: String
    let name: String
    /// The agent has skills folders in the host table.
    let readsSkills: Bool
    let plugins: PluginHost?
    let hooks: HookHost?
    let addOns: ExtensionHost?
    let mcp: ExtensionHost?

    var sidebarID: String { id }

    /// Every agent, by name. `universal` is the skills CLI's shared store,
    /// not an agent.
    static let all: [SidebarAgent] = {
        let ids =
            HostTable.hosts.map(\.id).filter { $0 != "universal" }
            + PluginHost.allCases.map(\.agentID) + HookHost.allCases.map(\.agentID)
            + ExtensionHost.allCases.map(\.agentID)
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }.map(SidebarAgent.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private init(id: String) {
        let plugins = PluginHost.allCases.first { $0.agentID == id }
        let hooks = HookHost.allCases.first { $0.agentID == id }
        let extensions = ExtensionHost.allCases.first { $0.agentID == id }
        self.id = id
        self.name =
            plugins?.displayName ?? hooks?.displayName ?? extensions?.displayName
            ?? HostTable.host(id: id)?.displayName ?? id
        self.readsSkills = HostTable.host(id: id) != nil
        self.plugins = plugins
        self.hooks = hooks
        self.addOns = extensions.flatMap { ExtensionHost.addOnHosts.contains($0) ? $0 : nil }
        self.mcp = extensions.flatMap { ExtensionHost.mcpHosts.contains($0) ? $0 : nil }
    }

    static func agent(id: String) -> SidebarAgent? { all.first { $0.id == id } }

    /// Whether the skill sits in one of this agent's user skills folders.
    func reads(_ skill: Skill, roots: [String]) -> Bool {
        guard skill.scope == .user else { return false }
        return skill.placements.contains { placement in
            !placement.internal && roots.contains { placement.path.hasPrefix($0 + "/") }
        }
    }
}

/// One sidebar section's order and visibility, so Settings and the sidebar
/// stay in step. Stored with `@AppStorage` as `claude,-codex,+opencode`: a
/// leading `-` hides an item and `+` shows one the sidebar would otherwise
/// leave out (an agent not installed on this Mac); entries are
/// percent-encoded so project paths may contain commas. Items never arranged
/// follow in their given order.
struct SidebarArrangement: RawRepresentable, Equatable {
    static let agentsKey = "sidebarAgents"
    static let projectsKey = "sidebarProjects"
    static let standard = SidebarArrangement(rawValue: "")!

    private static let entryCharacters = CharacterSet.urlPathAllowed.subtracting(
        CharacterSet(charactersIn: ",-+"))

    private var order: [String]
    private var hidden: Set<String>
    private var pinned: Set<String>

    init?(rawValue: String) {
        var order: [String] = []
        var hidden: Set<String> = []
        var pinned: Set<String> = []
        for entry in rawValue.split(separator: ",") {
            guard let id = String(entry.drop { $0 == "-" || $0 == "+" }).removingPercentEncoding,
                !id.isEmpty, !order.contains(id)
            else { continue }
            order.append(id)
            if entry.hasPrefix("-") { hidden.insert(id) }
            if entry.hasPrefix("+") { pinned.insert(id) }
        }
        self.order = order
        self.hidden = hidden
        self.pinned = pinned
    }

    var rawValue: String {
        order.map { id in
            (hidden.contains(id) ? "-" : pinned.contains(id) ? "+" : "")
                + (id.addingPercentEncoding(withAllowedCharacters: Self.entryCharacters) ?? id)
        }.joined(separator: ",")
    }

    /// `items` in the user's order, hidden ones included.
    func arranged<Item: SidebarItem>(_ items: [Item]) -> [Item] {
        let byID = Dictionary(items.map { ($0.sidebarID, $0) }) { first, _ in first }
        return order.compactMap { byID[$0] } + items.filter { !order.contains($0.sidebarID) }
    }

    /// The `items` the sidebar shows, in order. An unavailable item shows only
    /// once the user turns it on.
    func shown<Item: SidebarItem>(
        _ items: [Item], available: (Item) -> Bool = { _ in true }
    ) -> [Item] {
        arranged(items).filter { isShown($0, available: available($0)) }
    }

    func isShown(_ item: some SidebarItem, available: Bool = true) -> Bool {
        pinned.contains(item.sidebarID) || (available && !hidden.contains(item.sidebarID))
    }

    /// Records the choice; only arranged entries are stored, so an item first
    /// arranges its whole section in the order it currently appears.
    mutating func set<Item: SidebarItem>(_ item: Item, shown: Bool, in items: [Item]) {
        if !order.contains(item.sidebarID) {
            let ids = arranged(items).map(\.sidebarID)
            order = ids + order.filter { !ids.contains($0) }
        }
        if shown {
            hidden.remove(item.sidebarID)
            pinned.insert(item.sidebarID)
        } else {
            pinned.remove(item.sidebarID)
            hidden.insert(item.sidebarID)
        }
    }

    /// Drops removed items, so one added again later starts out shown.
    mutating func retain<Item: SidebarItem>(_ items: [Item]) {
        let ids = Set(items.map(\.sidebarID))
        order.removeAll { !ids.contains($0) }
        hidden.formIntersection(ids)
        pinned.formIntersection(ids)
    }

    mutating func move<Item: SidebarItem>(
        _ items: [Item], from source: IndexSet, to destination: Int
    ) {
        var ids = arranged(items).map(\.sidebarID)
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids + order.filter { !ids.contains($0) }
    }

    /// Swaps a shown item with its shown neighbour; hidden items keep their places.
    mutating func move<Item: SidebarItem>(
        _ item: Item, by step: Int, in items: [Item], available: (Item) -> Bool = { _ in true }
    ) {
        var ids = arranged(items).map(\.sidebarID)
        let shownIDs = shown(items, available: available).map(\.sidebarID)
        guard let index = shownIDs.firstIndex(of: item.sidebarID),
            shownIDs.indices.contains(index + step),
            let source = ids.firstIndex(of: item.sidebarID),
            let target = ids.firstIndex(of: shownIDs[index + step])
        else { return }
        ids.swapAt(source, target)
        order = ids + order.filter { !ids.contains($0) }
    }
}

/// An agent is available to the sidebar when it is installed on this Mac or
/// holds a plugin, hook, or add-on the scan found, so leftovers written by
/// other tools stay reachable for cleanup. Skills alone do not count: most
/// agents share `~/.agents/skills`, and Health reports leftover skills
/// folders. The open agent also stays available, so cleaning up its last
/// item does not pull its row out from under the user.
extension AppState {
    nonisolated static func installedAgentIDs(in environment: SukiruEnvironment) -> Set<String> {
        HostDetector(environment: environment, fileSystem: DefaultFileSystemProbe())
            .installedAgentIDs()
    }

    /// The agent's user-scope skills folders, current and legacy. Resolved on
    /// each call: OpenClaw's folder depends on which of its homes exists.
    func userSkillRoots(of agent: SidebarAgent) -> [String] {
        guard let host = HostTable.host(id: agent.id) else { return [] }
        let resolver = HostPathResolver(
            environment: environment, fileSystem: DefaultFileSystemProbe())
        return [resolver.globalSkillsRoot(for: host)] + resolver.legacyGlobalSkillsRoots(for: host)
    }

    /// The agent whose skills, plugins, hooks, or add-ons are on screen.
    var openAgent: SidebarAgent? {
        switch surface {
        case .plugins: return SidebarAgent.agent(id: pluginHost.agentID)
        case .hooks: return SidebarAgent.agent(id: hookState.host.agentID)
        case .extensions: return SidebarAgent.agent(id: hookState.extensionHost.agentID)
        case .library:
            if case .agent(let agent) = libraryScope { return agent }
            return nil
        default: return nil
        }
    }

    func isAvailable(_ agent: SidebarAgent) -> Bool {
        detectedAgentIDs.contains(agent.id) || openAgent == agent
            || agent.plugins.map(holdsItems) == true || agent.hooks.map(holdsItems) == true
            || agent.addOns.map { !extensions(for: $0, mcp: false).isEmpty } == true
            || agent.mcp.map { !extensions(for: $0, mcp: true).isEmpty } == true
    }

    private func holdsItems(_ host: PluginHost) -> Bool {
        let inventory = report?.pluginInventory
        return !pluginInstallations(for: host).isEmpty
            || inventory?.marketplaces.contains { $0.host == host } == true
            || inventory?.issues.contains { $0.host == host } == true
    }

    private func holdsItems(_ host: HookHost) -> Bool {
        !hooks(for: host).isEmpty
            || report?.hookInventory?.issues.contains { $0.host == host } == true
    }
}
