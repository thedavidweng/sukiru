import Foundation
import SukiruCore

/// An item a sidebar section can order and hide, keyed by a stable string.
protocol SidebarItem: Hashable {
    var sidebarID: String { get }
}

extension String: SidebarItem {
    var sidebarID: String { self }
}

extension PluginHost: SidebarItem {
    var sidebarID: String { rawValue }
}

extension HookHost: SidebarItem {
    var sidebarID: String { rawValue }
}

extension ExtensionHost: SidebarItem {
    var sidebarID: String { rawValue }
}

/// One sidebar section's order and visibility, so Settings and the sidebar
/// stay in step. Stored with `@AppStorage` as `claude,-codex,+opencode`: a
/// leading `-` hides an item and `+` shows one the sidebar would otherwise
/// leave out (an agent not installed on this Mac); entries are
/// percent-encoded so project paths may contain commas. Items never arranged
/// follow in their given order.
struct SidebarArrangement: RawRepresentable, Equatable {
    static let pluginHostsKey = "sidebarPluginHosts"
    static let hookHostsKey = "sidebarHookHosts"
    static let extensionHostsKey = "sidebarExtensionHosts"
    static let mcpHostsKey = "sidebarMCPHosts"
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
/// holds something the scan found, so leftovers written by other tools stay
/// reachable for cleanup. The open agent also stays available, so cleaning
/// up its last item does not pull its row out from under the user.
extension AppState {
    nonisolated static func installedAgentIDs(in environment: SukiruEnvironment) -> Set<String> {
        HostDetector(environment: environment, fileSystem: DefaultFileSystemProbe())
            .installedAgentIDs()
    }

    func isAvailable(_ host: PluginHost) -> Bool {
        let inventory = report?.pluginInventory
        return (surface == .plugins && pluginHost == host)
            || detectedAgentIDs.contains(host.agentID)
            || !pluginInstallations(for: host).isEmpty
            || inventory?.marketplaces.contains { $0.host == host } == true
            || inventory?.issues.contains { $0.host == host } == true
    }

    func isAvailable(_ host: HookHost) -> Bool {
        (surface == .hooks && hookState.host == host)
            || detectedAgentIDs.contains(host.agentID) || !hooks(for: host).isEmpty
            || report?.hookInventory?.issues.contains { $0.host == host } == true
    }

    func isAvailable(_ host: ExtensionHost, mcp: Bool) -> Bool {
        (surface == .extensions && hookState.showsMCP == mcp && hookState.extensionHost == host)
            || detectedAgentIDs.contains(host.agentID) || !extensions(for: host, mcp: mcp).isEmpty
    }
}
