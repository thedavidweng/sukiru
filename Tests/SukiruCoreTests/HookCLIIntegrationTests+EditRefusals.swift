import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test("A saved add refuses a source that changed or appeared after planning")
    func staleEditRefusal() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let source = try tree.file("home/.claude/settings.json", contents: "{}\n")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let add: [[String: Any]] = [
            [
                "action": "add", "host": "claude", "event": "Stop",
                "handler": ["type": "command", "command": "say done"]
            ]
        ]
        let plan = try planEdits(add, tree: tree, environment: env)
        try tree.file("home/.claude/settings.json", contents: "{\"model\": \"opus\"}\n")
        let result = try executePlan(plan, environment: env)
        #expect(result.exitCode == 1)
        #expect(String(bytes: result.stderr, encoding: .utf8)!.contains("Rescan and replan"))
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "{\"model\": \"opus\"}\n")

        let codex: [[String: Any]] = [
            [
                "action": "add", "host": "codex", "event": "Stop",
                "handler": ["type": "command", "command": "notify"]
            ]
        ]
        let absent = try planEdits(codex, tree: tree, environment: env)
        let appeared = try tree.file("home/.codex/hooks.json", contents: "{}\n")
        #expect(try executePlan(absent, environment: env).exitCode == 1)
        #expect(try String(contentsOfFile: appeared, encoding: .utf8) == "{}\n")
    }

    @Test("Skill, plugin, and unregistered sources and undocumented events are refused")
    func refusedEdits() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let skill = Self.hookedSkill
        let skillPath = try tree.file("home/.claude/skills/demo/SKILL.md", contents: skill)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let id = try hookID(command: "skill-hook", environment: env)
        let edit = try runPlan(
            [
                [
                    "action": "edit", "hookID": id,
                    "handler": ["type": "command", "command": "changed"]
                ]
            ], tree: tree, environment: env)
        #expect(edit.exitCode != 0)
        #expect(String(bytes: edit.stderr, encoding: .utf8)!.contains("read-only"))
        #expect(try String(contentsOfFile: skillPath, encoding: .utf8) == skill)
        let handler = ["type": "command", "command": "x"]
        let unregistered = try runPlan(
            [
                [
                    "action": "add", "host": "claude", "scope": "project",
                    "scopeRoot": tree.path + "/elsewhere", "event": "Stop", "handler": handler
                ]
            ], tree: tree, environment: env)
        #expect(unregistered.exitCode != 0)
        let claudeEvent = try runPlan(
            [["action": "add", "host": "claude", "event": "BeforeAnything", "handler": handler]],
            tree: tree, environment: env)
        #expect(claudeEvent.exitCode != 0)
        #expect(String(bytes: claudeEvent.stderr, encoding: .utf8)!.contains("does not document"))
        let codexEvent = try runPlan(
            [["action": "add", "host": "codex", "event": "BeforeAnything", "handler": handler]],
            tree: tree, environment: env)
        #expect(codexEvent.exitCode == 0)
        #expect(String(bytes: codexEvent.stdout, encoding: .utf8)!.contains("does not document"))
        let status = try runPlan(
            [
                [
                    "action": "add", "host": "claude", "event": "Stop",
                    "handler": ["type": "command", "command": "x", "statusMessage": "Hi"]
                ]
            ], tree: tree, environment: env)
        #expect(status.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: home + "/.claude/settings.json"))
    }

    private static let hookedSkill = """
        ---
        name: demo
        description: Hook in a skill
        hooks:
          Stop:
            - hooks:
                - type: command
                  command: skill-hook
        ---
        """
}
