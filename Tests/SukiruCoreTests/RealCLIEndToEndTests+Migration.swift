import Foundation
import Testing

@testable import SukiruCore

/// Installer migration against the REAL CLIs: a Vercel-owned user-scope
/// skill moves to the GitHub ledger, then back, and each end state has one
/// owner and no double booking. Serialized by the suite's trait (same
/// struct).
extension RealCLIEndToEndTests {
    /// A global v3 lock in the shape `skills` writes: `source` is
    /// `owner/repo` and `skillPath` is the skill's repo-relative
    /// `SKILL.md` path (verified against skills@1.7.6).
    private static var migrationLock: String {
        """
        {
          "version": 3,
          "skills": {
            "stale-docs-cleanup": {
              "source": "\(RealCLIE2ESupport.upstreamRepo)",
              "sourceType": "github",
              "sourceUrl": "https://github.com/\(RealCLIE2ESupport.upstreamRepo).git",
              "skillPath": "\(RealCLIE2ESupport.upstreamPath)",
              "skillFolderHash": "8696469960d3f9233ee158b78a006798edb2cc49",
              "installedAt": "2026-06-15T23:27:24.742Z",
              "updatedAt": "2026-06-15T23:27:24.742Z"
            }
          },
          "dismissed": {}
        }
        """
    }

    @Test("Real migration moves Vercel → GitHub → Vercel with one owner each time")
    func migrationRoundTrip() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let canary = Support.HomeCanary()
        // Vercel-owned in link mode: the shared copy plus a host link.
        try tree.file("home/.agents/.skill-lock.json", contents: Self.migrationLock)
        try tree.file(
            "home/.agents/skills/stale-docs-cleanup/SKILL.md",
            contents: OwnershipBuilders.skillMD("stale-docs-cleanup"))
        try tree.symlink(
            "home/.claude/skills/stale-docs-cleanup",
            to: home + "/.agents/skills/stale-docs-cleanup")
        let pre = try BatchExecutionSupport.scanObject(home: home, roots: [])
        #expect(try Self.owner(of: pre) == "vercel")

        let tools = try Support.resolveTools()
        let bin = try Support.installToolWrappers(tools, into: tree)
        let token = try #require(
            Support.gitHubToken, "SUKIRU_E2E=1 needs GH_TOKEN for the gh scenarios")
        let environment = CLIRunner.fixtureEnvironment(
            home: home, path: bin + ":/usr/bin:/bin", extra: ["GH_TOKEN": token])

        // MARK: Vercel → GitHub

        try Self.migrate(to: "github", environment: environment)
        let transcript = try Support.transcript(tree)
        #expect(transcript.contains("remove stale-docs-cleanup -g -y"), "the removal ran first")
        #expect(transcript.contains("gh|"), "the re-install ran through gh")
        let afterGitHub = try BatchExecutionSupport.scanObject(home: home, roots: [])
        #expect(try Self.owner(of: afterGitHub) == "github", "the GitHub ledger owns it alone")
        // gh writes a real copy into every skills folder the skill held,
        // rather than links to the shared copy: identical copies are the
        // documented (relink-repairable) consequence, not a lost host.
        let ghDuplicates = try Support.findings(
            afterGitHub, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        #expect(Self.subtypes(ghDuplicates) == ["exact"], "two folders, identical copies")
        #expect(
            try Support.findings(
                afterGitHub, ruleID: "broken-symlink", skill: "stale-docs-cleanup"
            ).isEmpty, "no host is left with a dead link")

        // MARK: GitHub → Vercel

        try Self.migrate(to: "vercel", environment: environment)
        let afterVercel = try BatchExecutionSupport.scanObject(home: home, roots: [])
        #expect(try Self.owner(of: afterVercel) == "vercel", "the Vercel ledger owns it alone")
        // The npx re-install restored the linked layout: the only duplicate
        // is the alias note the pre-state carried (several links into one
        // shared copy), never an exact copy.
        let duplicates = try Support.findings(
            afterVercel, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        #expect(Self.subtypes(duplicates) == ["alias"], "links, not copies")
        try canary.verifyUnchanged()
    }

    /// Runs one migration through the built CLI and asserts the batch ran.
    private static func migrate(to installer: String, environment: [String: String]) throws {
        let result = try CLIRunner.run(
            [
                "skills", "migrate", "stale-docs-cleanup", "--installer", installer, "--yes",
                "--confirm-dangerous", "--json"
            ], environment: environment, timeout: Support.batchTimeout)
        #expect(result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))")
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "succeeded")
    }

    private static func owner(of scan: [String: Any]) throws -> String? {
        try Support.skillOwnership(scan, name: "stale-docs-cleanup", scope: "user")
    }

    private static func subtypes(_ findings: [[String: Any]]) -> [String] {
        findings.compactMap { finding in
            (finding["evidence"] as? [[String: String]])?.first { $0["kind"] == "subtype" }?[
                "detail"]
        }.sorted()
    }
}
