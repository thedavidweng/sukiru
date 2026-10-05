import Foundation
import Testing

@testable import SukiruCore

extension RealCLIEndToEndTests {
    @Test(
        "Pinned real npx removes only Claude entries, predicts shared deletion, and rolls back",
        arguments: [false, true])
    func hostRemovalRoundTrip(otherHostPresent: Bool) throws {
        let tree = try TempTree()
        let (home, bin) = try Self.prepareHostRemoval(tree, otherHostPresent: otherHostPresent)
        let environment = CLIRunner.fixtureEnvironment(home: home, path: bin + ":/usr/bin:/bin")
        let args = ["skills", "uninstall", "--all", "--host", "claude-code", "--scope", "user"]
        let preview = try CLIRunner.run(
            args + ["--dry-run"], environment: environment, timeout: Support.batchTimeout)
        #expect(preview.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(preview))")
        let object = try #require(try preview.jsonObject())
        let plan = try #require(object["plan"] as? [String: Any])
        #expect(
            plan["sharedCopyDeletions"] as? [String] == (otherHostPresent ? [] : ["shared-tool"]))
        let before = try Self.hostRemovalState(home: home)
        let canary = Support.HomeCanary()
        let result = try CLIRunner.run(
            args + ["--yes", "--confirm-dangerous"], environment: environment,
            timeout: Support.batchTimeout)
        #expect(result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))")
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "succeeded")
        #expect(!FileManager.default.fileExists(atPath: home + "/.claude/skills/shared-tool"))
        #expect(FileManager.default.fileExists(atPath: home + "/.claude/skills/orphan/SKILL.md"))
        #expect(
            FileManager.default.fileExists(atPath: home + "/.agents/skills/shared-tool")
                == otherHostPresent)
        if otherHostPresent {
            #expect(
                FileManager.default.fileExists(atPath: home + "/.codex/skills/shared-tool/SKILL.md")
            )
        }
        let batchID = try #require(record["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--batch", batchID, "--yes"], environment: environment)
        #expect(
            rollback.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(rollback))")
        #expect(try Self.hostRemovalState(home: home) == before)
        #expect(try Support.transcript(tree).contains("remove shared-tool -a claude-code -g -y"))
        try canary.verifyUnchanged()
    }

    private static func prepareHostRemoval(_ tree: TempTree, otherHostPresent: Bool) throws -> (
        String, String
    ) {
        let home = try tree.dir("home")
        try tree.file(
            "home/.agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["shared-tool"])
        )
        try tree.file(
            "home/.agents/skills/shared-tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("shared-tool"))
        try tree.symlink(
            "home/.claude/skills/shared-tool", to: home + "/.agents/skills/shared-tool")
        try tree.file(
            "home/.claude/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))
        if otherHostPresent {
            try tree.file("home/.codex/config.toml", contents: "")
            try tree.symlink(
                "home/.codex/skills/shared-tool", to: home + "/.agents/skills/shared-tool")
        }
        let bin = try Support.installToolWrappers(
            try Support.resolveTools(), into: tree, skillsVersion: "1.7.0")
        return (home, bin)
    }

    private static func hostRemovalState(home: String) throws -> [String: String] {
        // npm's downloaded package cache is outside the removal's mutation bounds.
        try TreeChecksum.manifest(root: home).filter {
            $0.key.hasPrefix(".agents") || $0.key.hasPrefix(".claude") || $0.key.hasPrefix(".codex")
        }
    }
}
