import Foundation
import Testing

@testable import SukiruCore

/// End-to-end assertions for the CLI-generated collision-matrix corpus

///
/// The CM-* trees are REAL dirty states produced by the pinned
/// skills@1.5.26 CLI and gh in sandboxes (`Scripts/fixtures/generate.sh`);
/// these tests drive the built `sukiru-cli` and assert the complete
/// ownership/finding shape of each scenario against the decoded ScanReport.
/// Byte-exact whole-report coverage lives in CorpusExpectationTests; this
/// suite pins the load-bearing semantics so a blind snapshot re-record can
/// never silently bless a regression.
@Suite("Collision-matrix corpus end-to-end")
struct CollisionMatrixCorpusTests {
    private static let skillName = "stale-docs-cleanup"

    private func skill(in report: ScanReport, named name: String) throws -> Skill {
        try #require(report.skills.first { $0.name == name }, "skill \(name) not inventoried")
    }

    // MARK: CM-1 npx copy-mode baseline

    @Test("CM-1 is vercel-owned with a warning exact-duplicate and nothing else")
    func cm1CopyModeBaseline() throws {
        let report = try CLIRunner.scanReport("CM-1")
        let skill = try skill(in: report, named: Self.skillName)

        #expect(skill.ownership == .vercel)
        #expect(skill.scope == .project)
        #expect(!skill.ambiguous)
        #expect(skill.placements.count == 2)
        #expect(skill.placements.allSatisfy { $0.kind == .directory })

        let vercel = try #require(skill.provenance.vercel)
        #expect(vercel.source == "thedavidweng/skills")
        #expect(vercel.sourceType == "github")
        #expect(vercel.skillPath == "maintenance/stale-docs-cleanup/SKILL.md")
        #expect(vercel.computedHash != nil)
        #expect(vercel.skillFolderHash == nil)
        #expect(skill.provenance.github == nil)

        let exactDuplicates = report.findings(rule: "cross-host-duplicate")
            .filter { $0.evidenceDetails("subtype") == ["exact"] }
        #expect(exactDuplicates.count == 1)
        #expect(exactDuplicates.first?.severity == .warning)

        #expect(report.findings(rule: "vercel-lock-drift").isEmpty)
        #expect(report.findings(rule: "double-booked").isEmpty)
        #expect(report.findings(rule: "files-without-lock").isEmpty)
        #expect(!report.hasUserScopeLockNoise)
    }

    // MARK: CM-2 gh baseline

    @Test("CM-2 is github-owned with full provenance and the danger advisory")
    func cm2GitHubBaseline() throws {
        let report = try CLIRunner.scanReport("CM-2")
        let skill = try skill(in: report, named: Self.skillName)

        #expect(skill.ownership == .github)
        #expect(skill.scope == .project)
        let github = try #require(skill.provenance.github)
        #expect(github.repo == "https://github.com/thedavidweng/skills")
        #expect(github.ref == "refs/heads/main")
        #expect(github.treeSha != nil)
        #expect(skill.provenance.vercel == nil)

        #expect(report.findings(rule: "vercel-lock-drift").isEmpty)
        #expect(report.findings(rule: "files-without-lock").isEmpty)
        let advisories = report.findings(rule: "dangerous-removal-surface")
        #expect(advisories.count == 1)
        #expect(advisories.first?.evidenceDetails("ownership") == ["github"])
        #expect(!report.hasUserScopeLockNoise)
    }

    // MARK: CM-3 double-booked tri-symptom

    @Test("CM-3 shows double-booked + drift + divergence in one scan")
    func cm3TriSymptom() throws {
        let report = try CLIRunner.scanReport("CM-3")
        let skill = try skill(in: report, named: Self.skillName)
        #expect(skill.ownership == .doubleBooked)
        #expect(!skill.ambiguous)

        let doubleBooked = try #require(report.findings(rule: "double-booked").first)
        for kind in ["lockPath", "entryKey", "skillMdPath", "githubRepo"] {
            #expect(!doubleBooked.evidenceDetails(kind).isEmpty, "double-booked lacks \(kind)")
        }

        let drift = try #require(report.findings(rule: "vercel-lock-drift").first)
        #expect(drift.evidenceDetails("placementPath").contains { $0.contains(".claude") })
        for kind in ["lockPath", "entryKey", "expectedHash", "actualHash"] {
            #expect(!drift.evidenceDetails(kind).isEmpty, "drift lacks \(kind)")
        }

        let divergence = try #require(report.findings(rule: "canonical-host-divergence").first)
        #expect(!divergence.evidenceDetails("sourceIdentity").isEmpty)
        #expect(!divergence.evidenceDetails("canonicalPath").isEmpty)
        #expect(!divergence.evidenceDetails("hostPath").isEmpty)
        #expect(divergence.evidenceDetails("contentHash").count == 2)

        #expect(!report.hasUserScopeLockNoise)
    }

    // MARK: CM-5 reverse double-booked (provenance erased)

    @Test("CM-5 reflects post-erasure truth — vercel-only, no github trace")
    func cm5ProvenanceErased() throws {
        let report = try CLIRunner.scanReport("CM-5")
        let skill = try skill(in: report, named: Self.skillName)

        #expect(skill.ownership == .vercel)
        #expect(skill.provenance.vercel != nil)
        #expect(report.skills.allSatisfy { $0.provenance.github == nil })
        #expect(report.findings(rule: "double-booked").isEmpty)
        #expect(!report.hasUserScopeLockNoise)
    }

    // MARK: CM-8 mixed install, three-source resolution

    @Test("CM-8 resolves double-booked, never ambiguous, with both claims as data")
    func cm8ThreeSourceResolution() throws {
        let report = try CLIRunner.scanReport("CM-8")
        let skill = try skill(in: report, named: Self.skillName)

        // One name, three physical placements, correct kinds/paths.
        #expect(skill.placements.count == 3)
        #expect(skill.placements.allSatisfy { $0.kind == .directory })
        let paths = skill.placements.map(\.path)
        #expect(paths.contains { $0.contains(".agents/skills/") })
        #expect(paths.contains { $0.contains(".claude/skills/") })
        #expect(paths.contains { $0.contains(".qoder/skills/") })

        // The .qoder copy is hash-explained by the lock-anchored
        // canonical placement, so the name is NOT ambiguous; ownership is
        // double-booked with BOTH ledger claims surfaced as data.
        #expect(skill.ownership == .doubleBooked)
        #expect(!skill.ambiguous)
        #expect(skill.provenance.vercel != nil)
        #expect(skill.provenance.github != nil)
        #expect(report.findings(rule: "ambiguous-name").isEmpty)

        #expect(!report.findings(rule: "double-booked").isEmpty)

        let drift = report.findings(rule: "vercel-lock-drift")
        #expect(
            drift.contains { finding in
                finding.evidenceDetails("placementPath").contains { $0.contains(".claude") }
            })
        #expect(!report.findings(rule: "canonical-host-divergence").isEmpty)

        let exactDuplicates = report.findings(rule: "cross-host-duplicate")
            .filter { $0.evidenceDetails("subtype") == ["exact"] }
        #expect(
            exactDuplicates.contains { finding in
                let members = finding.evidenceDetails("memberPath")
                return members.contains { $0.contains(".qoder") }
                    && members.contains { $0.contains(".agents") }
            })

        #expect(!report.hasUserScopeLockNoise)
    }

    // MARK: Scope separation and isolation

    @Test("Project scope never leaks into user scope")
    func scopeIsolation() throws {
        let report = try CLIRunner.scanReport("scope-isolation")

        // The same name exists once per scope, each resolved against ITS OWN
        // lock: the user-scope claim carries the global-lock hash key, the
        // project-scope claim the project-lock hash key.
        let shared = report.skills.filter { $0.name == "shared-skill" }
        #expect(shared.count == 2)
        let userShared = try #require(shared.first { $0.scope == .user })
        let projectShared = try #require(shared.first { $0.scope == .project })
        #expect(userShared.ownership == .vercel)
        #expect(projectShared.ownership == .vercel)
        #expect(!userShared.ambiguous && !projectShared.ambiguous)
        #expect(userShared.provenance.vercel?.skillFolderHash != nil)
        #expect(userShared.provenance.vercel?.computedHash == nil)
        #expect(projectShared.provenance.vercel?.computedHash != nil)
        #expect(projectShared.provenance.vercel?.skillFolderHash == nil)

        // Every finding anchors to a workspace of its own scope.
        let workspaceKinds = Dictionary(
            uniqueKeysWithValues: report.workspaces.map { ($0.id, $0.kind) })
        for finding in report.findings {
            let kind = try #require(
                workspaceKinds[finding.workspaceID],
                "finding \(finding.ruleID) anchors to unknown workspace \(finding.workspaceID)"
            )
            if finding.workspaceID == "user" {
                #expect(kind == .user)
            } else {
                #expect(kind == .project)
            }
        }

        // Each orphan's files-without-lock finding stays in its own scope.
        let orphanFindings = report.findings(rule: "files-without-lock")
        #expect(
            orphanFindings.contains {
                $0.skillName == "user-orphan" && $0.workspaceID == "user"
            })
        #expect(
            orphanFindings.contains {
                $0.skillName == "proj-orphan" && $0.workspaceID.hasPrefix("project:")
            })
        let userOrphanFindings = orphanFindings.filter { $0.skillName == "user-orphan" }
        let projOrphanFindings = orphanFindings.filter { $0.skillName == "proj-orphan" }
        #expect(userOrphanFindings.allSatisfy { $0.workspaceID == "user" })
        #expect(projOrphanFindings.allSatisfy { $0.workspaceID.hasPrefix("project:") })
    }
}
