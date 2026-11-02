import Foundation
import Testing

@testable import SukiruCore

@Suite("Plugin catalog details")
struct PluginCatalogDetailsTests {
    let reader = PluginInventoryReader(
        environment: SukiruEnvironment(reader: DictionaryEnvironmentReader([:])))

    func marketplace(
        _ root: String, entries: [PluginCatalogEntry], source: String = "owner/market",
        sourceType: String? = "github", local: Bool = false
    ) -> PluginMarketplace {
        PluginMarketplace(
            host: .droid, name: "market", source: source, scopeRoot: "/", path: root,
            plugins: entries, ref: nil, localSource: local, sourceType: sourceType)
    }

    @Test("The plugin manifest fills what the listing omits and the listing wins")
    func manifestFillsGaps() throws {
        let tree = try TempTree()
        try tree.file("market/plugins/demo/assets/icon.png", contents: "x")
        try tree.file(
            "market/plugins/demo/.claude-plugin/plugin.json",
            contents: """
                {"name":"demo","description":"From manifest","logo":"assets/icon.png",
                 "author":{"name":"Ada"},"homepage":"https://example.com","license":"MIT"}
                """)
        var listed = PluginCatalogEntry(name: "demo", source: "./plugins/demo", version: nil)
        listed.summary = "From catalog"
        let result = reader.withPluginDetails(
            marketplace(tree.path + "/market", entries: [listed]))
        let entry = try #require(result.plugins.first)
        #expect(entry.summary == "From catalog")
        #expect(entry.author == "Ada")
        #expect(entry.homepage == "https://example.com")
        #expect(entry.license == "MIT")
        #expect(entry.logo?.hasSuffix("/market/plugins/demo/assets/icon.png") == true)
        #expect(entry.repository == "https://github.com/owner/market/tree/HEAD/plugins/demo")
    }

    @Test("Escaping, remote, local and subdirectory sources borrow nothing")
    func boundaries() throws {
        let tree = try TempTree()
        try tree.file("outside/.claude-plugin/plugin.json", contents: #"{"license":"MIT"}"#)
        try tree.dir("market/plugins/demo")
        let root = tree.path + "/market"
        let escaping = PluginCatalogEntry(name: "a", source: "../outside", version: nil)
        let remote = PluginCatalogEntry(name: "b", source: "github:x/y", version: nil)
        let inside = PluginCatalogEntry(name: "c", source: "plugins/demo", version: nil)
        let read = reader.withPluginDetails(
            marketplace(root, entries: [escaping, remote, inside]))
        #expect(read.plugins == [escaping, remote, read.plugins[2]])
        #expect(read.plugins[2].repository != nil)
        for other in [
            marketplace(root, entries: [inside], sourceType: "git-subdir"),
            marketplace(root, entries: [inside], source: root, local: true)
        ] {
            #expect(reader.withPluginDetails(other).plugins == [inside])
        }
    }

}
