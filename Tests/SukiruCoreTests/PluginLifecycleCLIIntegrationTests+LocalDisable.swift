import Darwin
import Foundation
import Testing

extension PluginLifecycleCLIIntegrationTests {
    @Test("Local disable requires confirmation and restores files with later-edit choices")
    func localDisableRoundTrip() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let source = "export const Legacy = async () => ({})\n"
        let plugin = try tree.file("home/.config/opencode/plugins/old.ts", contents: source)
        try tree.executable(
            "bin/opencode",
            contents: "#!/bin/sh\ncase \"$*\" in\n--version) echo v2.0.22;;\n*) exit 91;;\nesac\n")
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"disable-local","target":"\(plugin)",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let request = ["--requests", tree.path + "/requests.json"]
        let plan = try CLIRunner.run(["plugins", "plan"] + request, environment: env)
        #expect(plan.exitCode == 0)
        let preview = try #require(try plan.jsonObject())
        let batch = try #require(preview["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        #expect((command["warning"] as? String)?.contains("does not restore behavior") == true)
        let refused = try CLIRunner.run(
            ["plugins", "execute"] + request + ["--yes"], environment: env)
        #expect(refused.exitCode == 1)
        #expect(try String(contentsOfFile: plugin, encoding: .utf8) == source)
        let executed = try CLIRunner.run(
            ["plugins", "execute"] + request + ["--yes", "--confirm-dangerous"],
            environment: env)
        #expect(executed.exitCode == 0)
        let record = try #require(try executed.jsonObject())
        let batchID = try #require(record["batchID"] as? String)
        #expect(record["batchStatus"] as? String == "succeeded")
        #expect(!FileManager.default.fileExists(atPath: plugin))
        let diff = try #require(record["diff"] as? [String: Any])
        let entries = try #require(diff["entries"] as? [[String: Any]])
        #expect(entries.contains { $0["path"] as? String == plugin })
        let disabled = try #require(
            entries.compactMap { $0["path"] as? String }.first {
                $0.contains("disabled-plugins/") && $0.hasSuffix("old.ts")
            })
        #expect(try String(contentsOfFile: disabled, encoding: .utf8) == source)
        try restoreAfterLaterEdit(disabled: disabled, batchID: batchID, env: env)
        #expect(try String(contentsOfFile: plugin, encoding: .utf8) == source)
        #expect(!FileManager.default.fileExists(atPath: disabled))
    }

    private func restoreAfterLaterEdit(
        disabled: String, batchID: String, env: [String: String]
    ) throws {
        try "later edit".write(toFile: disabled, atomically: true, encoding: .utf8)
        let conflict = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID], environment: env)
        #expect(conflict.exitCode == 1)
        let conflictJSON = try #require(try conflict.jsonObject())
        #expect(
            (conflictJSON["conflicts"] as? [[String: Any]])?.contains {
                $0["path"] as? String == disabled
            } == true)
        let restored = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID, "--restore", disabled], environment: env)
        #expect(restored.exitCode == 0)
    }

    @Test("Local disable backup failure leaves the discovered file in place")
    func localDisableCaptureFailure() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let plugin = try tree.file(
            "home/.config/opencode/plugins/old.ts",
            contents: "export const Legacy = async () => ({})")
        try tree.dir("home/.config/opencode/disabled-plugins")
        let fifo = home + "/.config/opencode/disabled-plugins/fifo"
        #expect(mkfifo(fifo, 0o600) == 0)
        try tree.executable("bin/opencode", contents: "#!/bin/sh\necho v2.0.22\n")
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"disable-local","target":"\(plugin)",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            [
                "plugins", "execute", "--requests", tree.path + "/requests.json",
                "--yes", "--confirm-dangerous"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: plugin))
    }
}
