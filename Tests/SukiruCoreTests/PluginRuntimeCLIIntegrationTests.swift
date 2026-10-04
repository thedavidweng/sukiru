import Foundation
import Testing

@Suite("Explicit OpenCode runtime operations")
struct PluginRuntimeCLIIntegrationTests {
    @Test(
        "Runtime list check and update require consent and restore captured partial effects",
        arguments: ["list", "check", "update"], ["user", "project"])
    func runtimeOperation(action: String, scope: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let root = scope == "user" ? home : project
        let exitCode = scope == "user" ? 3 : 0
        let original = "saved runtime state"
        let state = try tree.file("home/.opencode/state", contents: original)
        try installShim(tree: tree, state: state, exitCode: exitCode)
        let request = try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"\(action)","target":"*",
                  "scope":"\(scope)","scopeRoot":"\(root)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(
            home: home, roots: [project], path: tree.path + "/bin:/usr/bin:/bin")
        let scan = try CLIRunner.run(["scan", "--format", "json"], environment: env)
        #expect(scan.exitCode == 0)
        #expect(try String(contentsOfFile: state, encoding: .utf8) == original)
        let plan = try CLIRunner.run(["plugins", "plan", "--requests", request], environment: env)
        let planned = try #require(try plan.jsonObject())
        let batch = try #require(planned["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        #expect(command["argv"] as? [String] == ["opencode", "plugin", action])
        #expect((command["warning"] as? String)?.contains("all package plugins") == true)
        #expect(try String(contentsOfFile: state, encoding: .utf8) == original)
        let refused = try CLIRunner.run(
            ["plugins", "execute", "--requests", request, "--reviewed"], environment: env)
        #expect(refused.exitCode == 1)
        #expect(try String(contentsOfFile: state, encoding: .utf8) == original)
        let execute = try CLIRunner.run(
            ["plugins", "execute", "--requests", request, "--reviewed", "--confirm-dangerous"],
            environment: env)
        #expect(execute.exitCode == (exitCode == 0 ? 0 : 1))
        #expect(try String(contentsOfFile: state, encoding: .utf8) == root + ":plugin " + action)
        let record = try #require(try execute.jsonObject())
        #expect((record["unrestorableEffects"] as? [String])?.isEmpty == false)
        let id = try #require(record["batchID"] as? String)
        let rollback = try CLIRunner.run(["rollback", "--batch", id], environment: env)
        #expect(rollback.exitCode == 0)
        #expect(try String(contentsOfFile: state, encoding: .utf8) == original)
        try verifyEffectsHistory(record)
    }
    private func installShim(tree: TempTree, state: String, exitCode: Int) throws {
        try tree.executable(
            "bin/opencode",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo v2.0.22;;
                *--help*) echo 'list check update';;
                *) printf '%s:%s' "$PWD" "$*" > '\(state)'; echo 'runtime result'; exit \(exitCode);;
                esac
                """)
    }

    private func verifyEffectsHistory(_ record: [String: Any]) throws {
        let directory = try #require(record["recordDirectory"] as? String)
        let saved =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: directory + "/record.json")))
            as? [String: Any]
        #expect(
            saved?["unrestorableEffects"] as? [String] == record["unrestorableEffects"] as? [String]
        )
    }

}
