import Foundation
import Testing

@testable import SukiruCore

/// `sukiru skills migrate` end to end: the reviewed commands of both
/// directions, the destination check, the danger acknowledgement, and a
/// shimmed execution that snapshots first.
@Suite("Skills migrate CLI", .serialized)
struct SkillMigrateCLIIntegrationTests {
    /// A Vercel-owned skill in link mode: the shared copy plus a host link,
    /// and a global lock whose `skillPath` is repo-relative.
    private static func vercelSkill(in home: TempTree, name: String) throws {
        try home.file(
            ".agents/.skill-lock.json",
            contents: """
                {
                  "version": 3,
                  "skills": {
                    "\(name)": {
                      "source": "thedavidweng/skills",
                      "sourceType": "github",
                      "sourceUrl": "https://github.com/thedavidweng/skills.git",
                      "skillPath": "maintenance/\(name)/SKILL.md",
                      "skillFolderHash": "8696469960d3f9233ee158b78a006798edb2cc49",
                      "installedAt": "2026-06-15T23:27:24.742Z",
                      "updatedAt": "2026-06-15T23:27:24.742Z"
                    }
                  },
                  "dismissed": {}
                }
                """)
        try home.file(".agents/skills/\(name)/SKILL.md", contents: OwnershipBuilders.skillMD(name))
        try home.symlink(
            ".claude/skills/\(name)", to: home.path + "/.agents/skills/\(name)")
    }

    private static func shims(in home: TempTree, transcript: String) throws -> String {
        let bin = try home.dir("bin")
        try home.executable(
            "bin/npx", contents: "#!/bin/sh\necho \"npx $@\" >> \"\(transcript)\"\n")
        try home.executable(
            "bin/gh", contents: "#!/bin/sh\necho \"gh $@\" >> \"\(transcript)\"\n")
        return bin
    }

    private static func argv(_ result: CLIRunner.Result) throws -> [[String]] {
        let batch = try #require(try result.jsonObject())
        let commands = try #require(batch["commands"] as? [[String: Any]])
        return try commands.map { try #require($0["argv"] as? [String]) }
    }

    @Test("Dry run prints the removal first and one gh install per skills folder, writing nothing")
    func dryRunVercelToGitHub() throws {
        let home = try TempTree()
        try Self.vercelSkill(in: home, name: "mig")
        let bin = try Self.shims(in: home, transcript: home.path + "/transcript.log")
        let before = try TreeChecksum.manifest(root: home.path)
        let result = try CLIRunner.run(
            ["skills", "migrate", "mig", "--installer", "github", "--dry-run", "--json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home.path, path: bin + ":/usr/bin:/bin"))
        #expect(result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))")
        #expect(
            try Self.argv(result) == [
                ["npx", "skills", "remove", "mig", "-g", "-y"],
                [
                    "gh", "skill", "install", "thedavidweng/skills", "maintenance/mig/SKILL.md",
                    "--force", "--dir", home.path + "/.agents/skills"
                ],
                [
                    "gh", "skill", "install", "thedavidweng/skills", "maintenance/mig/SKILL.md",
                    "--force", "--dir", home.path + "/.claude/skills"
                ]
            ])
        #expect(try TreeChecksum.manifest(root: home.path) == before)
    }

    @Test("The GitHub-ledger direction is one npx re-install, and a same-ledger target is refused")
    func gitHubToVercelAndRefusal() throws {
        let home = try TempTree()
        try home.file(
            ".claude/skills/g/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "g", repo: "https://github.com/thedavidweng/skills"))
        let bin = try Self.shims(in: home, transcript: home.path + "/transcript.log")
        let environment = CLIRunner.fixtureEnvironment(
            home: home.path, path: bin + ":/usr/bin:/bin")
        let result = try CLIRunner.run(
            ["skills", "migrate", "g", "--installer", "vercel", "--dry-run", "--json"],
            environment: environment)
        #expect(result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))")
        #expect(
            try Self.argv(result) == [
                ["npx", "skills", "add", "thedavidweng/skills", "--skill", "g", "-g", "-y"]
            ])
        let refused = try CLIRunner.run(
            ["skills", "migrate", "g", "--installer", "github", "--dry-run"],
            environment: environment)
        #expect(refused.exitCode == 1)
        #expect(BatchExecutionSupport.stderrText(refused).contains("is github-owned"))
    }

    @Test("Execution needs the danger acknowledgement, then snapshots and runs both commands")
    func executeVercelToGitHub() throws {
        let home = try TempTree()
        try Self.vercelSkill(in: home, name: "mig")
        let transcript = home.path + "/transcript.log"
        let bin = try Self.shims(in: home, transcript: transcript)
        let environment = CLIRunner.fixtureEnvironment(
            home: home.path, path: bin + ":/usr/bin:/bin")
        let refused = try CLIRunner.run(
            ["skills", "migrate", "mig", "--installer", "github", "--yes"], environment: environment
        )
        #expect(refused.exitCode == 1)
        #expect(BatchExecutionSupport.stderrText(refused).contains("--confirm-dangerous"))
        #expect(!FileManager.default.fileExists(atPath: transcript))

        let result = try CLIRunner.run(
            [
                "skills", "migrate", "mig", "--installer", "github", "--yes",
                "--confirm-dangerous", "--json"
            ], environment: environment)
        #expect(result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))")
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "succeeded")
        let snapshotID = try #require(record["snapshotID"] as? String)
        #expect(
            FileManager.default.fileExists(
                atPath: home.path + "/Library/Application Support/Sukiru/snapshots/" + snapshotID
                    + "/manifest.json"))
        let lines = try String(contentsOfFile: transcript, encoding: .utf8)
        #expect(
            lines == """
                npx skills remove mig -g -y
                gh skill install thedavidweng/skills maintenance/mig/SKILL.md --force --dir \
                \(home.path)/.agents/skills
                gh skill install thedavidweng/skills maintenance/mig/SKILL.md --force --dir \
                \(home.path)/.claude/skills

                """)
    }
}
