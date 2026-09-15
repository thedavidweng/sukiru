import Foundation
import Testing

@testable import SukiruCore

/// OwnershipResolver ownership states (architecture §6, D18): the four
/// verdicts and their provenance surfacing — unit-level over TempTree,
/// through ScanEngine.
@Suite("OwnershipResolver ownership states")
struct OwnershipResolverTests {
    @Test("Lock entry without gh provenance resolves vercel with global-scope provenance")
    func vercelOwnershipUserScope() throws {
        let home = try TempTree()
        try home.file(
            ".agents/skills/locked-tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("locked-tool"))
        try home.file(
            ".agents/.skill-lock.json",
            contents: OwnershipBuilders.globalLock(["locked-tool"]))

        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "locked-tool" })
        #expect(skill.ownership == .vercel)
        #expect(skill.ambiguous == false)

        let vercel = try #require(skill.provenance.vercel)
        #expect(vercel.source == "thedavidweng/skills")
        #expect(vercel.sourceType == "github")
        #expect(vercel.sourceUrl == "https://github.com/thedavidweng/skills.git")
        #expect(vercel.skillPath == ".agents/skills/locked-tool/SKILL.md")
        // Global scope exposes skillFolderHash and MUST NOT expose computedHash.
        #expect(vercel.skillFolderHash == String(repeating: "9", count: 40))
        #expect(vercel.computedHash == nil)
        #expect(vercel.installedAt == "2026-06-15T23:27:24.742Z")
        #expect(vercel.updatedAt == "2026-06-15T23:27:24.742Z")
        #expect(skill.provenance.github == nil)
        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
    }

    @Test("Project lock entry resolves vercel and exposes computedHash, never skillFolderHash")
    func vercelOwnershipProjectScope() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/proj-tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("proj-tool"))
        try project.file(
            "skills-lock.json", contents: OwnershipBuilders.projectLock("proj-tool"))

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let skill = try #require(report.skills.first { $0.name == "proj-tool" })
        #expect(skill.scope == .project)
        #expect(skill.ownership == .vercel)

        let vercel = try #require(skill.provenance.vercel)
        #expect(
            vercel.computedHash
                == "45c1c9bb9a52d7c1e4380406e2b9d2e9ce61a665ff292c3373b19e9463a43a19")
        #expect(vercel.skillFolderHash == nil, "project entries never expose skillFolderHash")
        #expect(vercel.ref == "refs/heads/main")
        #expect(vercel.installedAt == nil)
    }

    @Test("Frontmatter github-repo without a lock entry resolves github, pin state tri-state")
    func githubOwnership() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        let repo = "https://github.com/thedavidweng/skills.git"
        try home.file(
            ".claude/skills/pinned-tool/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("pinned-tool", repo: repo, pinned: true))
        try home.file(
            ".claude/skills/plain-tool/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "plain-tool", repo: "https://github.com/thedavidweng/skills"))

        let report = try OwnershipBuilders.scan(home: home)
        let pinned = try #require(report.skills.first { $0.name == "pinned-tool" })
        #expect(pinned.ownership == .github)
        let pinnedGitHub = try #require(pinned.provenance.github)
        #expect(pinnedGitHub.repo == repo, "repo preserved as stored, .git suffix intact")
        #expect(pinnedGitHub.path == "tools/pinned-tool/SKILL.md")
        #expect(pinnedGitHub.ref == "refs/heads/main", "full ref, never truncated")
        #expect(pinnedGitHub.treeSha == String(repeating: "a", count: 40))
        #expect(pinnedGitHub.pinned == true)

        let plain = try #require(report.skills.first { $0.name == "plain-tool" })
        #expect(plain.ownership == .github)
        let plainGitHub = try #require(plain.provenance.github)
        #expect(plainGitHub.pinned == false, "absent github-pinned key means unpinned")
        #expect(plain.provenance.vercel == nil)
        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
    }

    @Test("Lock entry AND github-repo resolve double-booked with two-sided evidence")
    func doubleBooked() throws {
        let home = try TempTree()
        let skillFile = try home.file(
            ".agents/skills/double-tool/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "double-tool", repo: "https://github.com/thedavidweng/skills"))
        let lockPath = try home.file(
            ".agents/.skill-lock.json",
            contents: OwnershipBuilders.globalLock(["double-tool"]))

        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "double-tool" })
        #expect(skill.ownership == .doubleBooked)
        #expect(skill.provenance.vercel != nil)
        #expect(skill.provenance.github != nil)

        let finding = try #require(report.findings.first { $0.ruleID == "double-booked" })
        #expect(finding.severity == .action)
        #expect(finding.skillName == "double-tool")
        #expect(finding.evidence.contains { $0.kind == "lockPath" && $0.detail == lockPath })
        #expect(finding.evidence.contains { $0.kind == "entryKey" && $0.detail == "double-tool" })
        #expect(finding.evidence.contains { $0.kind == "skillMdPath" && $0.detail == skillFile })
        let repoEvidence = finding.evidence.contains {
            $0.kind == "githubRepo" && $0.detail == "https://github.com/thedavidweng/skills"
        }
        #expect(repoEvidence)
    }

    @Test("No ledger claim resolves ownerless with a files-without-lock listing")
    func ownerless() throws {
        let home = try TempTree()
        let skillFile = try home.file(
            ".agents/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))

        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "orphan" })
        #expect(skill.ownership == .ownerless)
        #expect(skill.provenance.vercel == nil)
        #expect(skill.provenance.github == nil)

        let finding = try #require(report.findings.first { $0.ruleID == "files-without-lock" })
        #expect(finding.severity == .info)
        #expect(finding.skillName == "orphan")
        #expect(finding.workspaceID == "user")
        let placementPath = URL(fileURLWithPath: skillFile).deletingLastPathComponent().path
        #expect(
            finding.evidence.contains { $0.kind == "placementPath" && $0.detail == placementPath })
    }
}
