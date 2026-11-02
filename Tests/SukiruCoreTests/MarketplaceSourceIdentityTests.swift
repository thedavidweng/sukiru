import Foundation
import Testing

@testable import SukiruCore

struct MarketplaceSourceIdentityTests {
    @Test("Claude cache evidence does not authorize user-scope removal")
    func cachedRemoval() throws {
        let fixture = try ClaudePluginLifecycleCLIIntegrationTests.claude()
        try fixture.tree.file("home/.claude/settings.json", contents: "{}")
        let result = try fixture.plan([fixture.request("marketplace-remove", "team")])
        #expect(result.exitCode != 0)
        #expect(result.stderrText.contains("not declared in user scope"))
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Claude local source identity resolves relative paths in each project")
    func relativeSources() throws {
        let fixture = try ClaudePluginLifecycleCLIIntegrationTests.claude(
            projects: ["one", "two"])
        try FileManager.default.removeItem(
            atPath: fixture.home + "/.claude/plugins/known_marketplaces.json")
        try fixture.tree.file("home/.claude/settings.json", contents: "{}")
        for project in ["one", "two"] {
            try fixture.tree.file(
                project + "/.claude/settings.json",
                contents:
                    #"{"extraKnownMarketplaces":{"team":{"source":{"source":"directory","path":"./catalog"}}}}"#
            )
            try fixture.tree.file(
                project + "/catalog/.claude-plugin/marketplace.json",
                contents: #"{"name":"team","plugins":[{"name":"demo","source":"./demo"}]}"#)
        }
        let inventory = read(fixture)
        #expect(!inventory.claudeHasUniqueSource("team"))
        for market in inventory.marketplaces where market.host == .claude {
            let entry = try #require(market.plugins.first)
            #expect(inventory.recordedClaudeInstallations(entry, marketplace: market).isEmpty)
        }
        let plan = try fixture.plan([fixture.request("install", "demo@team")])
        #expect(plan.exitCode != 0)

        let shared = fixture.tree.path + "/one/catalog"
        try fixture.tree.file(
            "two/.claude/settings.json",
            contents: """
                {"extraKnownMarketplaces":{"team":{"source":{"source":"directory","path":"\(shared)"}}}}
                """)
        #expect(read(fixture).claudeHasUniqueSource("team"))
        #expect(try fixture.plan([fixture.request("install", "demo@team")]).exitCode == 0)
    }

    @Test("Claude declarations cannot borrow another source's cached listings")
    func claudeCacheBinding() throws {
        let fixture = try ClaudePluginLifecycleCLIIntegrationTests.claude(projects: ["project"])
        let cache = try fixture.tree.dir("home/.claude/plugins/marketplaces/team")
        try fixture.tree.file(
            "home/.claude/plugins/known_marketplaces.json",
            contents: """
                {"team":{"source":{"source":"github","repo":"example/team"},"installLocation":"\(cache)"}}
                """)
        try fixture.tree.file(
            "home/.claude/plugins/marketplaces/team/.claude-plugin/marketplace.json",
            contents: #"{"name":"team","plugins":[{"name":"only-a","source":"./only-a"}]}"#)
        try fixture.tree.file(
            "project/.claude/settings.json",
            contents:
                #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"other/team"}}}}"#
        )
        let inventory = read(fixture)
        let other = try #require(inventory.marketplaces.first { $0.source == "other/team" })
        #expect(other.plugins.isEmpty)
        #expect(other.catalogState == "unverified")
        #expect(inventory.marketplaces.first { $0.source == "example/team" }?.plugins.count == 1)
    }

    @Test(
        "Codex conflicting Git declarations do not attribute a shared snapshot",
        arguments: [false, true])
    func codexCacheBinding(refOnly: Bool) throws {
        let fixture = try CodexPluginLifecycleCLIIntegrationTests.codex(projects: ["project"])
        let source = refOnly ? "https://example.test/team.git" : "https://example.test/other.git"
        try fixture.tree.file(
            "project/.codex/config.toml",
            contents: """
                [marketplaces.team]
                source_type = "git"
                source = "\(source)"
                ref = "\(refOnly ? "other" : "main")"
                """)
        let catalogs = read(fixture).marketplaces.filter { $0.host == .codex && $0.name == "team" }
        #expect(catalogs.count == 2)
        #expect(catalogs.first { $0.scope == "project" }?.catalogState == "unverified")
        #expect(catalogs.first { $0.scope == "project" }?.plugins.isEmpty == true)
        #expect(catalogs.first { $0.scope == "user" }?.plugins.count == 1)
        #expect(try fixture.plan([fixture.request("install", "demo@team")]).exitCode == 0)
        #expect(fixture.invocations.isEmpty)
    }

    @Test(
        "Codex unverified snapshots cannot authorize user-only installation",
        arguments: ["missing", "malformed", "source", "ref", "invalid-ref"])
    func codexUnverifiedSnapshot(kind: String) throws {
        let fixture = try CodexPluginLifecycleCLIIntegrationTests.codex()
        let metadata = "home/.codex/.tmp/marketplaces/team/.codex-marketplace-install.json"
        if kind == "missing" {
            try FileManager.default.removeItem(atPath: fixture.tree.path + "/" + metadata)
        } else if kind == "malformed" {
            try fixture.tree.file(metadata, contents: "{")
        } else if kind == "invalid-ref" {
            try fixture.tree.file(
                "home/.codex/config.toml",
                contents: """
                    [marketplaces.team]
                    source_type = "git"
                    source = "https://example.test/team.git"
                    """)
            try fixture.tree.file(
                metadata,
                contents: """
                    {"source_type":"git","source":"https://example.test/team.git","ref_name":1}
                    """)
        } else {
            try fixture.tree.file(
                metadata,
                contents: """
                    {"source_type":"git","source":"https://example.test/\(kind == "source" ? "other" : "team").git",
                    "ref_name":"\(kind == "ref" ? "other" : "main")"}
                    """)
        }
        let result = try CLIRunner.run(
            [
                "plugins", "install", "demo@team", "--host", "codex", "--scope", "user",
                "--dry-run", "--json"
            ],
            environment: fixture.environment)
        #expect(result.exitCode != 0)
        #expect(fixture.invocations.isEmpty)
        let market = try #require(
            read(fixture).marketplaces.first { $0.host == .codex && $0.name == "team" })
        #expect(market.plugins.isEmpty && market.catalogState == "unverified")
        for action in ["marketplace-refresh", "marketplace-remove"] {
            #expect(try fixture.plan([fixture.request(action, "team")]).exitCode == 0)
        }
    }

    @Test("Codex local declarations do not compete with a verified Git snapshot")
    func codexLocalAndGit() throws {
        let fixture = try CodexPluginLifecycleCLIIntegrationTests.codex(projects: ["project"])
        try fixture.tree.file(
            "project/.codex/config.toml",
            contents: """
                [marketplaces.team]
                source_type = "local"
                source = "./catalog"
                """)
        try fixture.tree.file(
            "project/catalog/.agents/plugins/marketplace.json",
            contents: #"{"name":"team","plugins":[{"name":"local-only","source":"./local-only"}]}"#)
        let markets = read(fixture).marketplaces.filter { $0.host == .codex && $0.name == "team" }
        #expect(markets.first { $0.scope == "user" }?.plugins.first?.name == "demo")
        #expect(markets.first { $0.scope == "project" }?.plugins.first?.name == "local-only")
        #expect(try fixture.plan([fixture.request("install", "demo@team")]).exitCode == 0)
    }

    @Test("A host's cache time parses from an HTTP date or ISO 8601")
    func cacheTimestamps() throws {
        func record(_ updatedAt: String) -> PluginMarketplace {
            PluginMarketplace(
                host: .droid, name: "team", source: "example/team", scopeRoot: "/",
                path: nil, plugins: [], evidence: nil, updatedAt: updatedAt)
        }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(
            record("Fri, 30 Oct 2026 16:18:00 GMT").updatedDate
                == iso.date(from: "2026-10-30T16:18:00Z"))
        #expect(
            record("2026-11-02T07:50:14.943Z").updatedDate
                == fractional.date(from: "2026-11-02T07:50:14.943Z"))
        #expect(record("not a date").updatedDate == nil)
    }

    private func read(_ fixture: PluginHostFixture) -> PluginInventory {
        PluginInventoryReader(
            environment: SukiruEnvironment(reader: DictionaryEnvironmentReader(fixture.environment))
        ).read(ScanRequest())
    }
}
