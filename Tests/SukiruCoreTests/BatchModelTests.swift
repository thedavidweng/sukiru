import Foundation
import Testing

@testable import SukiruCore

/// The CommandBatch wire model and its lifecycle state machine.
@Suite("CommandBatch model and lifecycle")
struct BatchModelTests {
    private func makeBatch(status: BatchStatus) -> CommandBatch {
        CommandBatch(
            id: "batch-1",
            createdAt: "2026-09-16T00:00:00Z",
            findingRefs: [],
            decisions: [],
            commands: [],
            snapshotID: nil,
            status: status
        )
    }

    // MARK: - legal transitions

    @Test("proposed → reviewed → executing → succeeded is the happy path")
    func happyPath() throws {
        let batch = makeBatch(status: .proposed)
        let reviewed = try batch.transitioned(to: .reviewed)
        #expect(reviewed.status == .reviewed)
        let executing = try reviewed.transitioned(to: .executing)
        #expect(executing.status == .executing)
        let succeeded = try executing.transitioned(to: .succeeded)
        #expect(succeeded.status == .succeeded)
    }

    @Test("executing may end failed; succeeded and failed can both roll back")
    func failureAndRollback() throws {
        let executing = try makeBatch(status: .reviewed).transitioned(to: .executing)
        let failed = try executing.transitioned(to: .failed)
        #expect(failed.status == .failed)
        #expect(try failed.transitioned(to: .rolledBack).status == .rolledBack)
        let rolledBack = try makeBatch(status: .succeeded).transitioned(to: .rolledBack)
        #expect(rolledBack.status == .rolledBack)
    }

    // MARK: - Terminal states are terminal; no rollback mid-execution

    @Test("terminal states refuse every further transition")
    func terminalStatesRefuse() {
        for terminal in [BatchStatus.succeeded, .failed, .rolledBack] {
            for target in BatchStatus.allCases where target != terminal {
                if terminal != .succeeded && terminal != .failed && target == .rolledBack {
                    continue
                }
                if target == .rolledBack && (terminal == .succeeded || terminal == .failed) {
                    continue
                }
                #expect(throws: BatchTransitionError.self) {
                    try makeBatch(status: terminal).transitioned(to: target)
                }
            }
        }
    }

    @Test("no rollback mid-execution and no skipping review")
    func illegalMidFlowTransitions() {
        #expect(throws: BatchTransitionError.self) {
            try makeBatch(status: .executing).transitioned(to: .rolledBack)
        }
        #expect(throws: BatchTransitionError.self) {
            try makeBatch(status: .proposed).transitioned(to: .executing)
        }
        #expect(throws: BatchTransitionError.self) {
            try makeBatch(status: .reviewed).transitioned(to: .succeeded)
        }
    }

    @Test("refusal error names the from and to states")
    func refusalNamesStates() {
        do {
            _ = try makeBatch(status: .rolledBack).transitioned(to: .executing)
            Issue.record("expected a BatchTransitionError")
        } catch let error as BatchTransitionError {
            #expect(error.message.contains("rolledBack"))
            #expect(error.message.contains("executing"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Wire shape starts proposed with explicit null snapshotID

    @Test("batch JSON carries snapshotID as an explicit null and status proposed")
    func wireShape() throws {
        let command = BatchCommand(
            argv: ["npx", "skills", "update", "tool", "-g", "-y"],
            displayString: "npx skills update tool -g -y",
            owningCLI: .vercel,
            intent: "Update 'tool' (finding cross-host-duplicate).",
            dangerFlags: [],
            warning: nil,
            atRiskSkills: [],
            consequence: nil
        )
        let decision = BatchDecision(
            findingID: "cross-host-duplicate:user:tool", action: .update, choice: nil)
        let batch = CommandBatch(
            id: "batch-1",
            createdAt: "2026-09-16T00:00:00Z",
            findingRefs: [
                FindingRef(
                    findingID: "cross-host-duplicate:user:tool",
                    ruleID: "cross-host-duplicate",
                    skillName: "tool",
                    workspaceID: "user")
            ],
            decisions: [decision],
            commands: [command],
            snapshotID: nil,
            status: .proposed
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: batch.jsonData()) as? [String: Any])
        #expect(object["status"] as? String == "proposed")
        #expect(object["snapshotID"] is NSNull, "snapshotID must be an explicit null key")
        #expect(object["id"] as? String == "batch-1")
        let commands = try #require(object["commands"] as? [[String: Any]])
        let first = try #require(commands.first)
        #expect(first["owningCLI"] as? String == "vercel")
        #expect(first["argv"] as? [String] == ["npx", "skills", "update", "tool", "-g", "-y"])
        #expect(first["dangerFlags"] as? [String] == [])
        #expect(first["intent"] is String)
        #expect(first["displayString"] is String)
    }

    @Test("display strings shell-quote arguments that need it")
    func displayQuoting() {
        let plain = ["npx", "skills", "update", "tool", "-g", "-y"]
        #expect(BatchCommand.display(for: plain) == "npx skills update tool -g -y")
        let spaced = ["gh", "skill", "update", "x", "--dir", "/tmp/my dir/skills"]
        #expect(BatchCommand.display(for: spaced) == "gh skill update x --dir '/tmp/my dir/skills'")
        #expect(BatchCommand.display(for: ["a", ""]) == "a ''")
    }
}
