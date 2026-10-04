import Foundation
import Testing

extension PluginInventoryConfigTests {
    @Test("CLI scan lists custom and conventional manifest components")
    func customComponents() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        let plugin = "home/.claude/plugins/cache/team/demo/1.0.0"
        try tree.file(
            "home/.claude/plugins/installed_plugins.json",
            contents:
                #"{"plugins":{"demo@team":[{"scope":"user","installPath":"\#(tree.path)/\#(plugin)"}]}}"#
        )
        try tree.file(
            plugin + "/.claude-plugin/plugin.json",
            contents:
                """
                {"skills":"./extra-skills","commands":["./custom-commands/deploy.md"],
                 "agents":"./custom-agents/reviewer.md",
                 "hooks":["./config/hooks.json",{"SessionStart":[]}],
                 "mcpServers":["./config/servers.json",{"inline":{"command":"node"}}],
                 "lspServers":["./config/lsp.json",{"inline":{"command":"gopls"}}]}
                """
        )
        try tree.file(plugin + "/extra-skills/audit/SKILL.md", contents: "---\nname: audit\n---")
        try tree.file(plugin + "/custom-commands/deploy.md", contents: "Deploy")
        try tree.file(plugin + "/custom-agents/reviewer.md", contents: "Review")
        try tree.file(plugin + "/config/hooks.json", contents: #"{"hooks":{"SessionStart":[]}}"#)
        try tree.file(plugin + "/config/servers.json", contents: #"{"docs":{}}"#)
        try tree.file(plugin + "/config/lsp.json", contents: #"{"go":{}}"#)
        try tree.file(plugin + "/commands/default.md", contents: "Default")
        try tree.file(plugin + "/agents/default.md", contents: "Default")
        try tree.file(plugin + "/.mcp.json", contents: #"{"mcpServers":{"local":{}}}"#)
        try tree.file(
            plugin + "/.lsp.json",
            contents: #"{"rust":{"command":"rust-analyzer","extensionToLanguage":{".rs":"rust"}}}"#)
        try tree.file(plugin + "/hooks/hooks.json", contents: #"{"hooks":{"PostToolUse":[]}}"#)

        let result = try scan(home: home)
        let installations = try self.installations(from: result)
        let claude = try #require(installations.first { $0["host"] as? String == "claude" })
        let components = claude["components"] as? [[String: Any]] ?? []
        let paths = components.compactMap { $0["path"] as? String }
        #expect(components.contains { $0["name"] as? String == "audit" })
        #expect(paths.contains(tree.path + "/" + plugin + "/custom-commands/deploy.md"))
        #expect(paths.contains(tree.path + "/" + plugin + "/custom-agents/reviewer.md"))
        #expect(!components.contains { $0["name"] as? String == "default.md" })
        #expect(components.filter { $0["kind"] as? String == "hooks" }.count == 3)
        #expect(components.filter { $0["kind"] as? String == "mcpServers" }.count == 3)
        #expect(components.filter { $0["kind"] as? String == "lspServers" }.count == 3)
        let inventory = try #require(result["pluginInventory"] as? [String: Any])
        let issues = try #require(inventory["issues"] as? [[String: Any]])
        #expect(issues.isEmpty)
    }

}
