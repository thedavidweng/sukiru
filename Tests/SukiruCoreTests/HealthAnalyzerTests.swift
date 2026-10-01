import Foundation
import Testing

@testable import SukiruCore

/// HealthAnalyzer rule semantics at unit level over TempTree (through
/// ScanEngine): the user-scope gate on symlink-authenticity, the
/// lock-without-files healthy-placement edge cases, dangerous-removal-surface
/// ledger gating, and cross-host-duplicate classification edges.
@Suite("HealthAnalyzer rule semantics")
struct HealthAnalyzerTests {
    /// A project v1 lock claiming `name` with a tunable source type and hash.
    private func projectLock(
        _ name: String, sourceType: String = "github", hash: String
    ) -> String {
        """
        {
          "version": 1,
          "skills": {
            "\(name)": {
              "source": "thedavidweng/skills",
              "sourceType": "\(sourceType)",
              "sourceUrl": "https://github.com/thedavidweng/skills.git",
              "skillPath": ".agents/skills/\(name)/SKILL.md",
              "computedHash": "\(hash)"
            }
          }
        }
        """
    }

    /// A 64-hex hash that matches nothing (drift fixtures).
    private let staleHash = String(repeating: "0", count: 64)

    private func scan(home: TempTree, project: TempTree) throws -> ScanReport {
        try OwnershipBuilders.scan(home: home, projectRoots: [project])
    }

    // MARK: - symlink-authenticity scope gate

    @Test("Project-scope copy mode is legitimate: no impostor finding, exact duplicate instead")
    func projectCopyModeNotAnImpostor() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(
            ".claude/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file("skills-lock.json", contents: projectLock("tool", hash: staleHash))

        let report = try scan(home: home, project: project)
        #expect(
            !report.findings.contains { $0.ruleID == "symlink-authenticity" },
            "project copy mode is the stock layout, never an impostor")
        #expect(
            report.findings.contains {
                $0.ruleID == "cross-host-duplicate" && $0.skillName == "tool"
                    && $0.evidence.contains { $0.detail == "exact" }
            })
    }

    @Test("User scope: a physical host copy beside the locked canonical store is an impostor")
    func userScopeHostCopyIsAnImpostor() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".claude/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(
            report.findings.first {
                $0.ruleID == "symlink-authenticity" && $0.skillName == "tool"
            })
        let canonical = home.path + "/.agents/skills/tool"
        let impostor = home.path + "/.claude/skills/tool"
        #expect(finding.evidence.contains { $0.kind == "impostorPath" && $0.detail == impostor })
        #expect(
            finding.evidence.contains { $0.kind == "canonicalPath" && $0.detail == canonical })
    }

    @Test("A symlinked host placement is never an impostor")
    func symlinkHostPlacementNotAnImpostor() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".claude/skills/tool", to: "../../.agents/skills/tool")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))

        let report = try OwnershipBuilders.scan(home: home)
        #expect(!report.findings.contains { $0.ruleID == "symlink-authenticity" })
    }

    // MARK: - lock-without-files edge cases

    @Test("A name with only a broken-symlink placement has no healthy files: finding fires")
    func lockWithoutFilesBrokenOnly() throws {
        let home = try TempTree()
        try home.symlink(".agents/skills/rotted", to: "/nonexistent/rotted-target")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["rotted"]))

        let report = try OwnershipBuilders.scan(home: home)
        #expect(
            report.findings.contains {
                $0.ruleID == "lock-without-files" && $0.skillName == "rotted"
            },
            "a dangling link is not a healthy placement")
        // The scanner's broken-symlink finding still stands, unattributed to us.
        #expect(
            report.findings.contains {
                $0.ruleID == "broken-symlink" && $0.skillName == "rotted"
            })
    }

    @Test("A lock entry with a healthy placement raises no finding")
    func lockWithHealthyPlacementSilent() throws {
        let home = try TempTree()
        try home.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))

        let report = try OwnershipBuilders.scan(home: home)
        #expect(!report.findings.contains { $0.ruleID == "lock-without-files" })
    }

    // MARK: - dangerous-removal-surface edge cases

    @Test("A vercel-locked name never carries the removal advisory, even when ambiguous")
    func removalAdvisorySkipsLockedNames() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(".codex/config.json", contents: "{}")
        // Ambiguity: two DIVERGENT copies with no canonical-store
        // placement for the lock to anchor them to.
        try home.file(
            ".claude/skills/dup/SKILL.md",
            contents: OwnershipBuilders.skillMD("dup", variant: "Copy in claude."))
        try home.file(
            ".codex/skills/dup/SKILL.md",
            contents: OwnershipBuilders.skillMD("dup", variant: "Divergent copy in codex."))
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["dup"]))

        let report = try OwnershipBuilders.scan(home: home)
        let dup = try #require(report.skills.first { $0.name == "dup" })
        #expect(dup.ambiguous, "two divergent unexplained copies make the name ambiguous")
        #expect(
            !report.findings.contains {
                $0.ruleID == "dangerous-removal-surface" && $0.skillName == "dup"
            },
            "the vercel ledger knows the name; removal is ledger-consistent")
    }

    @Test("An ambiguous name with NO ledger claim carries the advisory (deletes copies by name)")
    func removalAdvisoryOnAmbiguousOwnerless() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(".codex/config.json", contents: "{}")
        try home.file(
            ".claude/skills/dup/SKILL.md",
            contents: OwnershipBuilders.skillMD("dup", variant: "Copy in claude."))
        try home.file(
            ".codex/skills/dup/SKILL.md",
            contents: OwnershipBuilders.skillMD("dup", variant: "Divergent copy in codex."))

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(
            report.findings.first {
                $0.ruleID == "dangerous-removal-surface" && $0.skillName == "dup"
            })
        #expect(finding.severity == .action)
        #expect(finding.evidence.contains { $0.kind == "ownership" && $0.detail == "ownerless" })
        #expect(finding.evidence.filter { $0.kind == "placementPath" }.count == 2)
    }

    @Test("Removal advisory evidence lists real placements only, never broken symlinks")
    func removalAdvisoryExcludesBrokenSymlinkEvidence() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(
            ".claude/skills/dup/SKILL.md",
            contents: OwnershipBuilders.skillMD("dup", variant: "Real copy in claude."))
        // A dangling link under the SAME name: one group, one real member,
        // one broken member. The advisory's placementPath evidence is framed
        // as the files `npx skills remove` would delete — every other rule
        // filters broken symlinks out of such lists.
        try home.symlink(".codex/skills/dup", to: "../nowhere/dup")

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(
            report.findings.first {
                $0.ruleID == "dangerous-removal-surface" && $0.skillName == "dup"
            })
        let paths = finding.evidence.filter { $0.kind == "placementPath" }.map(\.detail)
        #expect(paths == [home.path + "/.claude/skills/dup"])
        // The dangling link is still reported by its own rule.
        #expect(
            report.findings.contains {
                $0.ruleID == "broken-symlink" && $0.skillName == "dup"
            })
    }

    // MARK: - cross-host-duplicate unit edges

    @Test("A single placement is never a duplicate")
    func singlePlacementNoDuplicate() throws {
        let home = try TempTree()
        try home.file(
            ".agents/skills/solo/SKILL.md", contents: OwnershipBuilders.skillMD("solo"))

        let report = try OwnershipBuilders.scan(home: home)
        #expect(!report.findings.contains { $0.ruleID == "cross-host-duplicate" })
    }

    @Test("The same name in user AND project scope is not a cross-host duplicate (per-scope rule)")
    func crossScopeNameIsNotDuplicate() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(
            ".agents/skills/shared/SKILL.md", contents: OwnershipBuilders.skillMD("shared"))
        try project.file(
            ".agents/skills/shared/SKILL.md", contents: OwnershipBuilders.skillMD("shared"))

        let report = try scan(home: home, project: project)
        #expect(
            !report.findings.contains { $0.ruleID == "cross-host-duplicate" },
            "scopes are governed separately; duplicates group per scope")
    }
}
