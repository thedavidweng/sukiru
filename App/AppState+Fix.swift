import Foundation
import SukiruCore

/// One-click repairs: Health problems grouped by kind, Fix / Fix All, the
/// Library's link ↔ copy switch, and orphan adoption or deletion. Health
/// repairs queue in the cart (`AppState+Cart`); the mode switch builds its
/// batch at once. Nothing runs before the user confirms a batch (snapshot +
/// rollback stay in place).
@MainActor
extension AppState {
    /// The visible findings of one problem kind, in report order.
    struct ProblemGroup: Identifiable {
        let kind: ProblemKind
        let entries: [FindingEntry]

        var id: String { kind.rawValue }
    }

    /// The fix one click applies to a finding here: nil when the repair
    /// needs a choice, or needs `npx skills` and Node is missing.
    func oneClickFix(for finding: Finding) -> DecisionAction? {
        guard let action = ProblemKind.oneClickFix(for: finding) else { return nil }
        let needsNpx =
            action == .update || (action == .cleanup && finding.ruleID == "lock-without-files")
        if needsNpx && capabilities?.npx.canRunSkills == false {
            return nil
        }
        return action
    }

    func fixableEntries(_ entries: [FindingEntry]) -> [FindingEntry] {
        entries.filter { oneClickFix(for: $0.finding) != nil }
    }

    /// Fix All: queues every given one-click fix and checks out the whole
    /// cart, so repairs queued earlier join the same batch.
    func fixAll(_ entries: [FindingEntry]) {
        queueFixes(entries)
        checkout()
    }

    /// Library: switch every placement of a skill to links or copies.
    func switchMode(of skill: Skill, to mode: PlacementMode) {
        guard let report else { return }
        do {
            let batch = try CommandBatchBuilder().buildModeSwitch(
                skill: skill, to: mode, report: report)
            propose(batch, skipped: [])
        } catch let error as BatchBuildError {
            propose(nil, skipped: error.problems)
        } catch {
            propose(nil, skipped: [UserFacingError.message(for: error)])
        }
    }

    /// The `files-without-lock` finding that marks a skill as an orphan.
    func orphanFinding(for skill: Skill) -> Finding? {
        findingEntries(for: skill).map(\.finding).first { $0.ruleID == "files-without-lock" }
    }

    /// Queues an orphan's deletion (snapshot-protected file operations).
    func deleteOrphan(_ skill: Skill) {
        guard let finding = orphanFinding(for: skill) else { return }
        queue(.cleanup, for: finding)
    }

    /// Queues handing an orphan to `npx skills` from the chosen source, so
    /// it gains a lock entry and can be updated.
    func adoptOrphan(_ skill: Skill, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canAdoptFromSource, let finding = orphanFinding(for: skill)
        else { return }
        sourceSheetSkill = nil
        queue(.adopt, choice: .adoptVercel(source: trimmed), for: finding)
    }

    /// Opens the batch confirmation for a freshly built batch (or for the
    /// reasons nothing could be built).
    func propose(_ batch: CommandBatch?, skipped: [String]) {
        pendingBatch = batch
        fixSkipped = skipped
        repairDraft = nil
        repairError = nil
        repairBlockNotice = nil
        lastExecutionRecord = nil
        lastExecutionFailure = nil
        showingBatchConfirm = true
    }

    /// Closes the confirmation; an unexecuted batch is discarded.
    func dismissBatchConfirm() {
        showingBatchConfirm = false
        fixSkipped = []
        if !batchMutationInFlight {
            pendingBatch = nil
        }
    }
}
