import Foundation
import SukiruCore

/// Cursor's marketplace page reads Cursor's own registrations and its official catalog. The
/// last read is painted from Sukiru's purgeable cache and then revalidated (ADR-0008).
struct CursorCatalogState {
    /// Reading with nothing to paint: the page has never shown Cursor's marketplaces.
    var loading = false
    var loaded = false
    /// A read is in flight, so another open or Refresh does not start a second one.
    var revalidating = false
    var marketplaces: [PluginMarketplace] = []
    var registrationsUnavailable = false
    var officialUnavailable = false
}

extension AppState {
    /// Refresh (toolbar and ⌘R): re-reads everything Sukiru shows from disk, the library
    /// and the batch history. On Cursor's marketplace page it also re-reads that page's two
    /// sources; a launch or a scan never does (ADR-0008).
    func refresh() {
        rescan()
        loadHistory()
        if surface == .plugins, showsPluginMarketplace, pluginHost == .cursor {
            loadCursorMarketplaces()
        }
    }

    /// What the Marketplace page shows for a host. Cursor's page lists only what Cursor
    /// registers; a cached catalog alone would read as the whole marketplace.
    func pluginMarketplaces(for host: PluginHost) -> [PluginMarketplace] {
        if host == .cursor { return cursorCatalog.marketplaces }
        return (report?.pluginInventory?.marketplaces ?? []).filter { $0.host == host }
    }

    /// Reads Cursor's account-level registrations and fetches the official catalog, when the
    /// user opens Cursor's marketplace page or refreshes it: the stored read paints first,
    /// then the fresh one replaces it.
    func loadCursorMarketplaces() {
        guard !cursorCatalog.revalidating else { return }
        cursorCatalog.revalidating = true
        let environment = Self.makeEnvironment(roots: projectRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            let loader = CursorMarketplaceLoader(environment: environment)
            let cached = await loader.cached()
            await MainActor.run { self?.beginCursorCatalog(cached) }
            let fresh = await loader.load()
            await MainActor.run { self?.finishCursorCatalog(fresh) }
        }
    }

    /// The stored read only shows progress when it has nothing to paint; a revalidation
    /// never flashes a spinner over the marketplaces already on screen.
    private func beginCursorCatalog(_ cached: CursorMarketplaceCatalog?) {
        guard let cached else {
            cursorCatalog.loading = cursorCatalog.marketplaces.isEmpty
            return
        }
        paintCursorCatalog(cached)
    }

    private func finishCursorCatalog(_ catalog: CursorMarketplaceCatalog) {
        paintCursorCatalog(catalog)
        cursorCatalog.revalidating = false
    }

    private func paintCursorCatalog(_ catalog: CursorMarketplaceCatalog) {
        cursorCatalog.loaded = true
        cursorCatalog.loading = false
        cursorCatalog.marketplaces = catalog.marketplaces
        cursorCatalog.registrationsUnavailable = catalog.registrationsUnavailable
        cursorCatalog.officialUnavailable = catalog.officialUnavailable
    }
}
