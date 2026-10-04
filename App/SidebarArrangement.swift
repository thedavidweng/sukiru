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

    /// Hosts whose lifecycle hooks Sukiru reads.
    static let hookHosts: [PluginHost] = [.claude, .codex]
}

/// One sidebar section's order and hidden items, so Settings and the sidebar
/// stay in step. Stored with `@AppStorage` as `claude,-codex,opencode`: a
/// leading `-` hides an item, and entries are percent-encoded so project
/// paths may contain commas. Items never arranged follow in their given order.
struct SidebarArrangement: RawRepresentable, Equatable {
    static let pluginHostsKey = "sidebarPluginHosts"
    static let hookHostsKey = "sidebarHookHosts"
    static let projectsKey = "sidebarProjects"
    static let standard = SidebarArrangement(rawValue: "")!

    private static let entryCharacters = CharacterSet.urlPathAllowed.subtracting(
        CharacterSet(charactersIn: ",-"))

    private var order: [String]
    private var hidden: Set<String>

    init?(rawValue: String) {
        var order: [String] = []
        var hidden: Set<String> = []
        for entry in rawValue.split(separator: ",") {
            let isHidden = entry.hasPrefix("-")
            guard let id = String(entry.drop { $0 == "-" }).removingPercentEncoding,
                !id.isEmpty, !order.contains(id)
            else { continue }
            order.append(id)
            if isHidden { hidden.insert(id) }
        }
        self.order = order
        self.hidden = hidden
    }

    var rawValue: String {
        order.map { id in
            (hidden.contains(id) ? "-" : "")
                + (id.addingPercentEncoding(withAllowedCharacters: Self.entryCharacters) ?? id)
        }.joined(separator: ",")
    }

    /// `items` in the user's order, hidden ones included.
    func arranged<Item: SidebarItem>(_ items: [Item]) -> [Item] {
        let byID = Dictionary(items.map { ($0.sidebarID, $0) }) { first, _ in first }
        return order.compactMap { byID[$0] } + items.filter { !order.contains($0.sidebarID) }
    }

    /// The `items` the sidebar shows, in order.
    func shown<Item: SidebarItem>(_ items: [Item]) -> [Item] {
        arranged(items).filter { !hidden.contains($0.sidebarID) }
    }

    func isShown(_ item: some SidebarItem) -> Bool { !hidden.contains(item.sidebarID) }

    mutating func set(_ item: some SidebarItem, shown: Bool) {
        if shown { hidden.remove(item.sidebarID) } else { hidden.insert(item.sidebarID) }
    }

    /// Drops removed items, so one added again later starts out shown.
    mutating func retain<Item: SidebarItem>(_ items: [Item]) {
        let ids = Set(items.map(\.sidebarID))
        order.removeAll { !ids.contains($0) }
        hidden.formIntersection(ids)
    }

    mutating func move<Item: SidebarItem>(
        _ items: [Item], from source: IndexSet, to destination: Int
    ) {
        var ids = arranged(items).map(\.sidebarID)
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids + order.filter { !ids.contains($0) }
    }

    /// Swaps a shown item with its shown neighbour; hidden items keep their places.
    mutating func move<Item: SidebarItem>(_ item: Item, by step: Int, in items: [Item]) {
        var ids = arranged(items).map(\.sidebarID)
        let shownIDs = shown(items).map(\.sidebarID)
        guard let index = shownIDs.firstIndex(of: item.sidebarID),
            shownIDs.indices.contains(index + step),
            let source = ids.firstIndex(of: item.sidebarID),
            let target = ids.firstIndex(of: shownIDs[index + step])
        else { return }
        ids.swapAt(source, target)
        order = ids + order.filter { !ids.contains($0) }
    }
}
