import Foundation
import Testing

@testable import SukiruCore

extension ClaudePluginLifecycleCLIIntegrationTests {
    @Test("Conflicting Claude catalog sources cannot claim an installation record")
    func conflictingSourceBadges() throws {
        let fixture = try Self.claude()
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": fixture.home]))
        let reader = PluginInventoryReader(environment: environment)
        let original = reader.read(ScanRequest())
        let market = try #require(original.marketplaces.first { $0.host == .claude })
        let entry = try #require(market.plugins.first)
        #expect(original.recordedClaudeInstallations(entry, marketplace: market).count == 1)
        try fixture.tree.file(
            "home/.claude/settings.json",
            contents:
                #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"other/team"}}}}"#
        )
        let conflicting = reader.read(ScanRequest())
        for catalog in conflicting.marketplaces where catalog.host == .claude {
            #expect(conflicting.recordedClaudeInstallations(entry, marketplace: catalog).isEmpty)
        }
    }
    @Test("Marketplace inventory exposes declared listing metadata")
    func listingMetadata() throws {
        let fixture = try Self.claude(
            catalogEntry: """
                {"name":"demo","source":{"source":"github","repo":"example/demo"},
                 "displayName":"Demo Tool","description":"Useful demo","version":"1.2",
                 "author":{"name":"Example"},"homepage":"https://example.com",
                 "repository":"https://example.com/repo","license":"MIT",
                 "category":"Tools","keywords":["demo"],"suggestedPrompts":["Try it"],
                 "icon":"https://example.com/icon.png"}
                """)
        let list = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--json"], environment: fixture.environment)
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: list.stdout) as? [[String: Any]])
        let entry = try #require((catalogs.first?["plugins"] as? [[String: Any]])?.first)
        #expect(entry["displayName"] as? String == "Demo Tool")
        #expect(entry["summary"] as? String == "Useful demo")
        #expect(entry["author"] as? String == "Example")
        #expect(entry["homepage"] as? String == "https://example.com")
        #expect(entry["repository"] as? String == "https://example.com/repo")
        #expect(entry["license"] as? String == "MIT")
        #expect(entry["categories"] as? [String] == ["Tools"])
        #expect(entry["keywords"] as? [String] == ["demo"])
        #expect(entry["suggestedPrompts"] as? [String] == ["Try it"])
        #expect(entry["logo"] as? String == "https://example.com/icon.png")
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Conflicting marketplace sources remain visible and cannot be targeted ambiguously")
    func conflictingSources() throws {
        let fixture = try Self.claude()
        try fixture.tree.file(
            "home/.claude/settings.json",
            contents:
                #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"other/team","ref":"dev"}}}}"#
        )
        let list = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--json"], environment: fixture.environment)
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: list.stdout) as? [[String: Any]])
        #expect(
            Set(catalogs.compactMap { $0["source"] as? String })
                == ["example/team", "other/team"])
        #expect(catalogs.count == 2)
        let result = try fixture.plan([fixture.request("install", "demo@team")])
        #expect(result.exitCode != 0)
        for action in ["marketplace-refresh", "marketplace-remove"] {
            let ambiguous = try fixture.plan([fixture.request(action, "team")])
            #expect(ambiguous.exitCode != 0)
        }
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Marketplace source type and ref are retained")
    func marketplaceSourceType() throws {
        let fixture = try Self.claude()
        try fixture.tree.file(
            "home/.claude/settings.json",
            contents:
                #"{"extraKnownMarketplaces":{"team":{"source":{"source":"git","url":"example/team","ref":"main"}}}}"#
        )
        let list = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--json"], environment: fixture.environment)
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: list.stdout) as? [[String: Any]])
        #expect(Set(catalogs.compactMap { $0["sourceType"] as? String }) == ["github", "git"])
        #expect(catalogs.contains { $0["ref"] as? String == "main" })
    }

    @Test("An overridden cache registry still requires host review for headersHelper")
    func cacheOverrideApproval() throws {
        let fixture = try Self.claude()
        let config = try fixture.tree.dir("custom-config")
        let cache = try fixture.tree.dir("custom-cache")
        let catalog = fixture.tree.path + "/catalog"
        try fixture.tree.file(
            "custom-cache/known_marketplaces.json",
            contents: """
                {"team":{"source":{"source":"github","repo":"example/team",
                "headersHelper":"echo secret"},"installLocation":"\(catalog)"}}
                """)
        let requests = fixture.tree.path + "/override-requests.json"
        try JSONSerialization.data(withJSONObject: [fixture.request("install", "demo@team")])
            .write(to: URL(fileURLWithPath: requests))
        var environment = fixture.environment
        environment.removeValue(forKey: "SUKIRU_HOME")
        environment["HOME"] = fixture.home
        environment["CLAUDE_CONFIG_DIR"] = config
        environment["CLAUDE_CODE_PLUGIN_CACHE_DIR"] = cache
        let result = try CLIRunner.run(
            ["plugins", "plan", "--requests", requests], environment: environment)
        #expect(try result.instructions().contains { $0.contains("host review") })
        #expect(fixture.invocations.isEmpty)
    }

}

extension PluginCLIIntegrationTests {
    @Test("Claude retains readable catalog entries when another entry is malformed")
    func malformedClaudeCatalogEntry() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let catalog = try tree.dir("catalog")
        try tree.file(
            "home/.claude/plugins/known_marketplaces.json",
            contents: """
                {"team":{"source":{"source":"directory","path":"\(catalog)"},"installLocation":"\(catalog)"}}
                """)
        try tree.file(
            "catalog/.claude-plugin/marketplace.json",
            contents: #"{"plugins":[{"name":"valid","source":"./valid"},42]}"#)
        let result = try CLIRunner.run(
            ["scan"], environment: CLIRunner.fixtureEnvironment(home: home))
        let inventory = try #require(try result.jsonObject()?["pluginInventory"] as? [String: Any])
        let catalogs = try #require(inventory["marketplaces"] as? [[String: Any]])
        let entries = try #require(catalogs.first?["plugins"] as? [[String: Any]])
        #expect(entries.map { $0["name"] as? String } == ["valid"])
        let issues = try #require(inventory["issues"] as? [[String: Any]])
        #expect(issues.contains { ($0["path"] as? String)?.hasSuffix("marketplace.json") == true })
    }

}
