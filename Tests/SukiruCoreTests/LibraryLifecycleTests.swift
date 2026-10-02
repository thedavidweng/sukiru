import Foundation
import Testing

@testable import SukiruCore

/// Library update and uninstall: grouped update commands, ledger-routed
/// removal, and the ownership and capability rules that withhold them.
@Suite("Library lifecycle")
struct LibraryLifecycleTests {
    private typealias Support = BatchTestSupport

    private static func skill(_ name: String, in report: ScanReport) throws -> Skill {
        try #require(report.skills.first { $0.name == name })
    }

    private static func plan(
        _ report: ScanReport, _ requests: [(String, LifecycleAction)]
    ) throws -> (batch: CommandBatch?, skipped: [String]) {
        let lifecycle = try requests.map { name, action in
            LifecycleRequest(skill: try skill(name, in: report), action: action)
        }
        return Support.makeBuilder().buildApplicable(
            report: report, decisions: [], lifecycle: lifecycle)
    }

    private static func capabilities(npx: Bool, github: Bool) -> CapabilityReport {
        CapabilityReport(
            schemaVersion: CapabilityReport.currentSchemaVersion,
            github: .init(
                available: github, present: github, version: github ? "2.90.0" : nil,
                meetsMinimum: github, reason: github ? nil : .absent),
            npx: .init(
                resolvable: npx, skillsVersion: npx ? "1.7.0" : nil,
                reason: npx ? nil : .absent))
    }

    // MARK: - update

    @Test("Vercel updates in one scope share one npx skills update")
    func vercelUpdatesGroupPerScope() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a", "b"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.file(".agents/skills/b/SKILL.md", contents: OwnershipBuilders.skillMD("b"))
        let report = try OwnershipBuilders.scan(home: home)
        let batch = try #require(try Self.plan(report, [("b", .update), ("a", .update)]).batch)
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "update", "a", "b", "-g", "-y"])
        #expect(command.workingDirectory == nil)
        #expect(batch.findingRefs.map(\.ruleID) == ["library-update", "library-update"])
        #expect(batch.findingRefs.allSatisfy { $0.workspaceID == "user" })
        #expect(batch.decisions.isEmpty)
    }

    @Test("A project-scope Vercel update runs with -p from the project root")
    func vercelProjectUpdate() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(".agents/skills/p/SKILL.md", contents: OwnershipBuilders.skillMD("p"))
        try project.file("skills-lock.json", contents: OwnershipBuilders.projectLock("p"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let batch = try #require(try Self.plan(report, [("p", .update)]).batch)
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "update", "p", "-p", "-y"])
        #expect(command.workingDirectory == project.path)
        #expect(batch.findingRefs.only?.workspaceID == "project:" + project.path)
    }

    @Test("GitHub updates share one named gh skill update --all per skills folder")
    func githubUpdatesGroupPerDir() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".claude/skills/g1/SKILL.md", contents: OwnershipBuilders.ghSkillMD("g1", repo: "o/r"))
        try project.file(
            ".claude/skills/g2/SKILL.md", contents: OwnershipBuilders.ghSkillMD("g2", repo: "o/r"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        #expect(try Self.skill("g1", in: report).ownership == .github)
        let batch = try #require(try Self.plan(report, [("g1", .update), ("g2", .update)]).batch)
        let dir = project.path + "/.claude/skills"
        #expect(
            batch.commands.map(\.argv) == [
                ["gh", "skill", "update", "g1", "g2", "--all", "--dir", dir]
            ])
    }

    @Test("A gh update is withheld only when a genuine user-scope Vercel record shares the name")
    func githubUpdateTouchingVercelRecord() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["v"]))
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        try home.file(
            ".claude/skills/u/SKILL.md", contents: OwnershipBuilders.ghSkillMD("u", repo: "o/r"))
        try project.file(
            ".claude/skills/v/SKILL.md", contents: OwnershipBuilders.ghSkillMD("v", repo: "o/r"))
        try project.file(
            ".claude/skills/p/SKILL.md", contents: OwnershipBuilders.ghSkillMD("p", repo: "o/r"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let blocker = { (name: String, scope: Scope) throws -> LifecycleBlocker? in
            let skill = try #require(report.skills.first { $0.name == name && $0.scope == scope })
            return CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .update, capabilities: nil, report: report)
        }
        // "u" has no Vercel record of its own: gh would only (re)write its
        // companion record, so the update is allowed.
        #expect(try blocker("u", .user) == nil)
        #expect(try blocker("v", .project) == .touchesVercelRecord)
        #expect(try blocker("p", .project) == nil)
        let projectV = try #require(
            report.skills.first { $0.name == "v" && $0.scope == .project })
        let planned = Support.makeBuilder().buildApplicable(
            report: report, decisions: [],
            lifecycle: [LifecycleRequest(skill: projectV, action: .update)])
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("Vercel ledger's global lock") == true)
        let uninstall = CommandBatchBuilder.lifecycleBlocker(
            skill: projectV, action: .uninstall, capabilities: nil, report: report)
        #expect(uninstall == nil, "a direct deletion writes no lock")
    }

    // MARK: - uninstall

    @Test("A Vercel uninstall is a flagged npx skills remove naming no at-risk skills")
    func vercelUninstall() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        let report = try OwnershipBuilders.scan(home: home)
        let batch = try #require(try Self.plan(report, [("a", .uninstall)]).batch)
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "remove", "a", "-g", "-y"])
        #expect(command.dangerFlags == [.dangerousDeletion])
        #expect(command.atRiskSkills.isEmpty)
        #expect(command.warning?.hasPrefix("Dangerous deletion") == true)
        #expect(batch.findingRefs.only?.ruleID == "library-uninstall")
    }

    @Test("A GitHub uninstall deletes links as links and the folder directly")
    func githubUninstallDeletesLinksAsLinks() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".cursor/settings.json", contents: "{}")
        let folder = try home.file(
            ".claude/skills/g/SKILL.md", contents: OwnershipBuilders.ghSkillMD("g", repo: "o/r"))
        let store = URL(fileURLWithPath: folder).deletingLastPathComponent().path
        let link = try home.symlink(".cursor/skills/g", to: store)
        let report = try OwnershipBuilders.scan(home: home)
        let batch = try #require(try Self.plan(report, [("g", .uninstall)]).batch)
        #expect(
            batch.commands.map(\.argv) == [
                ["sukiru-fileop", "delete-link", link],
                ["sukiru-fileop", "delete-directory", store]
            ])
        #expect(batch.commands.allSatisfy { $0.owningCLI == .file })
        #expect(batch.commands.allSatisfy { $0.dangerFlags.contains(.directFileOperation) })
        #expect(!batch.commands.contains { $0.dangerFlags.contains(.ownerlessCleanup) })

        let removeLink = try #require(batch.commands.first?.fileOperation)
        try removeLink.perform()
        #expect(!FileManager.default.fileExists(atPath: link))
        #expect(FileManager.default.fileExists(atPath: folder), "the link is never followed")
        try #require(batch.commands.last?.fileOperation).perform()
        #expect(!FileManager.default.fileExists(atPath: store))
    }

    // MARK: - eligibility

    @Test("Only single-ledger, non-ambiguous skills can be updated or uninstalled")
    func ownershipBlockers() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["both"]))
        try home.file(
            ".agents/skills/both/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("both", repo: "o/r"))
        try home.file(".claude/skills/stray/SKILL.md", contents: OwnershipBuilders.skillMD("stray"))
        try home.file(".hermes/skills/.bundled_manifest", contents: "")
        try home.file(".hermes/skills/notes/SKILL.md", contents: OwnershipBuilders.skillMD("notes"))
        let report = try OwnershipBuilders.scan(home: home)
        let expected: [String: LifecycleBlocker] = [
            "both": .doubleBooked, "stray": .ownerless, "notes": .agentManaged
        ]
        for (name, blocker) in expected {
            let skill = try Self.skill(name, in: report)
            for action in LifecycleAction.allCases {
                #expect(
                    CommandBatchBuilder.lifecycleBlocker(
                        skill: skill, action: action, capabilities: nil) == blocker)
            }
        }
        let planned = try Self.plan(report, [("both", .update), ("stray", .uninstall)])
        #expect(planned.batch == nil)
        #expect(planned.skipped.count == 2)
        #expect(planned.skipped.contains { $0.contains("choose a surviving ledger in Health") })
    }

    @Test("Ambiguous ownership blocks every Library action")
    func ambiguousBlocks() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".codex/config.toml", contents: "")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["x"]))
        try home.file(".claude/skills/x/SKILL.md", contents: OwnershipBuilders.skillMD("x"))
        try home.file(
            ".codex/skills/x/SKILL.md",
            contents: OwnershipBuilders.skillMD("x", variant: "Different."))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try Self.skill("x", in: report)
        try #require(skill.ambiguous)
        #expect(
            CommandBatchBuilder.lifecycleBlocker(skill: skill, action: .update, capabilities: nil)
                == .ambiguous)
    }

    @Test("A missing CLI blocks its ledger's actions; a GitHub uninstall needs no gh")
    func capabilityBlockers() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["v"]))
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        try home.file(
            ".claude/skills/g/SKILL.md", contents: OwnershipBuilders.ghSkillMD("g", repo: "o/r"))
        let report = try OwnershipBuilders.scan(home: home)
        let vercel = try Self.skill("v", in: report)
        let github = try Self.skill("g", in: report)
        let none = Self.capabilities(npx: false, github: false)
        let all = Self.capabilities(npx: true, github: true)
        let blocker = { (skill: Skill, action: LifecycleAction, caps: CapabilityReport) in
            CommandBatchBuilder.lifecycleBlocker(skill: skill, action: action, capabilities: caps)
        }
        #expect(blocker(vercel, .update, none) == .needsNpx)
        #expect(blocker(vercel, .uninstall, none) == .needsNpx)
        #expect(blocker(github, .update, none) == .needsGitHubCLI)
        #expect(blocker(github, .uninstall, none) == nil)
        // Pin, unpin, and restore are GitHub-ledger writes: they need gh,
        // and the Vercel ledger has no concept of them.
        for action: LifecycleAction in [.pin, .unpin, .restore] {
            #expect(blocker(vercel, action, all) == .githubLedgerOnly)
            #expect(blocker(github, action, none) == .needsGitHubCLI)
        }
        #expect(blocker(vercel, .update, all) == nil)
        #expect(blocker(vercel, .uninstall, all) == nil)
        #expect(blocker(github, .update, all) == nil)
        #expect(blocker(github, .uninstall, all) == nil)
        #expect(blocker(github, .pin, all) == nil, "the skill is unpinned")
        #expect(blocker(github, .restore, all) == nil)
        #expect(blocker(github, .unpin, all) == .notPinned, "the skill is unpinned")
    }

    @Test("A request for a skill the current scan no longer holds is skipped")
    func staleRequestSkipped() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        let before = try OwnershipBuilders.scan(home: home)
        let stale = LifecycleRequest(skill: try Self.skill("a", in: before), action: .update)
        try FileManager.default.removeItem(atPath: home.path + "/.agents/skills/a")
        let after = try OwnershipBuilders.scan(home: home)
        let planned = Support.makeBuilder().buildApplicable(
            report: after, decisions: [], lifecycle: [stale])
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("not in the current scan") == true)
    }
}
