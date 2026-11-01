import SukiruCore

extension PluginMarketplace {
    func catalogID(_ entry: PluginCatalogEntry) -> String { id + "\n" + entry.name }
}

extension PluginCatalogEntry {
    var title: String { displayName ?? name }

    func matches(_ filter: String) -> Bool {
        filter.isEmpty
            || ([name, displayName, summary] + (keywords ?? []).map(Optional.some))
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(filter) }
    }
}

extension AppState {
    var selectedCatalogEntry: (entry: PluginCatalogEntry, marketplace: PluginMarketplace)? {
        guard let id = selectedCatalogEntryID else { return nil }
        for marketplace in report?.pluginInventory?.marketplaces ?? []
        where marketplace.host == pluginHost {
            if let entry = marketplace.plugins.first(where: { marketplace.catalogID($0) == id }) {
                return (entry, marketplace)
            }
        }
        return nil
    }
}
