import Foundation
import Testing

@testable import SukiruCore

/// Double-booked arbitration (VAL-REPAIR-013…016, D10) and the finding-ID
/// scheme the decisions file keys on.
@Suite("CommandBatchBuilder double-booked arbitration")
struct ArbitrationBuilderTests {
    private typealias Support = BatchTestSupport

    // MARK: - VAL-REPAIR-013: no batch before an explicit surviving-ledger choice

    @Test("CM-3: update on a double-booked finding refuses, naming the skill and both choices")
    func updateNeedsArbitration() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let problems = Support.problems(report, [Support.decide(findingID, .update)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("double-booked"))
        #expect(joined.contains("stale-docs-cleanup"))
        #expect(joined.contains("keep-vercel"))
        #expect(joined.contains("keep-github"))
    }

    @Test("CM-3: arbitrate without a choice refuses; there is no default")
    func arbitrateNeedsChoice() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let problems = Support.problems(report, [Support.decide(findingID, .arbitrate)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("keep-vercel"))
        #expect(joined.contains("keep-github"))
    }

    @Test("arbitrate on a non-double-booked skill refuses, naming the ownership")
    func arbitrateRefusedWhenNotDoubleBooked() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let findingID = try Support.findingID(report, "cross-host-duplicate", "stale-docs-cleanup")
        let decision = Support.decide(findingID, .arbitrate, .keepVercel)
        let problems = Support.problems(report, [decision])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("not double-booked"))
        #expect(joined.contains("vercel"))
    }

    // MARK: - VAL-REPAIR-014: keep-vercel re-installs from the recorded source

    @Test("CM-3 keep-vercel: exactly the D10 re-install, no gh mutation, consequence text")
    func keepVercel() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let batch = try Support.build(
            report, [Support.decide(findingID, .arbitrate, .keepVercel)])
        let command = try #require(batch.commands.only)
        let expected = "npx skills add thedavidweng/skills --skill stale-docs-cleanup -y"
        #expect(command.argv.joined(separator: " ") == expected)
        #expect(command.owningCLI == .vercel)
        #expect(!batch.commands.contains { $0.owningCLI == .github })
        let consequence = try #require(command.consequence)
        #expect(consequence.contains("upstream"))
        #expect(consequence.contains("local edits"))
        #expect(consequence.contains("provenance"))
        #expect(batch.decisions.only?.choice == .keepVercel)
    }

    // MARK: - VAL-REPAIR-015: keep-github is remove (danger-flagged) then re-install

    @Test("CM-3 keep-github: npx remove then gh install --force --dir, in that order")
    func keepGitHub() throws {
        let tree = FixturePaths.tree("CM-3")
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let batch = try Support.build(
            report, [Support.decide(findingID, .arbitrate, .keepGitHub)])
        #expect(batch.commands.count == 2)
        let remove = batch.commands[0]
        let install = batch.commands[1]
        #expect(remove.argv == ["npx", "skills", "remove", "stale-docs-cleanup", "-y"])
        #expect(remove.dangerFlags == [.dangerousDeletion])
        let warning = try #require(remove.warning)
        #expect(warning.contains("stale-docs-cleanup"))
        #expect(warning.contains("across ownership"))
        let atRisk = [AtRiskSkill(skill: "stale-docs-cleanup", ownership: "double-booked")]
        #expect(remove.atRiskSkills == atRisk)
        let ghHead = ["gh", "skill", "install", "thedavidweng/skills"]
        let dir = tree + "/proj/.claude/skills"
        let rest = ["maintenance/stale-docs-cleanup", "--force", "--dir", dir]
        #expect(install.argv == ghHead + rest)
        #expect(install.owningCLI == .github)
        #expect(install.dangerFlags.isEmpty)
        let consequence = try #require(install.consequence)
        #expect(consequence.contains("gh-recorded ref"))
        #expect(consequence.contains("local edits"))
    }

    @Test("the two arbitration choices produce observably different command sequences")
    func choicesDiffer() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let vercelBatch = try Support.build(
            report, [Support.decide(findingID, .arbitrate, .keepVercel)])
        let githubBatch = try Support.build(
            report, [Support.decide(findingID, .arbitrate, .keepGitHub)])
        #expect(vercelBatch.commands.map(\.argv) != githubBatch.commands.map(\.argv))
    }

    @Test("FIX-OWNERSHIP-QUAD: user-scope keep-github scopes the remove with -g")
    func keepGitHubUserScope() throws {
        let tree = FixturePaths.tree("FIX-OWNERSHIP-QUAD")
        let report = try OwnershipBuilders.scan(fixture: "FIX-OWNERSHIP-QUAD")
        let findingID = try Support.findingID(report, "double-booked", "double-booked-skill")
        let batch = try Support.build(
            report, [Support.decide(findingID, .arbitrate, .keepGitHub)])
        #expect(batch.commands.count == 2)
        let removeLine = batch.commands[0].argv.joined(separator: " ")
        #expect(removeLine == "npx skills remove double-booked-skill -g -y")
        let ghHead = ["gh", "skill", "install", "thedavidweng/skills"]
        let dir = tree + "/.agents/skills"
        let rest = ["tools/double-booked-skill/SKILL.md", "--force", "--dir", dir]
        #expect(batch.commands[1].argv == ghHead + rest)
    }

    @Test("arbitrate with an adopt-style choice is rejected as invalid for the action")
    func arbitrateRejectsAdoptChoice() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let choice = DecisionChoice.adoptSource(repo: "acme/tools", path: "skills/x")
        let problems = Support.problems(report, [Support.decide(findingID, .arbitrate, choice)])
        #expect(problems.joined(separator: "\n").contains("keep-vercel"))
    }

    // MARK: - finding-ID scheme

    @Test("finding IDs are <ruleID>:<workspaceID>:<skillName>, disambiguated with #N")
    func findingIDScheme() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-USER-SCOPE-COPY-MODE")
        let ids = FindingID.assignments(for: report.findings).map(\.id)
        let authenticities = ids.filter { $0.hasPrefix("symlink-authenticity:") }
        let base = "symlink-authenticity:user:copy-tool"
        #expect(authenticities == [base, base + "#2"])
        #expect(ids.contains("cross-host-duplicate:user:copy-tool"))
        #expect(Set(ids).count == ids.count, "IDs must be unique")
    }

    @Test("a finding ID minted from one scan is rejected against a different scan (stale)")
    func staleIDAcrossScans() throws {
        let before = try OwnershipBuilders.scanSplitFixture("CM-1")
        let after = try OwnershipBuilders.scanSplitFixture("CM-2")
        let staleID = try Support.findingID(before, "cross-host-duplicate", "stale-docs-cleanup")
        let problems = Support.problems(after, [Support.decide(staleID, .update)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains(staleID))
        #expect(joined.contains("unknown or stale"))
    }
}
