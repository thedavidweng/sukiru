import Foundation
import Testing

@testable import SukiruCore

/// OwnershipResolver ambiguity and scope-independence rules (architecture D1,
/// VAL-SCAN-018/055/056) — unit-level over TempTree, through ScanEngine.
@Suite("OwnershipResolver ambiguity and scope rules")
struct OwnershipResolverAmbiguityTests {
    @Test("Ambiguous name voids attribution: ownerless + ambiguous, lock claim stays data")
    func ambiguousVoidsOwnership() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(".codex/config.json", contents: "{}")
        let first = try home.file(
            ".claude/skills/dup/SKILL.md", contents: OwnershipBuilders.skillMD("dup"))
        let second = try home.file(
            ".codex/skills/dup/SKILL.md", contents: OwnershipBuilders.skillMD("dup"))
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["dup"]))

        let report = try OwnershipBuilders.scan(home: home)
        let dup = try #require(report.skills.first { $0.name == "dup" })
        #expect(report.skills.count == 1)
        #expect(dup.ambiguous == true)
        #expect(dup.ownership == .ownerless, "attribution voided, never guessed")
        // The lock claim is still surfaced as data, not authoritative ownership.
        #expect(dup.provenance.vercel != nil)
        #expect(dup.provenance.vercel?.skillFolderHash == String(repeating: "9", count: 40))

        let finding = try #require(report.findings.first { $0.ruleID == "ambiguous-name" })
        #expect(finding.severity == .warning)
        #expect(finding.skillName == "dup")
        let paths = finding.evidence.filter { $0.kind == "placementPath" }.map(\.detail)
        let expected = [first, second].map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        #expect(paths.sorted() == expected.sorted(), "one placementPath per colliding dir")
        // The ambiguity report stands in for the ownerless listing.
        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
    }

    @Test("Alias placements never trigger ambiguity and ownership resolves from the lock")
    func aliasGroupNeverAmbiguous() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(".codex/config.json", contents: "{}")
        let canonical = try home.file(
            ".agents/skills/demo/SKILL.md", contents: OwnershipBuilders.skillMD("demo"))
        let target = URL(fileURLWithPath: canonical).deletingLastPathComponent().path
        try home.symlink(".claude/skills/demo", to: target)
        try home.symlink(".codex/skills/demo", to: target)
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["demo"]))

        let report = try OwnershipBuilders.scan(home: home)
        let demo = try #require(report.skills.first { $0.name == "demo" })
        #expect(report.skills.count == 1)
        #expect(demo.placements.count == 3)
        #expect(demo.ambiguous == false, "D1 negative: aliases collapse to one canonical path")
        #expect(demo.ownership == .vercel, "ownership resolves normally on an alias group")
        #expect(!report.findings.contains { $0.ruleID == "ambiguous-name" })
        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
    }

    @Test("A broken-symlink-only name is ownerless but raises no files-without-lock")
    func brokenSymlinkNotListedAsFiles() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.symlink(".claude/skills/rotted", to: "/nonexistent/rotted-target")

        let report = try OwnershipBuilders.scan(home: home)
        let rotted = try #require(report.skills.first { $0.name == "rotted" })
        #expect(rotted.ownership == .ownerless)
        #expect(rotted.ambiguous == false)
        #expect(
            !report.findings.contains {
                $0.ruleID == "files-without-lock" && $0.skillName == "rotted"
            },
            "a dangling link has no files to list; the broken-symlink finding covers it")
        #expect(report.findings.contains { $0.ruleID == "broken-symlink" })
    }

    @Test("Ownership resolves independently per project root, no cross-root ledger bleed")
    func perProjectIndependence() throws {
        let home = try TempTree()
        let first = try TempTree()
        let second = try TempTree()
        try first.file(
            ".agents/skills/shared/SKILL.md", contents: OwnershipBuilders.skillMD("shared"))
        try first.file("skills-lock.json", contents: OwnershipBuilders.projectLock("shared"))
        try second.file(
            ".agents/skills/shared/SKILL.md", contents: OwnershipBuilders.skillMD("shared"))

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [first, second])
        let shared = report.skills.filter { $0.name == "shared" }
        #expect(shared.count == 2)

        let locked = try #require(
            shared.first { $0.placements.first?.path.hasPrefix(first.path) == true })
        #expect(locked.ownership == .vercel)
        #expect(locked.provenance.vercel != nil)

        let free = try #require(
            shared.first { $0.placements.first?.path.hasPrefix(second.path) == true })
        #expect(free.ownership == .ownerless, "p2 has no ledger claim for shared")
        #expect(free.provenance.vercel == nil)

        let finding = try #require(
            report.findings.first { $0.ruleID == "files-without-lock" && $0.skillName == "shared" })
        #expect(finding.workspaceID == "project:\(second.path)")
        #expect(
            !report.findings.contains {
                $0.ruleID == "files-without-lock" && $0.workspaceID == "project:\(first.path)"
            })
    }

    @Test("User scope and project scope never share ledger claims")
    func crossScopeIsolation() throws {
        let home = try TempTree()
        let project = try TempTree()
        // User scope: lock claims `shared`. Project scope: placement only.
        try home.file(
            ".agents/skills/shared/SKILL.md", contents: OwnershipBuilders.skillMD("shared"))
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["shared"]))
        try project.file(
            ".agents/skills/shared/SKILL.md", contents: OwnershipBuilders.skillMD("shared"))

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let shared = report.skills.filter { $0.name == "shared" }
        #expect(shared.count == 2)
        let userSkill = try #require(shared.first { $0.scope == .user })
        let projectSkill = try #require(shared.first { $0.scope == .project })
        #expect(userSkill.ownership == .vercel)
        #expect(projectSkill.ownership == .ownerless)
        #expect(projectSkill.ambiguous == false, "per-scope rule: one placement per scope")
    }
}
