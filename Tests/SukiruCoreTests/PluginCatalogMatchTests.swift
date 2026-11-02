import Testing

@testable import SukiruCore

@Suite("Installation to listing matching")
struct PluginCatalogMatchTests {
    private func installation(
        _ host: PluginHost, _ identifier: String, scope: String = "user",
        scopeRoot: String = "/Users/me"
    ) -> PluginInstallation {
        PluginInstallation(
            host: host, source: "market", identifier: identifier, scope: scope,
            scopeRoot: scopeRoot, version: nil, path: nil, enablement: .enabled,
            loadStatus: "unknown", components: [])
    }

    private func marketplace(
        _ host: PluginHost, _ name: String, source: String = "owner/market",
        scope: String = "user", scopeRoot: String = "/Users/me",
        plugins: [String]
    ) -> PluginMarketplace {
        PluginMarketplace(
            host: host, name: name, source: source, scopeRoot: scopeRoot, path: nil,
            plugins: plugins.map { name in
                var entry = PluginCatalogEntry(
                    name: name, source: "./plugins/" + name, version: nil)
                entry.displayName = name.uppercased()
                entry.logo = "https://example.com/" + name + ".png"
                return entry
            }, scope: scope)
    }

    @Test("Droid, Codex and Claude match a listing only by plugin and marketplace")
    func recordedIdentity() {
        let inventory = PluginInventory(
            installations: [
                installation(.droid, "demo@market"), installation(.droid, "demo@other")
            ],
            marketplaces: [marketplace(.droid, "market", plugins: ["demo", "spare"])],
            issues: [])
        #expect(inventory.catalogEntry(for: inventory.installations[0])?.logo != nil)
        #expect(inventory.catalogEntry(for: inventory.installations[1]) == nil)

        let codex = PluginInventory(
            installations: [
                installation(.codex, "demo@market"),
                installation(.codex, "demo@market", scope: "project", scopeRoot: "/repo")
            ],
            marketplaces: [marketplace(.codex, "market", plugins: ["demo"])],
            issues: [])
        #expect(codex.catalogEntry(for: codex.installations[0])?.displayName == "DEMO")
        #expect(codex.catalogEntry(for: codex.installations[1]) == nil)
    }

    @Test("A Claude marketplace name held by two sources identifies nothing")
    func claudeAmbiguousSource() {
        let installations = [installation(.claude, "demo@team")]
        let shared = [
            marketplace(.claude, "team", source: "owner/one", plugins: ["demo"]),
            marketplace(.claude, "team", source: "owner/two", plugins: ["demo"])
        ]
        #expect(
            PluginInventory(installations: installations, marketplaces: shared, issues: [])
                .catalogEntry(for: installations[0]) == nil)
        #expect(
            PluginInventory(
                installations: installations, marketplaces: [shared[0]], issues: []
            ).catalogEntry(for: installations[0])?.name == "demo")
    }

    @Test("A name-only host matches when exactly one listing carries the name")
    func nameOnly() {
        let plugin = installation(.antigravity, "demo")
        #expect(
            PluginInventory(
                installations: [plugin],
                marketplaces: [marketplace(.antigravity, "a", plugins: ["demo"])],
                issues: []
            ).catalogEntry(for: plugin)?.displayName == "DEMO")
        #expect(
            PluginInventory(
                installations: [plugin],
                marketplaces: [
                    marketplace(.antigravity, "a", plugins: ["demo"]),
                    marketplace(.antigravity, "b", plugins: ["demo"])
                ],
                issues: []
            ).catalogEntry(for: plugin) == nil)
        #expect(
            PluginInventory(
                installations: [installation(.opencode, "demo")],
                marketplaces: [marketplace(.opencode, "a", plugins: ["demo"])], issues: []
            ).catalogEntry(for: installation(.opencode, "demo")) == nil)
    }
}
