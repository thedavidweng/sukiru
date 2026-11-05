import Foundation
import Testing

@testable import SukiruCore

/// Installer migration: moving a skill from the Vercel ledger to the GitHub
/// ledger (a danger-flagged `npx skills remove` first, then one
/// `gh skill install` per skills folder) and back (one `npx skills add`
/// that overwrites the gh frontmatter provenance), plus the ownership,
/// capability, pin, and provenance rules that withhold it.
@Suite("Library migration")
struct LibraryLifecycleMigrationTests {
    private typealias Support = BatchTestSupport

    /// A global v3 lock entry in the shape `skills` writes: `source` is
    /// `owner/repo` and `skillPath` is the skill's REPO-RELATIVE `SKILL.md`
    /// path (verified against skills@1.7.6 in docs/collision-matrix.md).
    private static func vercelLock(_ name: String, skillPath: String?) -> String {
        let path = skillPath.map { "\n      \"skillPath\": \"\($0)\"," } ?? ""
        return """
            {
              "version": 3,
              "skills": {
                "\(name)": {
                  "source": "thedavidweng/skills",
                  "sourceType": "github",
                  "sourceUrl": "https://github.com/thedavidweng/skills.git",\(path)
                  "skillFolderHash": "8696469960d3f9233ee158b78a006798edb2cc49",
                  "installedAt": "2026-06-15T23:27:24.742Z",
                  "updatedAt": "2026-06-15T23:27:24.742Z"
                }
              },
              "dismissed": {}
            }
            """
    }

    private static func capabilities(npx: Bool, github: Bool) -> CapabilityReport {
        CapabilityReport(
            schemaVersion: CapabilityReport.currentSchemaVersion,
            github: .init(
                available: github, present: github, version: github ? "2.90.0" : nil,
                meetsMinimum: github, reason: github ? nil : .absent),
            npx: .init(
                resolvable: npx, skillsVersion: npx ? "1.7.4" : nil,
                reason: npx ? nil : .absent))
    }

    private static func built(
        _ report: ScanReport, name: String, action: LifecycleAction = .migrate
    ) throws -> (batch: CommandBatch?, skipped: [String]) {
        let skill = try #require(report.skills.first { $0.name == name })
        return Support.makeBuilder().buildApplicable(
            report: report, decisions: [],
            lifecycle: [LifecycleRequest(skill: skill, action: action)])
    }

    // MARK: - Vercel ledger → GitHub ledger

    @Test("A Vercel skill is removed first, then re-installed into every folder it held")
    func vercelToGitHubUserScope() throws {
        let home = try TempTree()
        let name = "mig"
        try home.file(
            ".agents/.skill-lock.json",
            contents: Self.vercelLock(name, skillPath: "maintenance/mig/SKILL.md"))
        try home.file(".agents/skills/mig/SKILL.md", contents: OwnershipBuilders.skillMD(name))
        try home.symlink(".claude/skills/mig", to: home.path + "/.agents/skills/mig")
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == name })
        #expect(skill.ownership == .vercel)

        let planned = try Self.built(report, name: name)
        #expect(planned.skipped.isEmpty)
        let batch = try #require(planned.batch)
        // The removal must come first: npx deletes by name across ownership
        // (collision-matrix scenario 6), so a gh install before it would be
        // deleted. The snapshot covers the transient window.
        #expect(
            batch.commands.map(\.argv) == [
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
        #expect(batch.commands.first?.dangerFlags == [.dangerousDeletion])
        #expect(batch.commands.first?.atRiskSkills.isEmpty == true)
        let installs = batch.commands.dropFirst()
        #expect(installs.allSatisfy { $0.consequenceKind == .migratesToGitHub })
        #expect(installs.allSatisfy { $0.owningCLI == .github })
        #expect(batch.findingRefs.map(\.ruleID) == ["library-migrate"])
        #expect(batch.findingRefs.only?.workspaceID == "user")
    }

    @Test("A project-scope Vercel skill migrates from the project root")
    func vercelToGitHubProjectScope() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            "skills-lock.json", contents: OwnershipBuilders.projectLock("p"))
        try project.file(".agents/skills/p/SKILL.md", contents: OwnershipBuilders.skillMD("p"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let planned = try Self.built(report, name: "p")
        let batch = try #require(planned.batch)
        let remove = try #require(batch.commands.first)
        #expect(remove.argv == ["npx", "skills", "remove", "p", "-y"])
        #expect(remove.workingDirectory == project.path)
        #expect(
            batch.commands.dropFirst().map(\.argv) == [
                [
                    "gh", "skill", "install", "thedavidweng/skills",
                    ".agents/skills/p/SKILL.md", "--force", "--dir",
                    project.path + "/.agents/skills"
                ]
            ])
        #expect(batch.findingRefs.only?.workspaceID == "project:" + project.path)
    }

    @Test("A lock entry without a recorded skill path withholds the move")
    func vercelMissingSkillPath() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: Self.vercelLock("m", skillPath: nil))
        try home.file(".agents/skills/m/SKILL.md", contents: OwnershipBuilders.skillMD("m"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "m" })
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .migrate,
                capabilities: Self.capabilities(npx: true, github: true),
                report: report) == .incompleteProvenance)
        let planned = try Self.built(report, name: "m")
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("does not name the repository") == true)
    }

    @Test("A move to the GitHub ledger needs gh")
    func vercelMissingGitHubCLI() throws {
        let home = try TempTree()
        try home.file(
            ".agents/.skill-lock.json",
            contents: Self.vercelLock("m", skillPath: "tools/m/SKILL.md"))
        try home.file(".agents/skills/m/SKILL.md", contents: OwnershipBuilders.skillMD("m"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "m" })
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .migrate,
                capabilities: Self.capabilities(npx: true, github: false),
                report: report) == .needsGitHubCLI)
    }

    @Test("A move is withheld when gh would rewrite another Vercel record of the same name")
    func vercelToGitHubTouchingVercelRecord() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json",
            contents: Self.vercelLock("v", skillPath: "tools/v/SKILL.md"))
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        // A project-scope Vercel record of the same name is not the record
        // the batch removes, so the gh write would overwrite its fields.
        try project.file("skills-lock.json", contents: OwnershipBuilders.projectLock("v"))
        try project.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let userSkill = try #require(report.skills.first { $0.name == "v" && $0.scope == .user })
        let projectSkill = try #require(
            report.skills.first { $0.name == "v" && $0.scope == .project })
        // The user-scope move removes that record itself, so it stays allowed.
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: userSkill, action: .migrate,
                capabilities: Self.capabilities(npx: true, github: true), report: report) == nil)
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: projectSkill, action: .migrate,
                capabilities: Self.capabilities(npx: true, github: true), report: report)
                == .touchesVercelRecord)
    }

    // MARK: - GitHub ledger → Vercel ledger

    @Test("A GitHub skill moves to npx with one untargeted global re-install")
    func gitHubToVercelUserScope() throws {
        let home = try TempTree()
        try home.file(
            ".claude/skills/g/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "g", repo: "https://github.com/thedavidweng/skills"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "g" })
        #expect(skill.ownership == .github)
        let planned = try Self.built(report, name: "g")
        #expect(planned.skipped.isEmpty)
        let batch = try #require(planned.batch)
        // No removal: rewriting the files erases the gh frontmatter record,
        // which is the same overwrite the keep-Vercel arbitration relies on.
        let command = try #require(batch.commands.only)
        #expect(
            command.argv == [
                "npx", "skills", "add", "thedavidweng/skills", "--skill", "g", "-g", "-y"
            ])
        #expect(command.consequenceKind == .resetsToUpstreamErasingGitHubProvenance)
        #expect(command.owningCLI == .vercel)
        #expect(batch.findingRefs.only?.ruleID == "library-migrate")
    }

    @Test("A project-scope GitHub skill names every host folder and copy mode")
    func gitHubToVercelProjectScope() throws {
        let home = try TempTree()
        let project = try TempTree()
        let skill = OwnershipBuilders.ghSkillMD(
            "g", repo: "https://github.com/thedavidweng/skills")
        try project.file(".agents/skills/g/SKILL.md", contents: skill)
        try project.file(".claude/skills/g/SKILL.md", contents: skill)
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let planned = try Self.built(report, name: "g")
        let batch = try #require(planned.batch)
        let command = try #require(batch.commands.only)
        #expect(
            command.argv == [
                "npx", "skills", "add", "thedavidweng/skills", "--skill", "g",
                "-a", "claude-code", "-a", "codex", "--copy", "-y"
            ])
        #expect(command.workingDirectory == project.path)
    }

    @Test("A move to the Vercel ledger needs npx")
    func gitHubMissingNpx() throws {
        let home = try TempTree()
        try home.file(
            ".claude/skills/g/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "g", repo: "https://github.com/thedavidweng/skills"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "g" })
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .migrate,
                capabilities: Self.capabilities(npx: false, github: true), report: report)
                == .needsNpx)
    }

    @Test("A pinned skill is refused: the Vercel ledger cannot carry the pin")
    func pinnedSkillRefused() throws {
        let home = try TempTree()
        try home.file(
            ".claude/skills/g/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "g", repo: "https://github.com/thedavidweng/skills", pinnedRef: "v1.2.3"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "g" })
        #expect(skill.provenance.github?.pinned == true)
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .migrate,
                capabilities: Self.capabilities(npx: true, github: true), report: report)
                == .migratingPinnedSkill)
        let planned = try Self.built(report, name: "g")
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("unpin it") == true)
    }

    // MARK: - Ownership rules

    @Test("Ownerless and double-booked skills are not migration candidates")
    func ownershipRefusals() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["b"]))
        try home.file(".agents/skills/b/SKILL.md", contents: OwnershipBuilders.skillMD("b"))
        try home.file(
            ".claude/skills/b/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD(
                "b", repo: "https://github.com/thedavidweng/skills"))
        try home.file(".claude/skills/stray/SKILL.md", contents: OwnershipBuilders.skillMD("stray"))
        let report = try OwnershipBuilders.scan(home: home)
        let blocked = { (name: String) throws -> LifecycleBlocker? in
            let skill = try #require(report.skills.first { $0.name == name })
            return CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .migrate,
                capabilities: Self.capabilities(npx: true, github: true), report: report)
        }
        #expect(try blocked("b") == .doubleBooked)
        #expect(try blocked("stray") == .ownerless)
    }
}
