import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test(
        "Local, skill, subagent, plugin, and managed definitions remain separate and source-managed"
    )
    func sourceTiers() throws {
        let tree = try TempTree()
        let fixture = try sourceFixture(tree)
        let home = fixture.home
        let project = fixture.project
        let system = fixture.system
        let plugin = fixture.plugin
        let config = fixture.config
        let env = CLIRunner.fixtureEnvironment(
            home: home, roots: [project], extra: ["SUKIRU_SYSTEM_ROOT": system])
        let result = try CLIRunner.run(["scan", "--format", "json"], environment: env)
        #expect(result.exitCode == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        let inventory = try #require(report.hookInventory)
        #expect(inventory.issues.isEmpty)
        #expect(inventory.hooks.count == 6)
        #expect(
            Set(inventory.hooks.map(\.source.tier)) == [
                "local", "skill", "subagent", "plugin", "managed"
            ])
        #expect(inventory.hooks.filter { $0.canRemove }.count == 1)
        let readOnly = try #require(inventory.hooks.first { $0.source.tier == "plugin" })
        try JSONEncoder().encode([HookCleanupRequest(hookID: readOnly.id)])
            .write(to: URL(fileURLWithPath: tree.path + "/requests.json"))
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        let plan = try JSONDecoder().decode(HookCleanupPlan.self, from: preview.stdout)
        #expect(plan.batch.commands.isEmpty)
        #expect(!plan.instructions.isEmpty)
        #expect(try String(contentsOfFile: plugin + "/hooks/hooks.json", encoding: .utf8) == config)
    }

    private struct SourceFixture {
        let home: String
        let project: String
        let system: String
        let plugin: String
        let config: String
    }

    private func sourceFixture(_ tree: TempTree) throws -> SourceFixture {
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let system = try tree.dir("system")
        let plugin = try tree.dir("plugin")
        let config = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}
            """
        try tree.file("project/.claude/settings.local.json", contents: config)
        let markdown = """
            ---
            name: example
            hooks:
              Stop:
                - hooks:
                    - type: command
                      command: /usr/bin/true
            ---
            Source content stays untouched.
            """
        try tree.file("home/.claude/skills/demo/SKILL.md", contents: markdown)
        try tree.file("home/.claude/agents/demo.md", contents: markdown)
        try tree.file("plugin/hooks/hooks.json", contents: config)
        try tree.file("plugin/.claude-plugin/plugin.json", contents: "{\"name\":\"demo\"}")
        try tree.file(
            "home/.claude/plugins/installed_plugins.json",
            contents: """
                {"version":2,"plugins":{"demo@team":[{"scope":"user","installPath":"\(plugin)","version":"1.0"}]}}
                """)
        try tree.file(
            "system/Library/Application Support/ClaudeCode/managed-settings.json", contents: config)
        try tree.file(
            "system/etc/codex/requirements.toml",
            contents: """
                [[hooks.Stop]]
                [[hooks.Stop.hooks]]
                type = "command"
                command = "/usr/bin/true"
                """)
        return SourceFixture(
            home: home, project: project, system: system, plugin: plugin, config: config)
    }

    @Test("Codex inline plugin declarations and managed preference payloads are additive")
    func inlineSources() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let system = try tree.dir("system")
        let pluginPath = "home/.codex/plugins/cache/team/demo/1.0"
        try tree.file(
            "home/.codex/config.toml",
            contents: """
                [plugins."demo@team"]
                enabled = true
                """)
        try tree.file(
            pluginPath + "/plugin.json",
            contents: """
                {"$schema":"https://agent-plugins.org/schemas/plugin.json","name":"demo","hooks":[
                    {"hooks":{"Stop":[{"hooks":[{"type":"prompt","prompt":"first"}]}]}},
                    {"hooks":{"Stop":[{"hooks":[{"type":"agent","prompt":"second"}]}]}}
                ]}
                """)
        let toml = """
            [[hooks.Stop]]
            [[hooks.Stop.hooks]]
            type = "mcp_tool"
            server = "audit"
            tool = "check"
            [hooks.Stop.hooks.input]
            field = "${tool_input.command}"
            """
        let plist: [String: String] = [
            "config_toml_base64": Data(toml.utf8).base64EncodedString(),
            "requirements_toml_base64": Data(toml.utf8).base64EncodedString()
        ]
        let path = try tree.file("system/Library/Managed Preferences/com.openai.codex.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path))
        let result = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, extra: ["SUKIRU_SYSTEM_ROOT": system]))
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        let inventory = try #require(report.hookInventory)
        #expect(inventory.issues.isEmpty)
        #expect(inventory.hooks.count == 4)
        #expect(Set(inventory.hooks.map(\.id)).count == 4)
        #expect(inventory.hooks.allSatisfy { !$0.canRemove })
    }

    @Test(
        "Malformed, unsupported, and ambiguous sources are inspection problems without mutation",
        arguments: ["hooks.Stop = []", "hooks\t= { Stop = [] }", "[hooks]\nStop = []"])
    func invalidSources(toml: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file("home/.claude/settings.json", contents: "{\"hooks\":{},\"hooks\":{}}")
        try tree.file("home/.codex/hooks.json", contents: "{not json")
        try tree.file("home/.codex/config.toml", contents: toml)
        let result = try CLIRunner.run(
            ["scan", "--format", "json"], environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        #expect(report.hookInventory?.issues.count == 3)
        #expect(report.hookInventory?.hooks.isEmpty == true)
    }
}
