import Foundation
import Testing

@testable import SukiruCore

/// Cursor's marketplace page adds two reads that are not on disk: Cursor's own
/// registrations and the official catalog in the `cursor/plugins` repository.
struct CursorMarketplaceCatalogTests {
    @Test("Official listings link to their directory in the Cursor plugins repository")
    func officialListings() async throws {
        let tree = try TempTree()
        let catalog = try await load(
            home: tree.dir("home"),
            registrations: "[]",
            official: """
                {"name":"cursor-plugins","owner":{"name":"Cursor"},"plugins":[
                  {"name":"teaching","source":"teaching","description":"Skill mapping."},
                  {"name":"remote","source":"https://example.com/remote.git"}]}
                """)
        let official = try #require(catalog.marketplaces.first)
        #expect(catalog.marketplaces.count == 1)
        #expect(official.isCursorOfficialCatalog)
        #expect(official.name == CursorMarketplaceLoader.officialName)
        #expect(official.displayName == "Cursor Plugin Marketplace")
        #expect(official.scope == "global")
        #expect(official.plugins.map(\.name) == ["teaching", "remote"])
        #expect(official.plugins[0].summary == "Skill mapping.")
        #expect(official.plugins[0].author == "Cursor")
        #expect(
            official.plugins[0].repository
                == "https://github.com/cursor/plugins/tree/main/teaching")
        // A source that is not a directory in that repository gets no link.
        #expect(official.plugins[1].repository == nil)
    }

    @Test("A registration without a cached catalog is listed as not cached")
    func registeredWithoutCache() async throws {
        let tree = try TempTree()
        let catalog = try await load(
            home: tree.dir("home"),
            registrations: """
                [{"name":"vercel","gitUrl":"https://github.com/vercel/vercel-plugin",
                  "gitRef":"b4803caa","scope":"user"}]
                """,
            official: nil)
        let registered = try #require(catalog.marketplaces.first)
        #expect(catalog.marketplaces.count == 1)
        #expect(registered.isCursorRegistration)
        #expect(registered.path == nil)
        #expect(registered.plugins.isEmpty)
        #expect(registered.source == "https://github.com/vercel/vercel-plugin")
        #expect(registered.ref == "b4803caa")
        #expect(registered.scope == "user")
        #expect(!catalog.registrationsUnavailable)
        #expect(catalog.officialUnavailable)
    }

    @Test("A cached catalog Cursor has not registered is not listed")
    func cachedButUnregistered() async throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.cursor/plugins/marketplaces/github.com/example/other/abc/.cursor-plugin/marketplace.json",
            contents: #"{"name":"other","plugins":[{"name":"demo","source":"./demo"}]}"#)
        let catalog = try await load(
            home: home,
            registrations: """
                [{"name":"vercel","gitUrl":"https://github.com/vercel/vercel-plugin","scope":"user"}]
                """,
            official: nil)
        #expect(catalog.marketplaces.map(\.name) == ["vercel"])
        #expect(catalog.marketplaces.first?.plugins.isEmpty == true)
    }

    @Test("A registered marketplace lists the catalog Cursor checked out for its commit")
    func registeredWithCache() async throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let commit = "004256cdc6281a385f1cf7ae80ccdf584bde6554"
        try tree.file(
            "home/.cursor/plugins/marketplaces/github.com/DietrichGebert/ponytail/"
                + "\(commit)/.claude-plugin/marketplace.json",
            contents: """
                {"name":"ponytail","plugins":[
                  {"name":"ponytail","source":"./","description":"Lazy senior dev mode."}]}
                """)
        let catalog = try await load(
            home: home,
            registrations: """
                [{"name":"ponytail","gitUrl":"https://github.com/DietrichGebert/ponytail",
                  "gitRef":"\(commit)","scope":"user"}]
                """,
            official: nil)
        let registered = try #require(catalog.marketplaces.first)
        #expect(registered.evidence == "registered-catalog")
        #expect(registered.source == "https://github.com/DietrichGebert/ponytail")
        #expect(registered.plugins.map(\.name) == ["ponytail"])
        #expect(registered.plugins.first?.summary == "Lazy senior dev mode.")
        #expect(registered.path?.hasSuffix(commit) == true)
        // The listing is the repository root, so it links to the registered repository.
        #expect(
            registered.plugins.first?.repository
                == "https://github.com/DietrichGebert/ponytail")
    }

    @Test("An unreadable registration list leaves the official catalog usable")
    func registrationsUnavailable() async throws {
        let tree = try TempTree()
        let catalog = try await load(
            home: tree.dir("home"),
            registrations: nil,
            official: #"{"name":"cursor-plugins","plugins":[{"name":"x","source":"x"}]}"#)
        #expect(catalog.registrationsUnavailable)
        #expect(!catalog.officialUnavailable)
        #expect(catalog.marketplaces.count == 1)
        #expect(catalog.marketplaces.first?.isCursorOfficialCatalog == true)
    }

    @Test("An unreachable official catalog leaves the registrations usable")
    func officialCatalogUnavailable() async throws {
        let tree = try TempTree()
        let catalog = try await load(
            home: tree.dir("home"),
            registrations: """
                [{"name":"ponytail","gitUrl":"https://github.com/DietrichGebert/ponytail",
                  "scope":"user"}]
                """,
            official: nil)
        #expect(catalog.officialUnavailable)
        #expect(!catalog.registrationsUnavailable)
        #expect(catalog.marketplaces.map(\.name) == ["ponytail"])
    }

    @Test("A malformed catalog is a failure rather than a partial listing")
    func malformedOfficialCatalog() async throws {
        let tree = try TempTree()
        let catalog = try await load(
            home: tree.dir("home"), registrations: "[]", official: #"{"plugins":[42]}"#)
        #expect(catalog.officialUnavailable)
        #expect(catalog.marketplaces.isEmpty)
    }

    @Test("Registration output outside Cursor's documented shape is refused")
    func registrationDecoding() throws {
        #expect(throws: PluginLifecycleError.self) {
            try CursorMarketplaceRegistration.decode("not json")
        }
        #expect(throws: PluginLifecycleError.self) {
            try CursorMarketplaceRegistration.decode(
                #"[{"name":"team","gitUrl":"https://example.com/t.git","scope":"workspace"}]"#)
        }
        let registrations = try CursorMarketplaceRegistration.decode(
            """
            [{"name":"cursor-public","displayName":"Cursor Plugin Marketplace","gitUrl":"",
              "scope":"global"}]
            """)
        #expect(registrations.first?.displayName == "Cursor Plugin Marketplace")
        #expect(registrations.first?.gitUrl.isEmpty == true)
    }

    @Test("A cached official plugin marks its listing as installed")
    func officialInstallationMarker() throws {
        let marketplace = PluginMarketplace(
            host: .cursor, name: CursorMarketplaceLoader.officialName,
            source: "https://github.com/cursor/plugins", scopeRoot: "/Users/example",
            path: nil,
            plugins: [PluginCatalogEntry(name: "github", source: "github", version: nil)],
            evidence: "official-catalog", scope: "global")
        let listing = try #require(marketplace.plugins.first)
        let installed = Self.installation(name: "github", source: "cursor-public")
        let elsewhere = Self.installation(name: "github", source: "personal")
        #expect(Self.inventory([installed]).cursorHasInstalled(listing, in: marketplace))
        #expect(!Self.inventory([elsewhere]).cursorHasInstalled(listing, in: marketplace))
        #expect(
            !Self.inventory([Self.installation(name: "cloudflare", source: "cursor-public")])
                .cursorHasInstalled(listing, in: marketplace))
    }

}

extension CursorMarketplaceCatalogTests {
    static func environment(home: String) -> SukiruEnvironment {
        SukiruEnvironment(
            reader: DictionaryEnvironmentReader([SukiruEnvironment.sukiruHomeKey: home]))
    }

    static func loader(
        home: String, transport: any MarketplaceTransport,
        registrations: StubRegistrations
    ) -> CursorMarketplaceLoader {
        CursorMarketplaceLoader(
            environment: environment(home: home), transport: transport,
            registrations: registrations)
    }

    private func load(
        home: String, registrations: String?, official: String?
    ) async throws -> CursorMarketplaceCatalog {
        var responses: [String: Result<Data, MarketplaceError>] = [:]
        if let official {
            responses[CursorMarketplaceLoader.officialCatalogURL.absoluteString] = .success(
                Data(official.utf8))
        }
        return await Self.loader(
            home: home, transport: StubMarketplaceTransport(responses: responses),
            registrations: StubRegistrations(
                listed: try registrations.map { try CursorMarketplaceRegistration.decode($0) })
        ).load()
    }

    private static func installation(name: String, source: String) -> PluginInstallation {
        PluginInstallation(
            host: .cursor, source: source, identifier: name, scope: "user",
            scopeRoot: "/Users/example", version: nil,
            path: "/Users/example/.cursor/plugins/cache/\(source)/\(name)",
            enablement: .unknown, loadStatus: "unknown", components: [],
            installationStatus: "cached", format: "cursor-plugin")
    }

    private static func inventory(_ installations: [PluginInstallation]) -> PluginInventory {
        PluginInventory(installations: installations, marketplaces: [], issues: [])
    }
}

struct StubRegistrations: CursorMarketplaceRegistrations {
    var listed: [CursorMarketplaceRegistration]?
    var stored: [CursorMarketplaceRegistration]?

    func read() -> [CursorMarketplaceRegistration]? { listed }
    func cached() -> [CursorMarketplaceRegistration]? { stored }
}

/// Records the cache policy of each request and answers per policy, so a test can assert
/// that the stored read is requested before the revalidation.
final class RecordingTransport: MarketplaceTransport, @unchecked Sendable {
    let responses: [URLRequest.CachePolicy: Result<Data, MarketplaceError>]
    private let queue = DispatchQueue(label: "app.sukiru.test.recorded-policies")
    private var recorded: [URLRequest.CachePolicy] = []

    init(responses: [URLRequest.CachePolicy: Result<Data, MarketplaceError>]) {
        self.responses = responses
    }

    var policies: [URLRequest.CachePolicy] { queue.sync { recorded } }

    func fetch(_ url: URL, cachePolicy: URLRequest.CachePolicy) async throws -> Data {
        queue.sync { recorded.append(cachePolicy) }
        guard let response = responses[cachePolicy] else {
            throw MarketplaceError.transport("no stub for policy \(cachePolicy.rawValue)")
        }
        return try response.get()
    }
}
