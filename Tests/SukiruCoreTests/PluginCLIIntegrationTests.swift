import Foundation
import Testing

@Suite("Passive plugin CLI inventory")
struct PluginCLIIntegrationTests {
    @Test("Codex active cache selection ignores files and ranks release above prerelease")
    func codexActiveCache() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.codex/config.toml", contents: "[plugins.\"demo@team\"]\nenabled = true\n")
        try tree.dir("home/.codex/plugins/cache/team/demo/2.0.0")
        try tree.dir("home/.codex/plugins/cache/team/demo/2.0.0-rc.1")
        try tree.file("home/.codex/plugins/cache/team/demo/zzz", contents: "not a directory")
        let result = try CLIRunner.run(
            ["scan"], environment: CLIRunner.fixtureEnvironment(home: home))
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        let plugins = try #require(inventory["installations"] as? [[String: Any]])
        #expect(plugins.first?["version"] as? String == "2.0.0")
    }

    @Test("Comments, strings, and unrelated async helpers do not establish incompatibility")
    func sourceShapeContext() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.config/opencode/plugins/comments.ts",
            contents: "// export const Legacy = async () => ({})\nexport const value = 1")
        try tree.file(
            "home/.config/opencode/plugins/strings.ts",
            contents:
                "const example = `export const Legacy = async () => ({})`;\nexport const value = 1")
        try tree.file(
            "home/.config/opencode/plugins/helper.ts",
            contents: "const helper = async () => ({});\nexport const value = 1")
        try tree.file(
            "home/.config/opencode/plugins/valid.ts",
            contents:
                "export default { id: 'valid', setup() {} };\nexport const helper = async () => ({})"
        )
        let result = try CLIRunner.run(
            ["scan"], environment: CLIRunner.fixtureEnvironment(home: home))
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        #expect((inventory["healthFindings"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("Inline marketplace entries remain available without standalone plugin manifests")
    func inlineMarketplace() throws {
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
            contents: """
                {"name":"team","plugins":[
                  {"name":"inline","description":"Valid inline definition","skills":"./skills"}
                ]}
                """)
        let result = try CLIRunner.run(
            ["scan"], environment: CLIRunner.fixtureEnvironment(home: home))
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        let catalogs = try #require(inventory["marketplaces"] as? [[String: Any]])
        let entries = try #require(catalogs.first?["plugins"] as? [[String: Any]])
        #expect(entries.first?["name"] as? String == "inline")
        #expect((inventory["issues"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("OpenCode reads both config generations and local files without loading their code")
    func openCodeInventory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        try tree.file(
            "home/.config/opencode/opencode.jsonc",
            contents: """
                { // user package declarations
                  "plugin": ["legacy@1.2.3"],
                  "plugins": ["modern@2.0.0"],
                }
                """)
        try tree.file(
            "project/opencode.json",
            contents: """
                {"plugins":["project-package@latest"]}
                """)
        try tree.file(
            "project/.opencode/plugins/old.ts",
            contents: """
                export const Legacy: Plugin = async () => ({})
                """)
        try tree.file(
            "home/.config/opencode/plugins/valid.ts",
            contents: """
                export default { id: "valid", setup() {} }
                """)
        try tree.file(
            "home/.local/share/opencode/log/opencode.log",
            contents:
                "2026-01-01 ERROR \(project)/.opencode/plugins/old.ts missing default definition\n")
        let result = try CLIRunner.run(
            ["scan"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, roots: [project]))
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        let plugins = try #require(inventory["installations"] as? [[String: Any]])
        #expect(plugins.count == 5)
        #expect(plugins.filter { $0["scopeRoot"] as? String == project }.count == 2)
        #expect(plugins.allSatisfy { $0["loadStatus"] as? String == "unknown" })
        let findings = try #require(inventory["healthFindings"] as? [[String: Any]])
        #expect(findings.count == 1)
        #expect(findings.first?["kind"] as? String == "v1-definition")
        #expect((findings.first?["historicalEvidence"] as? [String])?.count == 1)
    }

    @Test("Codex configuration declarations stay distinct from unreferenced cache versions")
    func codexInventory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let marketplace = try tree.dir("catalog")
        try tree.file(
            "home/.codex/config.toml",
            contents: """
                [marketplaces."local"]
                source_type = "local"
                source = "\(marketplace)"
                [plugins."demo@local"]
                enabled = false
                """)
        try tree.file(
            "project/.codex/config.toml",
            contents: """
                [plugins."demo@local"]
                enabled = true
                """)
        try tree.dir("home/.codex/plugins/cache/local/demo/local")
        try tree.dir("home/.codex/plugins/cache/local/unreferenced/1.0")
        try tree.file(
            "catalog/.agents/plugins/marketplace.json",
            contents: """
                {"name":"local","plugins":[{"name":"demo","source":{"source":"local","path":"./demo"}}]}
                """)
        let result = try CLIRunner.run(
            ["scan"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, roots: [project]))
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        let plugins = try #require(inventory["installations"] as? [[String: Any]])
        #expect(plugins.count == 2)
        #expect(plugins.allSatisfy { $0["identifier"] as? String == "demo@local" })
        #expect(
            plugins.first { $0["scopeRoot"] as? String == project }?["enablement"] as? String
                == "enabled")
        let catalogs = try #require(inventory["marketplaces"] as? [[String: Any]])
        #expect(catalogs.count == 1)
    }

    @Test("Claude installations retain source and concrete scope without invoking the host")
    func claudeInventory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let payload = try tree.dir("home/.claude/plugins/cache/one/demo/1.0")
        try tree.file(
            "home/.claude/plugins/installed_plugins.json",
            contents: """
                {"version":2,"plugins":{
                  "demo@one":[{"scope":"user","installPath":"\(payload)","version":"1.0"},
                    {"scope":"project","projectPath":"\(project)","installPath":"\(payload)","version":"1.0"}],
                  "demo@two":[{"scope":"user","installPath":"\(payload)","version":"1.0"}]
                }}
                """)
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"enabledPlugins":{"demo@one":true,"demo@two":false}}
                """)
        try tree.file(
            "project/.claude/settings.json",
            contents: """
                {"enabledPlugins":{"demo@one":false}}
                """)
        try tree.file(
            "home/.claude/plugins/cache/one/demo/1.0/.claude-plugin/plugin.json",
            contents: """
                {"name":"demo","version":"1.0"}
                """)
        try tree.file(
            "home/.claude/plugins/cache/one/demo/1.0/skills/bundled/SKILL.md",
            contents: "---\nname: bundled\n---\nInstructions")
        let marker = tree.path + "/invoked"
        try tree.executable("bin/claude", contents: "#!/bin/sh\ntouch '\(marker)'\nexit 1\n")
        let result = try CLIRunner.run(
            ["scan"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, roots: [project], path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        let plugins = try #require(inventory["installations"] as? [[String: Any]])
        #expect(plugins.count == 3)
        #expect(Set(plugins.compactMap { $0["id"] as? String }).count == 3)
        #expect(plugins.allSatisfy { $0["loadStatus"] as? String == "unknown" })
        let projectPlugin = try #require(plugins.first { $0["scopeRoot"] as? String == project })
        #expect(projectPlugin["enablement"] as? String == "disabled")
        let components = try #require(projectPlugin["components"] as? [[String: Any]])
        #expect(components.contains { $0["name"] as? String == "bundled" })
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
