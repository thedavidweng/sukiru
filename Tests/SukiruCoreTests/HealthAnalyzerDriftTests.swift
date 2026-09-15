import Foundation
import Testing

@testable import SukiruCore

/// HealthAnalyzer's `vercel-lock-drift` rule: evidence shape and the
/// recompute-eligibility gate (hash-algorithm.md §4.4), unit-level over
/// TempTree through ScanEngine.
@Suite("HealthAnalyzer vercel-lock-drift gating")
struct HealthAnalyzerDriftTests {
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

    // MARK: - vercel-lock-drift

    @Test("Drift fires with lock/entry/expected/actual evidence on an eligible tree")
    func driftFiresWithEvidence() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/drifted/SKILL.md",
            contents: OwnershipBuilders.skillMD("drifted"))
        let lockPath = try project.file(
            "skills-lock.json", contents: projectLock("drifted", hash: staleHash))

        let report = try scan(home: home, project: project)
        let finding = try #require(
            report.findings.first { $0.ruleID == "vercel-lock-drift" })
        #expect(finding.severity == .action)
        #expect(finding.skillName == "drifted")
        #expect(finding.workspaceID == "project:\(project.path)")
        #expect(finding.evidence.contains { $0.kind == "lockPath" && $0.detail == lockPath })
        #expect(finding.evidence.contains { $0.kind == "entryKey" && $0.detail == "drifted" })
        #expect(
            finding.evidence.contains { $0.kind == "expectedHash" && $0.detail == staleHash })
        let skill = try #require(report.skills.first { $0.name == "drifted" })
        let recomputed = try #require(skill.placements.first?.contentHash)
        #expect(
            finding.evidence.contains { $0.kind == "actualHash" && $0.detail == recomputed })
        #expect(recomputed != staleHash)
    }

    @Test("No drift when the lock hash matches disk")
    func noDriftWhenMatching() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/aligned/SKILL.md",
            contents: OwnershipBuilders.skillMD("aligned"))
        // Hash the on-disk content exactly like the engine does.
        let root = project.path + "/.agents/skills/aligned"
        let hasher = ContentHasher()
        let hashResult = hasher.computedHash(ofSkillAtPath: root)
        let hash = try #require(hashResult.successValue)
        try project.file("skills-lock.json", contents: projectLock("aligned", hash: hash))

        let report = try scan(home: home, project: project)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
    }

    @Test("Drift gate: metadata.json in the tree suppresses the finding (copy-filter divergence)")
    func driftGatedByMetadataJson() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(".agents/skills/tool/metadata.json", contents: "{}")
        try project.file("skills-lock.json", contents: projectLock("tool", hash: staleHash))

        let report = try scan(home: home, project: project)
        #expect(
            !report.findings.contains { $0.ruleID == "vercel-lock-drift" },
            "metadata.json is hashed but never copied — a mismatch cannot be verified")
    }

    @Test("Drift gate: a symlink inside the tree suppresses the finding")
    func driftGatedBySymlink() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.symlink(".agents/skills/tool/link.txt", to: "SKILL.md")
        try project.file("skills-lock.json", contents: projectLock("tool", hash: staleHash))

        let report = try scan(home: home, project: project)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
    }

    @Test("Drift gate: node_modules in the tree suppresses the finding")
    func driftGatedByNodeModules() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(".agents/skills/tool/node_modules/pkg/index.js", contents: "x")
        try project.file("skills-lock.json", contents: projectLock("tool", hash: staleHash))

        let report = try scan(home: home, project: project)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
    }

    @Test("Drift gate: a non-ASCII relative path suppresses the finding (locale-sensitive hash)")
    func driftGatedByNonAscii() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(".agents/skills/tool/é.md", contents: "accented")
        try project.file("skills-lock.json", contents: projectLock("tool", hash: staleHash))

        let report = try scan(home: home, project: project)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
    }

    @Test("Drift gate: a 40-hex stored hash is a git tree SHA — passthrough, never compared")
    func driftGatedByGitTreeSha() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        let treeSha = String(repeating: "0", count: 40)
        try project.file("skills-lock.json", contents: projectLock("tool", hash: treeSha))

        let report = try scan(home: home, project: project)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
    }

    @Test("Drift gate: an unrecognized sourceType cannot be verified")
    func driftGatedBySourceType() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(
            "skills-lock.json",
            contents: projectLock("tool", sourceType: "plugin", hash: staleHash))

        let report = try scan(home: home, project: project)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
    }

    @Test("Drift compares every placement: a matching canonical copy clears no drifted host copy")
    func driftPerPlacement() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/web-tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("web-tool"))
        // The canonical copy's real hash goes in the lock.
        let canonicalRoot = project.path + "/.agents/skills/web-tool"
        let hasher = ContentHasher()
        let hashResult = hasher.computedHash(ofSkillAtPath: canonicalRoot)
        let hash = try #require(hashResult.successValue)
        try project.file("skills-lock.json", contents: projectLock("web-tool", hash: hash))
        // The host copy diverges out-of-band (collision-matrix scenario 3).
        try project.file(
            ".claude/skills/web-tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("web-tool") + "\nEdited out of band.\n")

        let report = try scan(home: home, project: project)
        let finding = try #require(
            report.findings.first { $0.ruleID == "vercel-lock-drift" })
        #expect(finding.skillName == "web-tool")
        #expect(
            finding.evidence.contains {
                $0.kind == "placementPath" && $0.detail.hasSuffix(".claude/skills/web-tool")
            },
            "the drift finding names the mismatching copy")
        // The divergence rule fires alongside (same source identity, two hashes).
        #expect(
            report.findings.contains {
                $0.ruleID == "canonical-host-divergence" && $0.skillName == "web-tool"
            })
    }
}
