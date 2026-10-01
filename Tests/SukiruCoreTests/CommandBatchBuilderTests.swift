import Foundation
import Testing

@testable import SukiruCore

extension Array {
    /// The single element, or nil — for "exactly one command" assertions.
    var only: Element? {
        count == 1 ? first : nil
    }
}

/// Shared helpers for the CommandBatchBuilder suites.
enum BatchTestSupport {
    static let fixedDate = Date(timeIntervalSince1970: 1_757_923_200)

    static func makeBuilder() -> CommandBatchBuilder {
        CommandBatchBuilder(
            idProvider: { "batch-fixed" },
            dateProvider: { fixedDate })
    }

    static func decide(
        _ findingID: String, _ action: DecisionAction, _ choice: DecisionChoice? = nil
    ) -> DecisionEntry {
        DecisionEntry(findingID: findingID, action: action, choice: choice)
    }

    static func findingID(
        _ report: ScanReport, _ ruleID: String, _ skill: String
    ) throws -> String {
        let match = FindingID.assignments(for: report.findings).first {
            $0.finding.ruleID == ruleID && $0.finding.skillName == skill
        }
        return try #require(match).id
    }

    static func build(
        _ report: ScanReport, _ decisions: [DecisionEntry]
    ) throws -> CommandBatch {
        try #require(try makeBuilder().build(report: report, decisions: decisions))
    }

    static func problems(
        _ report: ScanReport, _ decisions: [DecisionEntry]
    ) -> [String] {
        do {
            _ = try makeBuilder().build(report: report, decisions: decisions)
            return []
        } catch let error as BatchBuildError {
            return error.problems
        } catch {
            return ["unexpected error: \(error)"]
        }
    }
}

/// Ownership-routed updates, drift repair, ownerless/ambiguous refusals,
/// adopt, and cleanup.
@Suite("CommandBatchBuilder ownership routing")
struct CommandBatchBuilderTests {
    private typealias Support = BatchTestSupport

    // MARK: - Vercel update routes to npx, scope-flagged

    @Test("CM-1: update on a vercel-ledger finding is npx skills update <name> -p -y")
    func vercelProjectUpdate() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let findingID = try Support.findingID(report, "cross-host-duplicate", "stale-docs-cleanup")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "update", "stale-docs-cleanup", "-p", "-y"])
        #expect(command.owningCLI == .vercel)
        #expect(command.dangerFlags.isEmpty)
        #expect(command.warning == nil)
        #expect(command.intent.contains("cross-host-duplicate"))
        #expect(command.intent.contains("stale-docs-cleanup"))
        #expect(!batch.commands.contains { $0.argv.first == "gh" })
    }

    @Test("impostor-copy: a user-scope vercel update carries -g")
    func vercelUserUpdate() throws {
        let report = try OwnershipBuilders.scan(fixture: "impostor-copy")
        let findingID = try Support.findingID(report, "symlink-authenticity", "tool")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "update", "tool", "-g", "-y"])
        #expect(command.owningCLI == .vercel)
    }

    // MARK: - Github update routes to gh, narrowly targeted

    @Test("CM-2: update on a github-ledger skill is gh skill update <name> --dir <dir>")
    func githubUpdate() throws {
        let tree = FixturePaths.tree("CM-2")
        let report = try OwnershipBuilders.scanSplitFixture("CM-2")
        let findingID = try Support.findingID(
            report, "dangerous-removal-surface", "stale-docs-cleanup")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        let command = try #require(batch.commands.only)
        let expected = "gh skill update stale-docs-cleanup --dir \(tree)/proj/.claude/skills"
        #expect(command.argv.joined(separator: " ") == expected)
        #expect(command.owningCLI == .github)
        #expect(!command.argv.contains("--all"))
        #expect(!batch.commands.contains { $0.argv.first == "npx" })
    }

    // MARK: - Drift repair re-installs from the recorded source

    @Test("FIX-DRIFT: update on a vercel-lock-drift finding re-installs from the recorded source")
    func driftRepairReinstalls() throws {
        let report = try OwnershipBuilders.scanSplitFixture("FIX-DRIFT")
        let findingID = try Support.findingID(report, "vercel-lock-drift", "drifted")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        let command = try #require(batch.commands.only)
        let expected = "npx skills add thedavidweng/skills --skill drifted -y"
        #expect(command.argv.joined(separator: " ") == expected)
        #expect(command.owningCLI == .vercel)
        let consequence = try #require(command.consequence)
        #expect(consequence.contains("upstream"))
        #expect(consequence.contains("local edits"))
        #expect(!command.argv.contains("update"), "drift repair must never use update")
    }

    // MARK: - Ownerless skills are never silently routed

    @Test("FIX-FILES-NO-LOCK: update on an ownerless skill is refused, naming adopt/cleanup")
    func ownerlessUpdateRefused() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(report, "files-without-lock", "orphan")
        let problems = Support.problems(report, [Support.decide(findingID, .update)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("no ledger owns this skill"))
        #expect(joined.contains("orphan"))
    }

    // MARK: - Ambiguous names route as ownerless

    @Test("FIX-AMBIGUOUS: update refuses with an attribution-voided explanation")
    func ambiguousUpdateRefused() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-AMBIGUOUS")
        let findingID = try Support.findingID(report, "ambiguous-name", "dup")
        let problems = Support.problems(report, [Support.decide(findingID, .update)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("attribution"))
        #expect(joined.contains("dup"))
    }

    // MARK: - lock-without-files ghosts have no repair target

    @Test("FIX-LOCK-NO-FILES: update on a lock-entry ghost names the missing placement")
    func ghostUpdateRefused() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-LOCK-NO-FILES")
        let findingID = try Support.findingID(report, "lock-without-files", "ghost")
        let problems = Support.problems(report, [Support.decide(findingID, .update)])
        #expect(problems.joined(separator: "\n").contains("no on-disk placement"))
    }

    // MARK: - Ownerless adopt

    @Test("FIX-FILES-NO-LOCK: adopt produces the gh re-anchoring install shape")
    func ownerlessAdopt() throws {
        let tree = FixturePaths.tree("FIX-FILES-NO-LOCK")
        let report = try OwnershipBuilders.scan(fixture: "FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(report, "files-without-lock", "orphan")
        let choice = DecisionChoice.adoptSource(repo: "acme/tools", path: "skills/orphan")
        let batch = try Support.build(report, [Support.decide(findingID, .adopt, choice)])
        let command = try #require(batch.commands.only)
        let ghHead = ["gh", "skill", "install", "acme/tools"]
        let dir = tree + "/.agents/skills"
        #expect(command.argv == ghHead + ["skills/orphan", "--force", "--dir", dir])
        #expect(command.owningCLI == .github)
        let consequence = try #require(command.consequence)
        #expect(consequence.contains("merge-overwrite"))
        #expect(consequence.contains("overwrites colliding"))
    }

    @Test("FIX-AMBIGUOUS: adopt is offered to ambiguous skills, one install per placement dir")
    func ambiguousAdopt() throws {
        let tree = FixturePaths.tree("FIX-AMBIGUOUS")
        let report = try OwnershipBuilders.scan(fixture: "FIX-AMBIGUOUS")
        let findingID = try Support.findingID(report, "ambiguous-name", "dup")
        let choice = DecisionChoice.adoptSource(repo: "acme/tools", path: "skills/dup")
        let batch = try Support.build(report, [Support.decide(findingID, .adopt, choice)])
        #expect(batch.commands.count == 2)
        let dirs = batch.commands.map { $0.argv.last ?? "" }
        #expect(dirs == [tree + "/.claude/skills", tree + "/.codex/skills"])
        #expect(batch.commands.allSatisfy { $0.owningCLI == .github })
    }

    @Test("adopt on an owned skill refuses, naming the owning ledger")
    func adoptRefusedWhenOwned() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let findingID = try Support.findingID(report, "cross-host-duplicate", "stale-docs-cleanup")
        let choice = DecisionChoice.adoptSource(repo: "acme/tools", path: "skills/x")
        let problems = Support.problems(report, [Support.decide(findingID, .adopt, choice)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("already owned"))
        #expect(joined.contains("vercel"))
    }

    // MARK: - Ownerless cleanup is a flagged file operation

    @Test("FIX-FILES-NO-LOCK: cleanup is a flagged direct file operation, not a CLI command")
    func ownerlessCleanup() throws {
        let tree = FixturePaths.tree("FIX-FILES-NO-LOCK")
        let report = try OwnershipBuilders.scan(fixture: "FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(report, "files-without-lock", "orphan")
        let batch = try Support.build(report, [Support.decide(findingID, .cleanup)])
        let command = try #require(batch.commands.only)
        #expect(command.owningCLI == .file)
        let argv = command.argv.joined(separator: " ")
        #expect(argv == "sukiru-fileop delete-directory \(tree)/.agents/skills/orphan")
        #expect(command.dangerFlags.contains(.directFileOperation))
        #expect(command.dangerFlags.contains(.ownerlessCleanup))
        let warning = try #require(command.warning)
        #expect(warning.contains("snapshot"))
        #expect(warning.contains("orphan"))
    }

    // MARK: - npx skills remove danger flag + at-risk naming

    @Test("CM-6: cleanup on a github-owned skill dispatches npx skills remove with named at-risk")
    func githubCleanupDanger() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-6")
        let findingID = try Support.findingID(
            report, "dangerous-removal-surface", "stale-docs-cleanup")
        let batch = try Support.build(report, [Support.decide(findingID, .cleanup)])
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "remove", "stale-docs-cleanup", "-y"])
        #expect(command.dangerFlags == [.dangerousDeletion])
        let warning = try #require(command.warning)
        #expect(warning.contains("stale-docs-cleanup"))
        #expect(warning.contains("github"))
        let atRisk = [AtRiskSkill(skill: "stale-docs-cleanup", ownership: "github")]
        #expect(command.atRiskSkills == atRisk)
    }

    @Test("FIX-DANGER: user-scope cleanup of a github skill carries -g and the danger flag")
    func githubUserCleanup() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-DANGER")
        let findingID = try Support.findingID(report, "dangerous-removal-surface", "gh-tool")
        let batch = try Support.build(report, [Support.decide(findingID, .cleanup)])
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "remove", "gh-tool", "-g", "-y"])
        #expect(command.dangerFlags == [.dangerousDeletion])
        #expect(command.atRiskSkills == [AtRiskSkill(skill: "gh-tool", ownership: "github")])
    }

    @Test("CM-1: cleanup on a vercel-owned skill is npx skills remove, flagged, with no at-risk")
    func vercelCleanup() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let findingID = try Support.findingID(report, "cross-host-duplicate", "stale-docs-cleanup")
        let batch = try Support.build(report, [Support.decide(findingID, .cleanup)])
        let command = try #require(batch.commands.only)
        #expect(command.argv == ["npx", "skills", "remove", "stale-docs-cleanup", "-y"])
        #expect(command.dangerFlags == [.dangerousDeletion])
        #expect(command.atRiskSkills.isEmpty)
        let warning = try #require(command.warning)
        #expect(warning.contains("across ownership"))
    }

    // MARK: - leave-as-is produces no batch

    @Test("leave-only decisions produce no batch at all")
    func leaveProducesNoBatch() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(report, "files-without-lock", "orphan")
        let batch = try Support.makeBuilder().build(
            report: report, decisions: [Support.decide(findingID, .leave)])
        #expect(batch == nil)
    }

    // MARK: - batch envelope

    @Test("batch envelope: proposed status, nil snapshot, findingRefs round-trip, injected id/date")
    func batchEnvelope() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let findingID = try Support.findingID(report, "cross-host-duplicate", "stale-docs-cleanup")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        #expect(batch.status == .proposed)
        #expect(batch.snapshotID == nil)
        #expect(batch.id == "batch-fixed")
        let expectedDate = ISO8601DateFormatter().string(from: Support.fixedDate)
        #expect(batch.createdAt == expectedDate)
        let reference = try #require(batch.findingRefs.only)
        #expect(reference.findingID == findingID)
        #expect(reference.ruleID == "cross-host-duplicate")
        #expect(reference.skillName == "stale-docs-cleanup")
        let matchesScan = report.findings.contains {
            $0.ruleID == reference.ruleID && $0.skillName == reference.skillName
                && $0.workspaceID == reference.workspaceID
        }
        #expect(matchesScan)
        #expect(batch.decisions.only?.action == .update)
    }

    @Test("mixed decisions: leave is recorded but contributes no commands")
    func mixedLeaveAndAct() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let arbitrateID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let leaveID = try Support.findingID(report, "vercel-lock-drift", "stale-docs-cleanup")
        let batch = try Support.build(
            report,
            [Support.decide(arbitrateID, .arbitrate, .keepVercel), Support.decide(leaveID, .leave)])
        #expect(batch.decisions.count == 2)
        #expect(batch.findingRefs.count == 2)
        #expect(batch.commands.count == 1)
    }

    @Test("unknown finding IDs are rejected by name as unknown or stale")
    func unknownFindingID() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let problems = Support.problems(report, [Support.decide("bogus-rule:user:nope", .update)])
        let joined = problems.joined(separator: "\n")
        #expect(joined.contains("bogus-rule:user:nope"))
        #expect(joined.contains("unknown or stale"))
    }

    @Test("building twice with the same inputs is byte-deterministic")
    func determinism() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-1")
        let findingID = try Support.findingID(report, "cross-host-duplicate", "stale-docs-cleanup")
        let first = try Support.build(report, [Support.decide(findingID, .update)])
        let second = try Support.build(report, [Support.decide(findingID, .update)])
        #expect(try first.jsonData() == second.jsonData())
    }
}
