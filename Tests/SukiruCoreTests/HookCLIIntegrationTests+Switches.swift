import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test("Documented hook switches: Kiro per-hook enabled and file-wide disableAllHooks")
    func documentedHookSwitches() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let kiro = try tree.file(
            "home/.kiro/hooks/lint.json",
            contents: """
                {"version":"v1","hooks":[{"name":"lint","trigger":"stop",
                  "action":{"type":"command","command":"make lint"}}]}
                """)
        let qwen = try tree.file(
            "home/.qwen/settings.json",
            contents:
                "{\n  \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"x\"}]}]}\n}\n"
        )
        let copilot = try tree.file(
            "home/.copilot/hooks/team.json",
            contents: "{\"version\":1,\"hooks\":{\"Stop\":[{\"type\":\"command\",\"bash\":\"y\"}]}}"
        )
        let env = CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin")
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        let hooks = try #require(
            try JSONDecoder().decode(ScanReport.self, from: scan.stdout).hookInventory?.hooks)
        let lint = try #require(hooks.first { $0.source.path == kiro })
        let requests = [
            HookCleanupRequest(action: "set-hook-enabled", hookID: lint.id, enabled: false),
            HookCleanupRequest(action: "set-disable-all", path: qwen, disableAllHooks: true),
            HookCleanupRequest(action: "set-disable-all", path: copilot, disableAllHooks: true)
        ]
        try JSONEncoder().encode(requests).write(
            to: URL(fileURLWithPath: tree.path + "/requests.json"))
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0, "\(String(bytes: preview.stderr, encoding: .utf8)!)")
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        let result = try executePlan(tree.path + "/plan.json", environment: env)
        #expect(
            result.exitCode == 0,
            "\(String(bytes: result.stdout + result.stderr, encoding: .utf8)!)")

        let read = { (path: String) in try String(contentsOfFile: path, encoding: .utf8) }
        #expect(
            try read(kiro).contains("\"enabled\": false")
                || read(kiro).contains("\"enabled\":false"))
        #expect(try read(qwen).contains("\"disableAllHooks\": true"))
        #expect(try read(copilot).contains("\"disableAllHooks\":true"))
        let rescan = try CLIRunner.run(["scan", "--json"], environment: env)
        let after = try #require(
            try JSONDecoder().decode(ScanReport.self, from: rescan.stdout).hookInventory?.hooks)
        #expect(
            after.filter { $0.source.path == kiro }.allSatisfy {
                !HookCleanupPlanner.hookEnabled($0)
            })
    }

    @Test("Kiro toggles use scanned indices when a removal shares the file")
    func kiroToggleWithRemoval() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let kiro = try tree.file(
            "home/.kiro/hooks/team.json",
            contents: """
                {"version":"v1","hooks":[
                  {"name":"a","trigger":"stop","action":{"type":"command","command":"a"}},
                  {"name":"b","trigger":"stop","action":{"type":"command","command":"b"}},
                  {"name":"c","trigger":"stop","action":{"type":"command","command":"c"}}]}
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin")
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        let hooks = try #require(
            try JSONDecoder().decode(ScanReport.self, from: scan.stdout).hookInventory?.hooks)
        let named = { (name: String) in hooks.first { $0.details["command"]?.stringValue == name } }
        let requests = [
            HookCleanupRequest(action: "remove", hookID: try #require(named("a")).id),
            HookCleanupRequest(
                action: "set-hook-enabled", hookID: try #require(named("b")).id, enabled: false)
        ]
        try JSONEncoder().encode(requests).write(
            to: URL(fileURLWithPath: tree.path + "/requests.json"))
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0, "\(String(bytes: preview.stderr, encoding: .utf8)!)")
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        let result = try executePlan(tree.path + "/plan.json", environment: env)
        #expect(result.exitCode == 0)

        let after = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: kiro)))
        let left = after["hooks"]?.arrayValue ?? []
        #expect(left.map { $0["name"]?.stringValue } == ["b", "c"])
        #expect(left.map { $0["enabled"]?.boolValue } == [false, nil])
    }

    @Test("A command that only mentions an Orca payload is not Orca's; project plans skip add-ons")
    func orcaMentionAndProjectScope() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[{"type":"command",
                  "command":"echo \(home)/.orca/agent-hooks/claude-hook.sh"}]}]}}
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin")
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        let hooks = try #require(
            try JSONDecoder().decode(ScanReport.self, from: scan.stdout).hookInventory?.hooks)
        #expect(hooks.count == 1)
        #expect(hooks.allSatisfy { $0.attribution.producer != "Orca" })

        let requests = [HookCleanupRequest(action: "remove-extension", extensionID: "pi:any")]
        try JSONEncoder().encode(requests).write(
            to: URL(fileURLWithPath: tree.path + "/requests.json"))
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--scope", "project", "--requests", tree.path + "/requests.json"],
            environment: env)
        #expect(preview.exitCode != 0)
        #expect(String(bytes: preview.stderr, encoding: .utf8)!.contains("user scope"))
    }
}
