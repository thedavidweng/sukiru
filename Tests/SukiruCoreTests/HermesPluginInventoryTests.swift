import Foundation
import Testing

@testable import SukiruCore

struct HermesPluginInventoryTests {
    @Test("User plugins come from ~/.hermes/plugins with config enablement and catalog provenance")
    func userPlugins() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.hermes/config.yaml",
            contents: "plugins:\n  enabled:\n    - supermemory\n  disabled: []\n")
        try tree.file(
            "home/.hermes/plugins/supermemory/plugin.yaml",
            contents: "name: supermemory\nversion: 1.0.1\ndescription: Long-term memory\n")
        try tree.file(
            "home/.hermes/plugins/supermemory/.hermes-catalog.json",
            contents:
                """
                {"catalog_name":"supermemory",
                 "repo":"https://github.com/supermemoryai/hermes-supermemory","tier":"community"}
                """
        )
        try tree.file(
            "home/.hermes/plugins/local-tool/plugin.yaml",
            contents: "name: local-tool\nversion: 0.1.0\n")
        let inventory = read(home)
        let installed = inventory.installations.filter { $0.host == .hermes }
        let memory = try #require(installed.first { $0.identifier == "supermemory" })
        #expect(memory.enablement == .enabled)
        #expect(memory.source == "https://github.com/supermemoryai/hermes-supermemory")
        #expect(memory.version == "1.0.1")
        #expect(memory.summary == "Long-term memory")
        let local = try #require(installed.first { $0.identifier == "local-tool" })
        #expect(local.enablement == .disabled)
        #expect(local.source == "local")
        #expect(inventory.issues.isEmpty)
    }

    @Test("The cached catalog keeps tier and category, and drops removed entries")
    func cachedCatalog() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.hermes/cache/plugin-catalog.json",
            contents: """
                {"generated_at":"2026-11-03T21:29:28+00:00",
                 "entries":[
                  {"name":"homeassistant","repo":"https://github.com/a/homeassistant","sha":"\
                0000000000000000000000000000000000000000","tier":"official","category":"desktop",
                   "version":"1.0.0","title":"Home Assistant","description":"Control devices",
                   "image":"https://raw.githubusercontent.com/a/b/x.jpg","maintainer":"Nous",
                   "docs_url":"https://example.com/docs",
                   "known_issues":["Needs a restart after enabling"],
                   "capabilities":{"provides_tools":[],"requires_env":["HASS_TOKEN"]},
                   "platforms":["linux","macos"]},
                  {"name":"lite","repo":"https://github.com/a/lite","tier":"community",
                   "homepage_url":"https://example.com/lite"},
                  {"name":"or-picker","repo":"https://github.com/a/or-picker","tier":"community"}],
                 "removed":[{"name":"or-picker","reason":"Folded","date":"2026-09-28"}]}
                """)
        let marketplace = try #require(read(home).marketplaces.first { $0.host == .hermes })
        #expect(marketplace.plugins.map(\.name) == ["homeassistant", "lite"])
        let entry = try #require(marketplace.plugins.first)
        #expect(entry.tier == "official")
        #expect(entry.knownIssues == ["Needs a restart after enabling"])
        #expect(entry.requiredEnvironment == ["HASS_TOKEN"])
        #expect(entry.platforms == ["linux", "macos"])
        #expect(entry.homepage == "https://example.com/docs")
        #expect(marketplace.plugins.last?.homepage == "https://example.com/lite")
        #expect(entry.categories == ["desktop"])
        #expect(entry.displayName == "Home Assistant")
        #expect(entry.logo == "https://raw.githubusercontent.com/a/b/x.jpg")
        #expect(entry.repository == "https://github.com/a/homeassistant")
        #expect(marketplace.updatedAt == "2026-11-03T21:29:28+00:00")
    }

    @Test("Hermes plugins are user-scoped, so a project scan reads none")
    func projectScopeIsEmpty() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file("home/.hermes/plugins/x/plugin.yaml", contents: "name: x\n")
        let project = try tree.dir("project")
        let inventory = PluginInventoryReader(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader([
                    "SUKIRU_HOME": home, "SUKIRU_ROOTS": project
                ]))
        ).read(ScanRequest(scope: .project))
        #expect(inventory.installations.allSatisfy { $0.host != .hermes })
        #expect(inventory.marketplaces.allSatisfy { $0.host != .hermes })
    }

    @Test("Install targets are catalog names or GitHub repositories; option-like names are refused")
    func installTargets() throws {
        #expect(try HermesInstallTarget("homeassistant") == .catalog("homeassistant"))
        #expect(
            try HermesInstallTarget("anpicasso/hermes-plugin-chrome-profiles")
                == .repository("https://github.com/anpicasso/hermes-plugin-chrome-profiles"))
        #expect(
            try HermesInstallTarget("https://github.com/owner/repo.git")
                == .repository("https://github.com/owner/repo"))
        #expect(throws: PluginLifecycleError.self) {
            try HermesInstallTarget("https://gitlab.com/a/b")
        }
        #expect(HermesPluginName.isValid("-rf") == false)
        #expect(HermesPluginName.isValid("supermemory") && HermesPluginName.isValid("a.b_c-1"))
    }

    @Test("Hermes versions map to the verified contract only from 0.22.7 within 0.x")
    func contract() {
        #expect(PluginHostContract(host: .hermes, version: "0.22.7") == .hermes)
        #expect(PluginHostContract(host: .hermes, version: "0.23.0") == .hermes)
        #expect(PluginHostContract(host: .hermes, version: "0.22.6") == nil)
        #expect(PluginHostContract(host: .hermes, version: "1.0.0") == nil)
    }

    private func read(_ home: String) -> PluginInventory {
        PluginInventoryReader(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home, "SUKIRU_ROOTS": ""]))
        ).read(ScanRequest())
    }
}
