import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    private static let hermesConfig =
        "model: x\nplugins:\n  enabled:\n    - orca-status\n    - spotify\n  disabled: []\n"

    @Test("Orca extensions, Hermes entries, and orphaned helpers clean up and roll back together")
    func orcaExtensionLeftovers() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let piExtension = try tree.file(
            "home/.pi/agent/extensions/orca-agent-status.ts", contents: "// x")
        let own = try tree.file("home/.pi/agent/extensions/rtk.ts", contents: "// mine")
        let plugin = try tree.file(
            "home/.config/opencode/plugins/orca-opencode-status.js", contents: "// x")
        let tui = try tree.file(
            "home/.config/opencode/plugins/orca-opencode-status-tui/tui.js", contents: "// x")
        let amp = try tree.file("home/.config/amp/plugins/orca-agent-status.ts", contents: "// x")
        let orphan = try tree.file(
            "home/.orca/agent-hooks/antigravity-hook.sh", contents: "#!/bin/sh\nexit 0")
        let config = try tree.file("home/.hermes/config.yaml", contents: Self.hermesConfig)
        try tree.dir("home/.hermes/plugins/spotify")
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"SessionStart":[{"hooks":[{"type":"command",
                  "command":"/bin/sh -c 'rex session-start || true'"}]}]}}
                """)
        try tree.file(
            "requests.json", contents: #"[{"action":"remove-leftovers","producer":"Orca"}]"#)
        let env = CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin")

        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        let report = try JSONDecoder().decode(ScanReport.self, from: scan.stdout)
        let found = try #require(report.extensionInventory?.extensions)
        #expect(found.filter { $0.producer == "Orca" }.count == 5)
        #expect(found.contains { $0.path == own && $0.producer == "Unknown" })

        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0, "\(String(bytes: preview.stderr, encoding: .utf8)!)")
        let plan = try JSONDecoder().decode(HookCleanupPlan.self, from: preview.stdout)
        #expect(plan.extensions.count == 5)
        #expect(plan.helperPaths == [orphan])
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        let result = try executePlan(tree.path + "/plan.json", environment: env)
        #expect(result.exitCode == 0, "\(String(bytes: result.stderr, encoding: .utf8)!)")

        let removed = [piExtension, plugin, tui, amp, orphan]
        #expect(removed.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(FileManager.default.fileExists(atPath: own))
        let hermes = try String(contentsOfFile: config, encoding: .utf8)
        #expect(hermes == "model: x\nplugins:\n  enabled:\n    - spotify\n  disabled: []\n")

        let id = try #require(try result.jsonObject()?["batchID"] as? String)
        let rollback = try CLIRunner.run(["rollback", "--yes", "--batch", id], environment: env)
        #expect(rollback.exitCode == 0, "\(String(bytes: rollback.stderr, encoding: .utf8)!)")
        #expect(removed.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(try String(contentsOfFile: config, encoding: .utf8).contains("orca-status"))
    }
}
