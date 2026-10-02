import Foundation
import Testing

@testable import SukiruCore

/// Library pin, unpin, and restore for GitHub-ledger skills: the
/// probe-verified gh command shapes (docs/collision-matrix.md, 2026-10-02
/// pin/unpin run), the pin-state preconditions, the pin ref validation, and
/// the same Vercel-lock write guards updates carry.
@Suite("Library pin, unpin, restore")
struct LibraryLifecyclePinTests {
    private typealias Support = BatchTestSupport

    private static func skill(_ name: String, in report: ScanReport) throws -> Skill {
        try #require(report.skills.first { $0.name == name })
    }

    private static func plan(
        _ report: ScanReport, _ requests: [LifecycleRequest]
    ) throws -> (batch: CommandBatch?, skipped: [String]) {
        Support.makeBuilder().buildApplicable(report: report, decisions: [], lifecycle: requests)
    }

    /// A user-scope gh-owned skill on disk; the scan plus the skills dir of
    /// its one placement.
    private static func ghScan(
        _ skillMD: String, name: String = "g"
    ) throws -> (report: ScanReport, dir: String) {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".claude/skills/\(name)/SKILL.md", contents: skillMD)
        let report = try OwnershipBuilders.scan(home: home)
        try #require(report.skills.first { $0.name == name }?.ownership == .github)
        return (report, home.path + "/.claude/skills")
    }

    // MARK: - pin ref validation

    @Test("Pin refs reject emptiness, whitespace, and control characters")
    func pinRefValidation() {
        #expect(LifecycleRequest.isValidPinRef("v1.2.3"))
        #expect(LifecycleRequest.isValidPinRef("main"))
        #expect(LifecycleRequest.isValidPinRef("1ed29a03dc852d30fa6ef2ca53a67dc2c2c2c563"))
        #expect(LifecycleRequest.isValidPinRef("feature/x.y_1-2"))
        #expect(!LifecycleRequest.isValidPinRef(""))
        #expect(!LifecycleRequest.isValidPinRef("  "))
        #expect(!LifecycleRequest.isValidPinRef("a b"))
        #expect(!LifecycleRequest.isValidPinRef("main\n"))
        #expect(!LifecycleRequest.isValidPinRef("v1\0"))
    }

    // MARK: - pin

    @Test("Pin runs gh skill install --pin --force per placement dir")
    func pinCommandShape() throws {
        let (report, dir) = try Self.ghScan(OwnershipBuilders.ghSkillMD("g", repo: "o/r"))
        let request = LifecycleRequest(
            skill: try Self.skill("g", in: report), action: .pin, pinRef: "v1.2.3")
        #expect(request.id.contains("v1.2.3"), "the ref disambiguates the finding ref")
        let planned = try Self.plan(report, [request])
        let batch = try #require(planned.batch)
        let command = try #require(batch.commands.only)
        #expect(
            command.argv == [
                "gh", "skill", "install", "o/r", "tools/g/SKILL.md", "--pin", "v1.2.3",
                "--force", "--dir", dir
            ])
        #expect(command.consequence == CommandConsequence.pinsGitHubSkill(ref: "v1.2.3").text)
        #expect(batch.findingRefs.only?.ruleID == "library-pin")
    }

    @Test("An invalid pin ref is refused at plan time")
    func pinRefusedOnInvalidRef() throws {
        let (report, _) = try Self.ghScan(OwnershipBuilders.ghSkillMD("g", repo: "o/r"))
        let skill = try Self.skill("g", in: report)
        let planned = try Self.plan(
            report, [LifecycleRequest(skill: skill, action: .pin, pinRef: "  ")])
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("pin ref") == true)
    }

    @Test("Pin is withheld on a pinned skill and on non-GitHub skills")
    func pinEligibility() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["v"]))
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        try home.file(
            ".claude/skills/g/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("g", repo: "o/r", pinnedRef: "v1.2.3"))
        let report = try OwnershipBuilders.scan(home: home)
        let pinned = try Self.skill("g", in: report)
        let vercel = try Self.skill("v", in: report)
        let blocker = { (skill: Skill, action: LifecycleAction) in
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: action, capabilities: nil, report: report)
        }
        #expect(pinned.provenance.github?.pinned == true)
        #expect(pinned.provenance.github?.pinnedRef == "v1.2.3")
        #expect(blocker(pinned, .pin) == .alreadyPinned)
        #expect(blocker(pinned, .unpin) == nil)
        #expect(blocker(vercel, .pin) == .githubLedgerOnly)
        #expect(blocker(vercel, .unpin) == .githubLedgerOnly)
        #expect(blocker(vercel, .restore) == .githubLedgerOnly)
    }

    // MARK: - unpin

    @Test("Unpin groups named gh skill update --unpin --all per skills dir")
    func unpinCommandShape() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        let pinnedMD = { OwnershipBuilders.ghSkillMD($0, repo: "o/r", pinnedRef: "v1.2.3") }
        try home.file(".claude/skills/g1/SKILL.md", contents: pinnedMD("g1"))
        try home.file(".claude/skills/g2/SKILL.md", contents: pinnedMD("g2"))
        let report = try OwnershipBuilders.scan(home: home)
        let requests = try ["g2", "g1"].map {
            LifecycleRequest(skill: try Self.skill($0, in: report), action: .unpin)
        }
        let batch = try #require(try Self.plan(report, requests).batch)
        let dir = home.path + "/.claude/skills"
        #expect(
            batch.commands.map(\.argv) == [
                ["gh", "skill", "update", "g1", "g2", "--unpin", "--all", "--dir", dir]
            ])
        #expect(batch.commands.only?.consequence == CommandConsequence.unpinsAndUpdates.text)
        #expect(batch.findingRefs.map(\.ruleID) == ["library-unpin", "library-unpin"])
    }

    @Test("Unpin is withheld on an unpinned skill")
    func unpinEligibility() throws {
        let (report, _) = try Self.ghScan(OwnershipBuilders.ghSkillMD("g", repo: "o/r"))
        let skill = try Self.skill("g", in: report)
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .unpin, capabilities: nil, report: report) == .notPinned)
        let planned = try Self.plan(report, [LifecycleRequest(skill: skill, action: .unpin)])
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("not pinned") == true)
    }

    // MARK: - restore

    @Test("Restore re-installs unpinned skills without --pin, pinned ones with their ref")
    func restoreCommandShape() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".claude/skills/plain/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("plain", repo: "o/r"))
        try home.file(
            ".claude/skills/fixed/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("fixed", repo: "o/r", pinnedRef: "v1.2.3"))
        let report = try OwnershipBuilders.scan(home: home)
        let requests = try ["plain", "fixed"].map {
            LifecycleRequest(skill: try Self.skill($0, in: report), action: .restore)
        }
        let planned = try Self.plan(report, requests)
        let batch = try #require(planned.batch)
        let dir = home.path + "/.claude/skills"
        #expect(
            batch.commands.map(\.argv) == [
                [
                    "gh", "skill", "install", "o/r", "tools/fixed/SKILL.md", "--pin", "v1.2.3",
                    "--force", "--dir", dir
                ],
                [
                    "gh", "skill", "install", "o/r", "tools/plain/SKILL.md", "--force",
                    "--dir", dir
                ]
            ])
        #expect(
            batch.commands.allSatisfy {
                $0.consequence == CommandConsequence.mergeOverwritesCollidingFiles.text
            })
        #expect(batch.findingRefs.map(\.ruleID) == ["library-restore", "library-restore"])
    }

    @Test("Restore of a pinned skill without a recorded ref is refused")
    func restoreRefusedWithoutPinRef() throws {
        // The legacy bool form records no ref, and a re-install without
        // --pin would silently clear the pin.
        let (report, _) = try Self.ghScan(
            OwnershipBuilders.ghSkillMD("g", repo: "o/r", pinned: true))
        let skill = try Self.skill("g", in: report)
        let planned = try Self.plan(report, [LifecycleRequest(skill: skill, action: .restore)])
        #expect(planned.batch == nil)
        #expect(planned.skipped.only?.contains("pin ref is missing") == true)
    }

    // MARK: - Vercel-lock write guard

    @Test("A genuine user-scope Vercel record of the name withholds pin, unpin, and restore")
    func writeGuardApplies() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["v", "w"]))
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        try home.file(".agents/skills/w/SKILL.md", contents: OwnershipBuilders.skillMD("w"))
        try project.file(
            ".claude/skills/v/SKILL.md", contents: OwnershipBuilders.ghSkillMD("v", repo: "o/r"))
        try project.file(
            ".claude/skills/w/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("w", repo: "o/r", pinnedRef: "v1.2.3"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let unpinned = try #require(
            report.skills.first { $0.name == "v" && $0.scope == .project })
        let pinned = try #require(
            report.skills.first { $0.name == "w" && $0.scope == .project })
        for (skill, action) in [
            (unpinned, LifecycleAction.pin), (unpinned, .restore),
            (pinned, .unpin)
        ] {
            #expect(
                CommandBatchBuilder.lifecycleBlocker(
                    skill: skill, action: action, capabilities: nil, report: report)
                    == .touchesVercelRecord,
                "\(action) is a gh write, guarded like an update")
        }
        let planned = try Self.plan(
            report,
            [
                LifecycleRequest(skill: unpinned, action: .pin, pinRef: "v2"),
                LifecycleRequest(skill: unpinned, action: .restore),
                LifecycleRequest(skill: pinned, action: .unpin)
            ])
        #expect(planned.batch == nil)
        #expect(planned.skipped.count == 3)
        #expect(planned.skipped.allSatisfy { $0.contains("Vercel ledger's global lock") })
    }

    @Test("A gh companion record withholds nothing from pin, unpin, or restore")
    func companionRecordAllows() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.ghCompanionLock(["u"]))
        try home.file(
            ".claude/skills/u/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("u", repo: "o/r", pinnedRef: "v1.2.3"))
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try Self.skill("u", in: report)
        for action: LifecycleAction in [.pin, .unpin, .restore] {
            // .pin is withheld by the pin state alone, not the lock write.
            let expected: LifecycleBlocker? = action == .pin ? .alreadyPinned : nil
            #expect(
                CommandBatchBuilder.lifecycleBlocker(
                    skill: skill, action: action, capabilities: nil, report: report)
                    == expected)
        }
    }
}
