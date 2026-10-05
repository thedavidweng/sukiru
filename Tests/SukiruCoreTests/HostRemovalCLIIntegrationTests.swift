import Foundation
import Testing

@testable import SukiruCore

@Suite("Host removal CLI")
struct HostRemovalCLIIntegrationTests {
    @Test("Bulk uninstall requires a host and dry-run prints all three lists without writes")
    func dryRun() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.symlink(".claude/skills/a", to: home.path + "/.agents/skills/a")
        try home.file(".claude/skills/own/SKILL.md", contents: OwnershipBuilders.skillMD("own"))
        try home.executable("bin/npx", contents: "#!/bin/sh\necho 1.7.0\n")
        let environment = CLIRunner.fixtureEnvironment(
            home: home.path, path: home.path + "/bin:/usr/bin:/bin")
        let refused = try CLIRunner.run(
            ["skills", "uninstall", "--all", "--dry-run"], environment: environment)
        #expect(refused.exitCode == 64)
        #expect(BatchExecutionSupport.stderrText(refused).contains("--host"))
        let before = try TreeChecksum.manifest(root: home.path)
        let result = try CLIRunner.run(
            [
                "skills", "uninstall", "--all", "--host", "claude-code", "--scope", "user",
                "--dry-run"
            ], environment: environment)
        #expect(result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))")
        let json = try #require(try result.jsonObject())
        let plan = try #require(json["plan"] as? [String: Any])
        #expect((plan["removed"] as? [[String: Any]])?.count == 1)
        #expect((plan["leftInPlace"] as? [[String: Any]])?.count == 1)
        let visible = try #require(plan["stillVisible"] as? [[String: Any]])
        #expect(visible.only?["sourceFolder"] as? String == home.path + "/.claude/skills")
        #expect(try TreeChecksum.manifest(root: home.path) == before)
        let danger = try CLIRunner.run(
            ["skills", "uninstall", "--all", "--host", "claude-code", "--scope", "user", "--yes"],
            environment: environment)
        #expect(danger.exitCode == 1)
        #expect(BatchExecutionSupport.stderrText(danger).contains("--confirm-dangerous"))
        #expect(try TreeChecksum.manifest(root: home.path) == before)
    }
}
