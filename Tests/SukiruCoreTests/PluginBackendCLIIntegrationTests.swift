import Foundation
import Testing

@Suite("Confirmed plugin backend operations")
struct PluginBackendCLIIntegrationTests {
    @Test(
        "Codex curated operations disclose backend effects and require consent",
        arguments: ["install", "remove"])
    func curatedOperation(action: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/backend-call"
        try installShim(tree: tree, marker: marker)
        let request = try tree.file(
            "requests.json",
            contents: """
                [{"host":"codex","action":"\(action)","target":"demo@openai-curated-remote",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let plan = try CLIRunner.run(["plugins", "plan", "--requests", request], environment: env)
        let planned = try #require(try plan.jsonObject())
        let batch = try #require(planned["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        let native = action == "install" ? "add" : "remove"
        #expect(
            command["argv"] as? [String] == [
                "codex", "plugin", native, "demo@openai-curated-remote", "--json"
            ])
        #expect(
            (command["warning"] as? String)?.contains("does not reverse backend installation")
                == true)
        let refused = try CLIRunner.run(
            ["plugins", "execute", "--requests", request, "--yes"], environment: env)
        #expect(refused.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker))
        let execute = try CLIRunner.run(
            ["plugins", "execute", "--requests", request, "--yes", "--confirm-dangerous"],
            environment: env)
        #expect(execute.exitCode == 0)
        let record = try #require(try execute.jsonObject())
        #expect((record["unrestorableEffects"] as? [String])?.first?.contains("backend") == true)
        #expect(
            try String(contentsOfFile: marker, encoding: .utf8)
                == "plugin \(native) demo@openai-curated-remote --json")
        let id = try #require(record["batchID"] as? String)
        #expect(
            try CLIRunner.run(["rollback", "--yes", "--batch", id], environment: env).exitCode == 0)
        let directory = try #require(record["recordDirectory"] as? String)
        let saved =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: directory + "/record.json")))
            as? [String: Any]
        #expect(
            saved?["unrestorableEffects"] as? [String] == record["unrestorableEffects"] as? [String]
        )
        #expect(saved?["batchStatus"] as? String == "rolledBack")
    }
    private func installShim(tree: TempTree, marker: String) throws {
        try tree.executable(
            "bin/codex",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 'codex-cli 0.160.0';;
                *--help*) echo '--json';;
                *) printf '%s' "$*" > '\(marker)'; echo '{}';;
                esac
                """)
    }

}
