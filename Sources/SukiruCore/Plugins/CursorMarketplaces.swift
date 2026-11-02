import Foundation

/// Cursor's marketplace page has two sources that are not on disk: Cursor's own list of
/// registered marketplaces (account-level, through the installed `agent`) and the official
/// catalog published in the `cursor/plugins` repository. Both are read when the user opens
/// that page or refreshes it; the last read stays in a purgeable cache so the page paints at
/// once (ADR-0008).
public struct CursorMarketplaceCatalog: Sendable {
    public internal(set) var marketplaces: [PluginMarketplace] = []
    /// `agent plugin marketplace list` did not answer, so Cursor's registrations are unknown.
    public internal(set) var registrationsUnavailable = false
    /// The official catalog could not be revalidated; a stored copy may still be listed.
    public internal(set) var officialUnavailable = false
}

/// Reads those two sources and matches them against the catalogs Cursor has cached locally.
/// Partial results stand: each source reports its own failure.
public struct CursorMarketplaceLoader: Sendable {
    /// The official catalog Cursor publishes in its public plugins repository.
    public static let officialCatalogURL = URL(
        string:
            "https://raw.githubusercontent.com/cursor/plugins/main/.cursor-plugin/marketplace.json")!
    /// Cursor's own registration of that catalog; plugins installed from it are cached
    /// under this folder name.
    public static let officialName = "cursor-public"
    /// Cursor's product name for the official marketplace, when its registration omits one.
    static let officialDisplayName = "Cursor Plugin Marketplace"

    let environment: SukiruEnvironment
    let transport: any MarketplaceTransport
    let registrations: any CursorMarketplaceRegistrations

    public init(environment: SukiruEnvironment) {
        self.environment = environment
        transport = URLSessionMarketplaceTransport()
        registrations = AgentMarketplaceRegistrations(environment: environment)
    }

    init(
        environment: SukiruEnvironment, transport: any MarketplaceTransport,
        registrations: any CursorMarketplaceRegistrations
    ) {
        self.environment = environment
        self.transport = transport
        self.registrations = registrations
    }

    /// Reads both sources and stores what answered, so the next open paints at once.
    public func load() async -> CursorMarketplaceCatalog {
        let read = registrations.read()
        // A source that failed keeps the last stored answer: the page shows what it has
        // plus that source's failure line, never an empty page in place of a stale one.
        let registered = read ?? registrations.cached()
        var catalog = CursorMarketplaceCatalog()
        catalog.registrationsUnavailable = read == nil
        catalog.marketplaces = registrationMarketplaces(registered)
        var official = await officialCatalog(registered, cachePolicy: .useProtocolCachePolicy)
        if official == nil {
            catalog.officialUnavailable = true
            official = await officialCatalog(registered, cachePolicy: .returnCacheDataDontLoad)
        }
        if let official { catalog.marketplaces.insert(official, at: 0) }
        return catalog
    }

    /// The last read on this Mac, without starting `agent` or revalidating the catalog.
    /// nil on a first open, and a source with nothing stored simply stays out.
    public func cached() async -> CursorMarketplaceCatalog? {
        let registered = registrations.cached()
        let official = await officialCatalog(registered, cachePolicy: .returnCacheDataDontLoad)
        guard registered != nil || official != nil else { return nil }
        var catalog = CursorMarketplaceCatalog()
        catalog.marketplaces = registrationMarketplaces(registered)
        if let official { catalog.marketplaces.insert(official, at: 0) }
        return catalog
    }

    private func registrationMarketplaces(
        _ registrations: [CursorMarketplaceRegistration]?
    ) -> [PluginMarketplace] {
        let reader = PluginInventoryReader(environment: environment)
        var issues: [Issue] = []
        let cached = reader.cursorCatalogs(issues: &issues)
        return (registrations ?? [])
            .filter { $0.name != Self.officialName }
            .map { registeredMarketplace($0, cached: cached, reader: reader) }
    }

    private func registeredMarketplace(
        _ registration: CursorMarketplaceRegistration, cached: [PluginMarketplace],
        reader: PluginInventoryReader
    ) -> PluginMarketplace {
        let payload = cachedPayload(for: registration, in: cached)
        return reader.withPluginDetails(
            PluginMarketplace(
                host: .cursor, name: registration.name, source: registration.gitUrl,
                scopeRoot: environment.home, path: payload?.path,
                plugins: payload?.plugins ?? [],
                evidence: payload == nil ? "registered" : "registered-catalog",
                scope: registration.scope, ref: registration.gitRef))
    }

    /// Cursor checks a Git marketplace out under `<host>/<path>/<commit>`, so a registration's
    /// URL names the folder its cached catalog lives in.
    private func cachedPayload(
        for registration: CursorMarketplaceRegistration, in cached: [PluginMarketplace]
    ) -> PluginMarketplace? {
        guard let directory = Self.cacheDirectory(registration.gitUrl) else { return nil }
        let root = HostPathResolver.join(environment.home, ".cursor/plugins/marketplaces")
        let matches = cached.filter { marketplace in
            guard let path = Self.relativePath(marketplace.source, under: root) else {
                return false
            }
            let normalized = path.lowercased()
            return normalized == directory || normalized.hasPrefix(directory + "/")
        }.sorted { $0.source < $1.source }
        // The registration's own commit identifies its checkout; a single cached payload
        // is the only one there is.
        return matches.first { $0.ref == registration.gitRef } ?? matches.first
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(boundary + "/") else { return nil }
        return String(resolved.dropFirst(boundary.count + 1))
    }

    private static func cacheDirectory(_ gitUrl: String) -> String? {
        guard let url = URL(string: gitUrl), let host = url.host, !host.isEmpty,
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty else { return nil }
        return (host + "/" + path).lowercased()
    }

    private func officialCatalog(
        _ registered: [CursorMarketplaceRegistration]?, cachePolicy: URLRequest.CachePolicy
    ) async -> PluginMarketplace? {
        guard
            let data = try? await transport.fetch(
                Self.officialCatalogURL, cachePolicy: cachePolicy),
            let entries = Self.officialEntries(data)
        else { return nil }
        let registration = registered?.first { $0.name == Self.officialName }
        var marketplace = PluginMarketplace(
            host: .cursor, name: Self.officialName, source: "https://github.com/cursor/plugins",
            scopeRoot: environment.home, path: nil, plugins: entries,
            evidence: "official-catalog", scope: registration?.scope ?? "global")
        marketplace.displayName =
            registration?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.officialDisplayName
        return marketplace
    }

    /// Every published entry names a directory in the repository, so the listing links there
    /// instead of inventing a version. A malformed catalog yields nil, never partial data.
    static func officialEntries(_ data: Data) -> [PluginCatalogEntry]? {
        guard let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = catalog["plugins"] as? [Any]
        else { return nil }
        let owner = (catalog["owner"] as? [String: Any])?["name"] as? String
        let listings: [PluginCatalogEntry] = entries.compactMap { value in
            guard let entry = value as? [String: Any],
                let name = entry["name"] as? String, !name.isEmpty,
                let source = entry["source"] as? String, !source.isEmpty
            else { return nil }
            var listing = PluginCatalogEntry(name: name, source: source, version: nil)
            listing.summary = entry["description"] as? String
            listing.author = (entry["author"] as? [String: Any])?["name"] as? String ?? owner
            listing.repository = officialRepositoryLink(source)
            if let logo = entry["logo"] as? String, logo.hasPrefix("https://") {
                listing.logo = logo
            }
            return listing
        }
        return listings.isEmpty ? nil : listings
    }

    /// A relative source is a directory in the `cursor/plugins` repository.
    static func officialRepositoryLink(_ source: String) -> String? {
        let path = source.hasPrefix("./") ? String(source.dropFirst(2)) : source
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":") else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "https://github.com/cursor/plugins/tree/main/" + encoded
    }
}

/// One entry of `agent plugin marketplace list --format json`: a marketplace Cursor itself
/// has registered. `name`, `gitUrl` and `scope` are the fields Sukiru acts on; the rest is
/// display or indexing metadata.
struct CursorMarketplaceRegistration: Codable, Sendable {
    let name: String
    let gitUrl: String
    let scope: String
    let gitRef: String?
    let displayName: String?

    /// Anything outside the documented registrations blocks the read.
    static func decode(_ output: String) throws -> [Self] {
        guard
            let registrations = try? JSONDecoder().decode([Self].self, from: Data(output.utf8))
        else {
            throw PluginLifecycleError(
                message: "Unrecognized Cursor marketplace JSON output; use Customize")
        }
        guard
            registrations.allSatisfy({
                !$0.name.isEmpty && ["user", "team", "global"].contains($0.scope)
            })
        else {
            throw PluginLifecycleError(
                message: "Unrecognized Cursor marketplace JSON registration; use Customize")
        }
        return registrations
    }
}

/// Cursor's account-level marketplace registrations, injectable so catalog assembly is
/// testable without the account's CLI.
protocol CursorMarketplaceRegistrations: Sendable {
    /// nil when the installed `agent` cannot list them.
    func read() -> [CursorMarketplaceRegistration]?
    /// What the last successful read stored; starts no process.
    func cached() -> [CursorMarketplaceRegistration]?
}

/// The registrations Cursor last reported, in Sukiru's purgeable cache: the same folder as
/// the app's HTTP cache, so deleting it only costs a slower first paint.
struct CursorRegistrationStore: Sendable {
    let environment: SukiruEnvironment

    var path: String {
        HostPathResolver.join(
            environment.home, "Library/Caches/app.sukiru/cursor-registrations.json")
    }

    func read() -> [CursorMarketplaceRegistration]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([CursorMarketplaceRegistration].self, from: data)
    }

    func write(_ registrations: [CursorMarketplaceRegistration]) {
        guard let data = try? JSONEncoder().encode(registrations) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Reads the structured output registration targeting already uses, after the same version
/// and list-help gates, so a missing `agent` or another product's binary fails closed.
struct AgentMarketplaceRegistrations: CursorMarketplaceRegistrations {
    let environment: SukiruEnvironment

    private var store: CursorRegistrationStore { CursorRegistrationStore(environment: environment) }

    func cached() -> [CursorMarketplaceRegistration]? { store.read() }

    func read() -> [CursorMarketplaceRegistration]? {
        let probe = PluginLifecycleProbe(environment: environment)
        guard (try? probe.version(host: .cursor)) != nil,
            (try? probe.help(
                host: .cursor, arguments: ["plugin", "marketplace", "list"],
                requiredFlags: ["Usage:", "plugin marketplace list", "--format", "json"])) != nil,
            let output = try? probe.output(
                host: .cursor, arguments: ["plugin", "marketplace", "list", "--format", "json"]),
            let registrations = try? CursorMarketplaceRegistration.decode(output)
        else { return nil }
        store.write(registrations)
        return registrations
    }
}

extension PluginMarketplace {
    /// The official catalog Cursor publishes in its `cursor/plugins` repository.
    public var isCursorOfficialCatalog: Bool { host == .cursor && evidence == "official-catalog" }

    /// A marketplace Cursor itself has registered, whether or not its catalog is cached here.
    public var isCursorRegistration: Bool {
        host == .cursor && (evidence == "registered" || evidence == "registered-catalog")
    }
}
