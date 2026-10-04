import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test("A newly discovered alias invalidates a reviewed helper deletion before any writes")
    func lateHelperReference() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let helper = try tree.file("home/.orca/agent-hooks/claude-hook.sh", contents: "keep")
        let original = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh '\(helper)'"}]}]}}
            """
        let source = try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let path = try planFirstHook(tree: tree, environment: env)
        try tree.symlink("home/alias.sh", to: helper)
        try tree.file(
            "home/.codex/hooks.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh '\(home)/alias.sh'"}]}]}}
                """)
        #expect(try executePlan(path, environment: env).exitCode == 1)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == original)
        #expect(try String(contentsOfFile: helper, encoding: .utf8) == "keep")
    }

    @Test("Rollback preserves a helper recreated after cleanup")
    func recreatedHelperConflict() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let helper = try tree.file("home/.orca/agent-hooks/claude-hook.sh", contents: "original")
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh '\(helper)'"}]}]}}
                """)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let path = try planFirstHook(tree: tree, environment: env)
        let executed = try executePlan(path, environment: env)
        #expect(executed.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: helper))
        try tree.file("home/.orca/agent-hooks/claude-hook.sh", contents: "later")
        let record = try #require(try executed.jsonObject())
        let id = try #require(record["batchID"] as? String)
        #expect(
            try CLIRunner.run(["rollback", "--yes", "--batch", id], environment: env).exitCode == 1)
        #expect(try String(contentsOfFile: helper, encoding: .utf8) == "later")
        #expect(
            try CLIRunner.run(
                ["rollback", "--yes", "--batch", id, "--preserve", helper], environment: env
            ).exitCode == 0)
        #expect(try String(contentsOfFile: helper, encoding: .utf8) == "later")
    }

    @Test("A surviving symlink alias protects the producer helper")
    func helperAlias() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let helper = try tree.file("home/.orca/agent-hooks/claude-hook.sh", contents: "keep")
        try tree.symlink("home/alias.sh", to: helper)
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[
                  {"type":"command","command":"/bin/sh '\(helper)'"},
                  {"type":"command","command":"/bin/sh '\(home)/alias.sh'"}
                ]}]}}
                """)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let path = try planFirstHook(tree: tree, environment: env)
        let plan = try JSONDecoder().decode(
            HookCleanupPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(plan.helperPaths.isEmpty)
        #expect(try executePlan(path, environment: env).exitCode == 0)
        #expect(try String(contentsOfFile: helper, encoding: .utf8) == "keep")
    }

    @Test("Shell semantics, PATH targets, and producer names receive conservative diagnoses")
    func literalSemantics() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.executable("bin/muxy-not-a-producer", contents: "#!/bin/sh\nexit 0")
        let commands = [
            "muxy-not-a-producer", "absent-on-path", "'/missing/orca-helper.sh'",
            "/bin/sh \"~/Library/Application Support/Muxy/hooks/a.sh\"",
            "/bin/sh \"\" /missing/shifted.sh", "${RUNTIME}/hook", "printf orca",
            "''~/missing/hook", "~\"/missing/hook\"", "/bin/sh /existing/foo\\\n.sh"
        ]
        let handlers = commands.map { ["type": "command", "command": $0] }
        let data = try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": handlers]]]
        ])
        let source = try tree.file("home/.claude/settings.json")
        try data.write(to: URL(fileURLWithPath: source))
        let result = try CLIRunner.run(
            ["hooks", "inventory"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        let inventory = try #require(report.hookInventory)
        #expect(inventory.hooks.allSatisfy { $0.attribution.producer == "Unknown" })
        #expect(inventory.hooks.filter { $0.health == .brokenTarget }.count == 2)
        #expect(inventory.hooks.filter { $0.health == .unknown }.count == 7)
    }

    @Test("Snapshot storage failure prevents hook mutation")
    func snapshotFailure() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let original = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/missing/hook"}]}]}}
            """
        let source = try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let path = try planFirstHook(tree: tree, environment: env)
        try tree.file(
            "home/Library/Application Support/Sukiru/snapshots", contents: "blocks storage")
        #expect(try executePlan(path, environment: env).exitCode == 1)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == original)
    }

    @Test(
        "Hook rollback preserves later edits and deletions until explicitly resolved",
        arguments: [false, true])
    func rollbackConflict(deleted: Bool) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let source = try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"keep":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/missing/hook"}]}]}}
                """)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let path = try planFirstHook(tree: tree, environment: env)
        let executed = try executePlan(path, environment: env)
        #expect(executed.exitCode == 0)
        let record = try #require(try executed.jsonObject())
        let id = try #require(record["batchID"] as? String)
        if deleted {
            try FileManager.default.removeItem(atPath: source)
        } else {
            try tree.file("home/.claude/settings.json", contents: "{\"later\":true}")
        }
        let result = try CLIRunner.run(["rollback", "--yes", "--batch", id], environment: env)
        #expect(result.exitCode == 1)
        let object = try #require(try result.jsonObject())
        let conflicts = try #require(object["conflicts"] as? [[String: Any]])
        #expect(conflicts.contains { $0["path"] as? String == source })
        if deleted {
            #expect(!FileManager.default.fileExists(atPath: source))
        } else {
            #expect(try String(contentsOfFile: source, encoding: .utf8) == "{\"later\":true}")
        }
    }
}
