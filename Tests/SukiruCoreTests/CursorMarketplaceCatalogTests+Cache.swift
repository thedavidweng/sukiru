import Foundation
import Testing

@testable import SukiruCore

/// The paint-then-revalidate cache in front of Cursor's two marketplace sources.
extension CursorMarketplaceCatalogTests {
    @Test("The stored registrations round-trip, and an unreadable file is nothing")
    func registrationStore() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let store = CursorRegistrationStore(environment: Self.environment(home: home))
        #expect(store.read() == nil)

        let registrations = [
            CursorMarketplaceRegistration(
                name: "ponytail", gitUrl: "https://github.com/DietrichGebert/ponytail",
                scope: "user", gitRef: "b0e1", displayName: "Ponytail"),
            CursorMarketplaceRegistration(
                name: "cursor-public", gitUrl: "", scope: "global", gitRef: nil,
                displayName: "Cursor Plugin Marketplace")
        ]
        store.write(registrations)

        #expect(
            store.path
                == HostPathResolver.join(
                    home, "Library/Caches/app.sukiru/cursor-registrations.json"))
        #expect(
            store.read()?.map {
                "\($0.name)|\($0.gitUrl)|\($0.scope)|\($0.gitRef ?? "")|\($0.displayName ?? "")"
            }
                == [
                    "ponytail|https://github.com/DietrichGebert/ponytail|user|b0e1|Ponytail",
                    "cursor-public||global||Cursor Plugin Marketplace"
                ])

        try "truncated".write(toFile: store.path, atomically: true, encoding: .utf8)
        #expect(store.read() == nil)
    }

    @Test("A failed read keeps the marketplaces the last read stored")
    func failedReadKeepsStoredData() async throws {
        let tree = try TempTree()
        let catalog = await Self.loader(
            home: try tree.dir("home"),
            transport: StubMarketplaceTransport(responses: [
                CursorMarketplaceLoader.officialCatalogURL.absoluteString: .success(
                    Data(#"{"plugins":[{"name":"x","source":"x"}]}"#.utf8))
            ]),
            registrations: StubRegistrations(
                stored: try CursorMarketplaceRegistration.decode(
                    """
                    [{"name":"ponytail","gitUrl":"https://github.com/DietrichGebert/ponytail",
                      "scope":"user"}]
                    """))
        ).load()

        #expect(catalog.registrationsUnavailable)
        #expect(!catalog.officialUnavailable)
        #expect(catalog.marketplaces.map(\.name) == ["cursor-public", "ponytail"])
    }

    @Test("An unreachable catalog falls back to its stored copy and still reports the failure")
    func officialCatalogStoredFallback() async throws {
        let tree = try TempTree()
        let transport = RecordingTransport(responses: [
            .useProtocolCachePolicy: .failure(.transport("offline")),
            .returnCacheDataDontLoad: .success(
                Data(#"{"plugins":[{"name":"x","source":"x"}]}"#.utf8))
        ])
        let catalog = await Self.loader(
            home: try tree.dir("home"), transport: transport, registrations: StubRegistrations()
        ).load()

        #expect(catalog.officialUnavailable)
        #expect(catalog.marketplaces.first?.isCursorOfficialCatalog == true)
        #expect(transport.policies == [.useProtocolCachePolicy, .returnCacheDataDontLoad])
    }

    @Test("The stored read paints first and the revalidation replaces it")
    func cachedThenFresh() async throws {
        let tree = try TempTree()
        let transport = RecordingTransport(responses: [
            .returnCacheDataDontLoad: .success(
                Data(#"{"plugins":[{"name":"stored","source":"stored"}]}"#.utf8)),
            .useProtocolCachePolicy: .success(
                Data(#"{"plugins":[{"name":"fresh","source":"fresh"}]}"#.utf8))
        ])
        let loader = Self.loader(
            home: try tree.dir("home"), transport: transport,
            registrations: StubRegistrations(
                stored: try CursorMarketplaceRegistration.decode(
                    #"[{"name":"ponytail","gitUrl":"https://example.com/t.git","scope":"user"}]"#)))

        let painted = try #require(await loader.cached())
        #expect(painted.marketplaces.map(\.name) == ["cursor-public", "ponytail"])
        #expect(painted.marketplaces.first?.plugins.map(\.name) == ["stored"])
        // A painted catalog claims no failure: it is a display state, not a read result.
        #expect(!painted.registrationsUnavailable)
        #expect(!painted.officialUnavailable)

        let fresh = await loader.load()
        #expect(fresh.marketplaces.map(\.name) == ["cursor-public", "ponytail"])
        #expect(fresh.marketplaces.first?.plugins.map(\.name) == ["fresh"])
        #expect(transport.policies == [.returnCacheDataDontLoad, .useProtocolCachePolicy])
    }

    @Test("A first open has nothing stored to paint")
    func nothingStored() async throws {
        let tree = try TempTree()
        let loader = Self.loader(
            home: try tree.dir("home"),
            transport: StubMarketplaceTransport(responses: [
                CursorMarketplaceLoader.officialCatalogURL.absoluteString: .failure(
                    .transport("offline"))
            ]),
            registrations: StubRegistrations())
        #expect((await loader.cached())?.marketplaces.isEmpty ?? true)
    }
}
