import Foundation
import Testing

@testable import SukiruCore

/// Ownership and lifecycle gating for gh's companion records in the Vercel
/// global lock (`VercelLockEntry.isGitHubCompanion`,
/// `CommandBatchBuilder.githubWriteBlocker`).
@Suite("Library lifecycle with gh companion records")
struct LibraryLifecycleCompanionTests {
    private static func skill(_ name: String, in report: ScanReport) throws -> Skill {
        try #require(report.skills.first { $0.name == name })
    }

    // MARK: - gh companion records

    @Test("A gh companion record is not a Vercel claim and withholds nothing")
    func companionRecordIsNotAClaim() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.ghCompanionLock(["u"]))
        try home.file(
            ".claude/skills/u/SKILL.md", contents: OwnershipBuilders.ghSkillMD("u", repo: "o/r"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try Self.skill("u", in: report)
        #expect(skill.ownership == .github, "gh's own record does not double-book the skill")
        #expect(skill.provenance.vercel?.githubCompanion == true)
        #expect(!report.findings.contains { $0.ruleID == "double-booked" })
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .update, capabilities: nil, report: report) == nil)
        #expect(
            CommandBatchBuilder.githubWriteBlocker(skillName: "u", report: report) == nil)
    }

    @Test("A genuine user-scope Vercel record still withholds the gh write")
    func genuineRecordWithholds() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json",
            contents: OwnershipBuilders.ghCompanionLock(["u"], pinned: true))
        try home.file(".agents/skills/u/SKILL.md", contents: OwnershipBuilders.skillMD("u"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try Self.skill("u", in: report)
        #expect(
            skill.ownership == .vercel,
            "without gh provenance the entry is a Vercel claim even when gh-shaped")
        #expect(
            CommandBatchBuilder.githubWriteBlocker(skillName: "u", report: report)
                == .touchesVercelRecord)
    }

    @Test("A gh write that would drop data npx needs is withheld")
    func lossyRewriteWithholds() throws {
        let lockWithRef = """
            {
              "version": 3,
              "skills": {
                "v": {
                  "source": "thedavidweng/skills",
                  "sourceType": "github",
                  "sourceUrl": "https://github.com/thedavidweng/skills.git",
                  "ref": "refs/heads/next",
                  "skillPath": ".agents/skills/v/SKILL.md",
                  "skillFolderHash": "9999999999999999999999999999999999999999",
                  "installedAt": "2026-06-15T23:27:24.742Z",
                  "updatedAt": "2026-06-15T23:27:24.742Z"
                }
              },
              "dismissed": {}
            }
            """
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: lockWithRef)
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        let report = try OwnershipBuilders.scan(home: home)
        #expect(
            CommandBatchBuilder.githubWriteBlocker(skillName: "other", report: report)
                == .dropsVercelLockData,
            "gh's rewrite drops the ref of every record, not just the skill's own")
    }

    @Test("Unknown top-level lock keys withhold a gh write")
    func unknownTopLevelKeysWithhold() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json",
            contents: OwnershipBuilders.globalLock(["a"]).replacingOccurrences(
                of: "\"dismissed\": {}", with: "\"futureKey\": true"))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        let report = try OwnershipBuilders.scan(home: home)
        #expect(report.lockExtras?["user"]?["futureKey"] != nil)
        #expect(
            CommandBatchBuilder.githubWriteBlocker(skillName: "other", report: report)
                == .dropsVercelLockData)
    }

}
