import Foundation
import Testing

@testable import SukiruCore

@Suite("OpenCode plugin configuration inventory")
struct PluginInventoryConfigTests {
    @Test("CLI scan applies config precedence, scopes, and component kinds")
    func configurationLayers() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        let project = try tree.dir("project")
        let global = home + "/.config/opencode"
        try FileManager.default.createDirectory(
            atPath: global, withIntermediateDirectories: true)
        try tree.file(
            "home/.config/opencode/opencode.json",
            contents: #"{"plugin":["legacy"],"plugins":["server","-blocked"]}"#)
        try tree.file("home/.config/opencode/cli.json", contents: #"{"plugins":["cli"]}"#)
        let custom = try tree.file(
            "custom.jsonc", contents: #"{"plugin":["custom","precedence"]}"#)
        try tree.file(
            "project/opencode.json",
            contents: #"{"plugin":["shared","project","-discovered.js"]}"#)
        try tree.file(
            "project/.opencode/opencode.jsonc",
            contents: "{\n // project overlay\n \"plugins\": [\"shared\", \"./local.ts\",],\n}")
        try tree.file("project/.opencode/plugins/discovered.js", contents: "export default {}")

        let result = try scan(
            home: home, roots: [project],
            extra: [
                "OPENCODE_CONFIG": custom,
                "OPENCODE_CONFIG_CONTENT": #"{"plugins":["inline","precedence"]}"#
            ])
        let installations = try installations(from: result)
        let user = installations.filter { $0["scope"] as? String == "user" }
        #expect(contains(user, id: "legacy", component: "v1"))
        #expect(contains(user, id: "server", component: "server"))
        #expect(contains(user, id: "cli", component: "cli"))
        #expect(contains(user, id: "custom"))
        #expect(contains(user, id: "inline"))
        let precedence = user.filter { $0["identifier"] as? String == "precedence" }
        #expect(precedence.count == 1)
        #expect(componentKind(precedence[0]) == "server")
        #expect(!installations.contains { $0["identifier"] as? String == "-blocked" })

        let projectPlugins = installations.filter { $0["scopeRoot"] as? String == project }
        #expect(contains(projectPlugins, id: "project"))
        #expect(contains(projectPlugins, id: "custom"))
        #expect(contains(projectPlugins, id: "inline"))
        let shared = projectPlugins.filter { $0["identifier"] as? String == "shared" }
        #expect(shared.count == 1)
        #expect(componentKind(shared[0]) == "server")
        #expect(contains(projectPlugins, id: "./local.ts"))
        let discovered = try #require(
            projectPlugins.first { $0["identifier"] as? String == "discovered.js" })
        #expect(discovered["enablement"] as? String == "unknown")
        #expect(discovered["loadStatus"] as? String == "unknown")
        #expect(discovered["installationStatus"] as? String == "discovered")
    }

    @Test("CLI scan reports malformed JSONC instead of partial config state")
    func malformedJSONC() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        try tree.file(
            "home/.config/opencode/opencode.jsonc",
            contents: #"{"plugins":["valid-before-comment"]} /* never closed"#)

        let result = try scan(home: home)
        let inventory = try #require(result["pluginInventory"] as? [String: Any])
        #expect((inventory["installations"] as? [[String: Any]] ?? []).isEmpty)
        let issues = try #require(inventory["issues"] as? [[String: Any]])
        #expect(issues.contains { ($0["kind"] as? String) == "plugin-config" })
    }

    @Test("JSONC comments, URL strings, and trailing commas are preserved")
    func jsoncStringsAndComments() throws {
        let source = #"""
            {"plugins":["https://example.test/a,b", // comment
              "@scope/plugin",],}
            """#
        let data = PluginJSONC.data(source)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: [String]])

        #expect(object["plugins"] == ["https://example.test/a,b", "@scope/plugin"])
    }

    @Test("Claude project marketplace declarations work without a known catalog and deduplicate")
    func claudeProjectMarketplaces() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        let project = try tree.dir("project")
        try tree.file(
            "project/.claude/settings.json",
            contents: #"{"extraKnownMarketplaces":{"local":{"source":{"path":"./catalog"}}}}"#)
        try tree.file(
            "project/.claude/settings.local.json",
            contents: #"{"extraKnownMarketplaces":{"local":{"source":{"path":"./catalog"}}}}"#)
        try tree.file(
            "project/catalog/.claude-plugin/marketplace.json",
            contents: #"{"plugins":[{"name":"demo","source":"./demo"}]}"#)

        let result = try scan(home: home, roots: [project])
        let inventory = try #require(result["pluginInventory"] as? [String: Any])
        let marketplaces = try #require(inventory["marketplaces"] as? [[String: Any]])
        let projectMarketplaces = marketplaces.filter { $0["scopeRoot"] as? String == project }
        #expect(projectMarketplaces.count == 1)
        #expect(projectMarketplaces.first?["name"] as? String == "local")
        #expect(projectMarketplaces.first?["source"] as? String == "./catalog")
        #expect(
            (projectMarketplaces.first?["plugins"] as? [[String: Any]])?.first?["name"] as? String
                == "demo")
    }

    @Test("Codex plugin root manifest takes precedence over host specific overlays")
    func codexManifestPrecedence() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        try tree.file(
            "home/.codex/config.toml",
            contents: #"[plugins."demo@market"]"# + "\nenabled = true\n")
        let plugin = "home/.codex/plugins/cache/market/demo/1.0.0"
        try tree.file(
            plugin + "/plugin.json",
            contents:
                #"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","hooks":{}}"#
        )
        try tree.file(plugin + "/.codex-plugin/plugin.json", contents: #"{"mcpServers":{}}"#)
        try tree.file(plugin + "/.claude-plugin/plugin.json", contents: #"{"lspServers":{}}"#)
        try tree.file(plugin + "/.cursor-plugin/plugin.json", contents: #"{"agents":{}}"#)

        let result = try scan(home: home)
        let installations = try self.installations(from: result)
        let codex = try #require(installations.first { $0["host"] as? String == "codex" })
        let kinds = (codex["components"] as? [[String: Any]] ?? []).compactMap {
            $0["kind"] as? String
        }
        #expect(kinds.contains("hooks"))
        #expect(!kinds.contains("mcpServers"))
        #expect(!kinds.contains("lspServers"))
    }

    @Test("Codex manifest lookup skips symlinked manifest paths")
    func codexManifestSymlink() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        try tree.file(
            "home/.codex/config.toml",
            contents: #"[plugins."demo@market"]"# + "\nenabled = true\n")
        let relative = "home/.codex/plugins/cache/market/demo/1.0.0"
        let plugin = try tree.dir(relative)
        let linkedManifest = try tree.file("outside/plugin.json", contents: #"{"hooks":{}}"#)
        try FileManager.default.createSymbolicLink(
            atPath: plugin + "/plugin.json", withDestinationPath: linkedManifest)
        try tree.file(relative + "/.codex-plugin/plugin.json", contents: #"{"mcpServers":{}}"#)

        let result = try scan(home: home)
        let installations = try self.installations(from: result)
        let codex = try #require(installations.first { $0["host"] as? String == "codex" })
        let kinds = (codex["components"] as? [[String: Any]] ?? []).compactMap {
            $0["kind"] as? String
        }
        #expect(kinds.isEmpty)
        #expect(!kinds.contains("hooks"))
    }

    private func scan(
        home: String, roots: [String] = [], extra: [String: String] = [:]
    ) throws -> [String: Any] {
        var environment = CLIRunner.fixtureEnvironment(home: home, roots: roots)
        environment.removeValue(forKey: SukiruEnvironment.sukiruHomeKey)
        environment[SukiruEnvironment.homeKey] = home
        environment[SukiruEnvironment.xdgConfigHomeKey] = home + "/.config"
        environment[SukiruEnvironment.xdgStateHomeKey] = home + "/.local/state"
        for key in SukiruEnvironment.externalEnvKeys {
            environment.removeValue(forKey: key)
        }
        environment.merge(extra) { _, new in new }
        let result = try CLIRunner.run(["scan", "--format", "json"], environment: environment)
        #expect(result.exitCode == 0)
        return try #require(try result.jsonObject())
    }

    private func installations(from report: [String: Any]) throws -> [[String: Any]] {
        let inventory = try #require(report["pluginInventory"] as? [String: Any])
        return inventory["installations"] as? [[String: Any]] ?? []
    }

    private func contains(
        _ installations: [[String: Any]], id: String, component: String? = nil
    ) -> Bool {
        installations.contains { installation in
            guard installation["identifier"] as? String == id else { return false }
            guard let component else { return true }
            return componentKind(installation) == component
        }
    }

    private func componentKind(_ installation: [String: Any]) -> String? {
        (installation["components"] as? [[String: Any]])?.first?["kind"] as? String
    }
}
