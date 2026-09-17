import Foundation
import Testing

@testable import SukiruCore

/// Seam-B e2e, continued: adopt provenance, ownerless cleanup, and the
/// VAL-CROSS-018 cross-scope isolation loop. Same suite struct as
/// `SeamBEndToEndTests.swift`, so the `.serialized` trait and the
/// SUKIRU_E2E gate cover these tests too.
extension SeamBEndToEndTests {
    // MARK: - VAL-REPAIR-045: adopt shows github provenance after rescan

    @Test(
        "VAL-REPAIR-045: adopt on FIX-ADOPT → github provenance on disk, finding gone",
        .enabled(if: SeamBE2ESupport.gitHubToken != nil, "GH_TOKEN required for gh skill install")
    )
    func adoptShowsGitHubProvenance() throws {
        let tree = try TempTree()
        let fixture = try Support.prepare("FIX-ADOPT", into: tree)
        let home = fixture.home
        let roots = fixture.roots
        let bin = fixture.bin
        let projectRoot = try #require(roots.only)
        let canary = Support.HomeCanary()

        let pre = try Batch.scanObject(home: home, roots: roots)
        let ownership = try Support.skillOwnership(
            pre, name: "stale-docs-cleanup", scope: "project")
        #expect(ownership == "ownerless")
        let findingID = try BatchCLITestSupport.findingID(
            pre, ruleID: "files-without-lock", skill: "stale-docs-cleanup")
        let choice: [String: Any] = ["repo": Support.upstreamRepo, "path": Support.upstreamPath]
        _ = try Support.executeBatch(
            home: home, roots: roots,
            decisions: [findingID: ["action": "adopt", "choice": choice]],
            tree: tree, bin: bin, token: Support.gitHubToken)

        let transcript = try Support.transcript(tree)
        #expect(transcript.contains("gh|"))
        #expect(transcript.contains("skill install thedavidweng/skills"))
        #expect(transcript.contains("--force"))
        #expect(!transcript.contains("npx|"), "adopt never routes through npx")

        let post = try Batch.scanObject(home: home, roots: roots)
        let adopted = try Support.skillOwnership(post, name: "stale-docs-cleanup", scope: "project")
        #expect(adopted == "github")
        let finding = try Support.findings(
            post, ruleID: "files-without-lock", skill: "stale-docs-cleanup")
        #expect(finding.isEmpty, "the originating finding is gone after adopt")
        // Note: `dangerous-removal-surface` legitimately PERSISTS — it
        // advises on every name the vercel ledger does not claim, and a
        // github-adopted skill is still inside `npx skills remove`'s blast
        // radius (HealthAnalyzer). VAL-REPAIR-045 only requires the
        // files-without-lock finding to clear.

        // Contract-verified frontmatter formats: repo URL without `.git`,
        // fully-qualified ref, repo-relative path, tree sha.
        let skillMD = try String(
            contentsOfFile: projectRoot + "/.agents/skills/stale-docs-cleanup/SKILL.md",
            encoding: .utf8)
        #expect(skillMD.contains("github-repo: https://github.com/thedavidweng/skills"))
        #expect(!skillMD.contains("github-repo: https://github.com/thedavidweng/skills.git"))
        #expect(skillMD.contains("github-path: maintenance/stale-docs-cleanup"))
        #expect(skillMD.contains("github-ref: refs/"))
        #expect(skillMD.contains("github-tree-sha: "))
        try canary.verifyUnchanged()
    }

    // MARK: - VAL-REPAIR-043: ownerless cleanup makes the finding disappear

    @Test("VAL-REPAIR-043: ownerless cleanup on FIX-FILES-NO-LOCK clears the finding on rescan")
    func ownerlessCleanupMakesFindingDisappear() throws {
        let tree = try TempTree()
        let copy = try Batch.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let canary = Support.HomeCanary()

        let pre = try Batch.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            pre, ruleID: "files-without-lock", skill: "orphan")
        _ = try Support.executeBatch(
            home: copy, roots: [], decisions: [findingID: ["action": "cleanup"]], tree: tree)

        let post = try Batch.scanObject(home: copy, roots: [])
        let finding = try Support.findings(post, ruleID: "files-without-lock", skill: "orphan")
        let advisory = try Support.findings(
            post, ruleID: "dangerous-removal-surface", skill: "orphan")
        #expect(finding.isEmpty)
        #expect(advisory.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy + "/.agents/skills/orphan"))
        try canary.verifyUnchanged()
    }

    // MARK: - VAL-CROSS-018: cross-scope action isolation

    @Test("VAL-CROSS-018: project-scope cleanup on FIX-SCOPES-CROSS leaves user scope untouched")
    func crossScopeActionIsolation() throws {
        let tree = try TempTree()
        let copy = try Batch.copyFixture("FIX-SCOPES-CROSS", into: tree)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let projectRoot = try #require(inputs.roots.only)
        let canary = Support.HomeCanary()
        let userStateBefore = try Support.userStateManifest(home: inputs.home)

        let pre = try Batch.scanObject(home: inputs.home, roots: inputs.roots)
        // The project-scope ownerless `shared-tool` finding; the user-scope
        // findings belong to `user-orphan`, so this match is unique.
        let findingID = try BatchCLITestSupport.findingID(
            pre, ruleID: "files-without-lock", skill: "shared-tool")
        #expect(findingID.hasPrefix("files-without-lock:project:"))
        let userFindingsBefore = try Support.findingIdentities(pre)
            .filter { $0.contains("|user|") }

        let record = try Support.executeBatch(
            home: inputs.home, roots: inputs.roots,
            decisions: [findingID: ["action": "cleanup"]], tree: tree)

        // No transcript command addresses the user scope: the batch is a
        // single direct file operation confined to the project root.
        let command = try #require(try Batch.commands(of: record).only)
        let argv = try #require(command["argv"] as? [String])
        #expect(Array(argv.prefix(2)) == ["sukiru-fileop", "delete-directory"])
        for argument in argv.dropFirst(2) {
            #expect(argument.hasPrefix(projectRoot), "command arg escapes the targeted scope")
            #expect(!argument.contains(inputs.home))
        }

        // The user scope is byte-identical: locks, placements, everything.
        let userStateAfter = try Support.userStateManifest(home: inputs.home)
        #expect(userStateAfter == userStateBefore, "any byte change in the user scope fails")
        try Support.assertManifestConfined(
            record: record, home: inputs.home, projectRoot: projectRoot)

        // Post-run scan: project findings for shared-tool are gone; the
        // user scope's findings and ownership are unchanged.
        let post = try Batch.scanObject(home: inputs.home, roots: inputs.roots)
        let finding = try Support.findings(post, ruleID: "files-without-lock", skill: "shared-tool")
        let advisory = try Support.findings(
            post, ruleID: "dangerous-removal-surface", skill: "shared-tool")
        #expect(finding.isEmpty)
        #expect(advisory.isEmpty)
        let userFindingsAfter = try Support.findingIdentities(post)
            .filter { $0.contains("|user|") }
        #expect(userFindingsAfter == userFindingsBefore)
        let userOwnership = try Support.skillOwnership(post, name: "shared-tool", scope: "user")
        #expect(userOwnership == "vercel", "user-scope ownership from its own ledger, untouched")
        let projectSkillGone = !FileManager.default.fileExists(
            atPath: projectRoot + "/.agents/skills/shared-tool")
        #expect(projectSkillGone)
        #expect(
            FileManager.default.fileExists(atPath: projectRoot + "/.agents/skills/proj-locked"),
            "the other project skill is not collateral damage")
        try canary.verifyUnchanged()
    }
}
