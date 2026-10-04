import Foundation
import SukiruCore
import Testing

@Suite("Passive hook hygiene CLI", .serialized)
struct HookCLIIntegrationTests {
    @Test("A saved plan refuses source drift before any cleanup")
    func sourceRace() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let original = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/missing/hook"}]}]}}
            """
        try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let planPath = try planFirstHook(tree: tree, environment: env)
        let edited = original + "\n "
        try tree.file("home/.claude/settings.json", contents: edited)
        let result = try executePlan(planPath, environment: env)
        #expect(result.exitCode == 1)
        #expect(String(bytes: result.stderr, encoding: .utf8)!.contains("Rescan and replan"))
        #expect(
            try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8) == edited)
    }

    @Test("TOML cleanup preserves comments and siblings and removes only emptied hook tables")
    func tomlRemoval() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let text = """
            # model selection
            model = "keep"
            [[hooks.Stop]]
            matcher = "Bash"
            [[hooks.Stop.hooks]]
            type = "command"
            command = "/missing/first"
            # sibling stays
            [[hooks.Stop.hooks]]
            type = "command"
            command = "/missing/second"
            [features]
            hooks = true # keep feature setting
            """
        try tree.file("home/.codex/config.toml", contents: text)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let path = try planFirstHook(tree: tree, environment: env)
        let result = try executePlan(path, environment: env)
        #expect(result.exitCode == 0)
        let after = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        #expect(!after.contains("/missing/first"))
        #expect(after.contains("/missing/second"))
        #expect(after.contains("# sibling stays"))
        #expect(after.hasPrefix("# model selection\nmodel = \"keep\""))
        #expect(after.contains("hooks = true # keep feature setting"))
    }

    func planFirstHook(tree: TempTree, environment: [String: String]) throws -> String {
        let scan = try CLIRunner.run(["scan", "--json"], environment: environment)
        let object = try #require(try scan.jsonObject())
        let inventory = try #require(object["hookInventory"] as? [String: Any])
        let hooks = try #require(inventory["hooks"] as? [[String: Any]])
        let id = try #require(hooks.first?["id"] as? String)
        let requestPath = tree.path + "/requests.json"
        try JSONSerialization.data(withJSONObject: [["action": "remove", "hookID": id]])
            .write(to: URL(fileURLWithPath: requestPath))
        let plan = try CLIRunner.run(
            ["hooks", "plan", "--requests", requestPath], environment: environment)
        #expect(plan.exitCode == 0, "\(String(bytes: plan.stderr, encoding: .utf8)!)")
        let planPath = tree.path + "/plan.json"
        try plan.stdout.write(to: URL(fileURLWithPath: planPath))
        return planPath
    }

    func executePlan(_ path: String, environment: [String: String]) throws -> CLIRunner.Result {
        try CLIRunner.run(
            ["hooks", "execute", "--plan", path, "--yes", "--confirm-dangerous"],
            environment: environment)
    }

    @Test("Exact duplicate removal preserves unrelated bytes and supports diff and rollback")
    func removalRoundTrip() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let original = """
            { "model": "keep", "hooks": { "Stop": [{ "matcher": "Bash", "hooks": [
              {"type":"command","command":"/missing/duplicate"},
              {"type":"command","command":"/missing/duplicate"}
            ]}], "SessionStart": [] }, "permissions": { "allow": ["Read"] } }
            """
        try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        let object = try #require(try scan.jsonObject())
        let inventory = try #require(object["hookInventory"] as? [String: Any])
        let hooks = try #require(inventory["hooks"] as? [[String: Any]])
        let id = try #require(hooks.first?["id"] as? String)
        let requests = [["action": "remove", "hookID": id]]
        try JSONSerialization.data(withJSONObject: requests).write(
            to: URL(fileURLWithPath: tree.path + "/requests.json"))
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0)
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        #expect(
            try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8) == original
        )
        let result = try CLIRunner.run(
            [
                "hooks", "execute", "--plan", tree.path + "/plan.json", "--yes",
                "--confirm-dangerous"
            ], environment: env)
        #expect(result.exitCode == 0, "\(String(bytes: result.stderr, encoding: .utf8)!)")
        let record = try #require(try result.jsonObject())
        let after = try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)
        #expect(after.components(separatedBy: "/missing/duplicate").count == 2)
        #expect(after.contains("\"SessionStart\": []"))
        #expect(after.contains("\"permissions\": { \"allow\": [\"Read\"] }"))
        let diff = try #require(record["diff"] as? [String: Any])
        #expect((diff["entries"] as? [[String: Any]])?.isEmpty == false)
        let batchID = try #require(record["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID], environment: env)
        #expect(rollback.exitCode == 0)
        #expect(
            try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8) == original
        )
    }

    @Test("Additive host sources expose handlers and health without executing them")
    func passiveInventory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let marker = tree.path + "/executed"
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[
                  {"type":"command","command":"/missing/hook.sh"},
                  {"type":"command","command":"touch '\(marker)' | cat"},
                  {"type":"http","url":"http://127.0.0.1:9/hook"},
                  {"type":"mcp_tool","server":"audit","tool":"check","input":{"x":1}}
                ]}]}}
                """)
        try tree.file(
            "project/.codex/hooks.json",
            contents: """
                {"hooks":{"SessionStart":[{"hooks":[{"type":"prompt","prompt":"inspect"}]}]}}
                """)
        try tree.file(
            "project/.codex/config.toml",
            contents: """
                model = "example"
                [[hooks.Stop]]
                matcher = "Bash"
                [[hooks.Stop.hooks]]
                type = "command"
                command = "${DYNAMIC}/hook"
                """)
        let result = try CLIRunner.run(
            ["scan", "--json"],
            environment: CLIRunner.fixtureEnvironment(home: home, roots: [project]))
        #expect(result.exitCode == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["hookInventory"] as? [String: Any])
        let hooks = try #require(inventory["hooks"] as? [[String: Any]])
        #expect(hooks.count == 6)
        #expect(hooks.filter { $0["health"] as? String == "brokenTarget" }.count == 1)
        #expect(report.skills.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
