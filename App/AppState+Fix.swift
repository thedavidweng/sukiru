import Foundation
import SukiruCore

/// One-click repairs: Health problems grouped by kind, Fix / Fix All, the
/// Library's link ↔ copy switch, and orphan adoption or deletion. Every
/// intent builds one batch and opens the batch confirmation; nothing runs
/// before the user confirms it (snapshot + rollback stay in place).
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

    /// Builds one batch repairing every given finding that has a one-click
    /// fix. Repairs that turn out not to apply are listed in the
    /// confirmation instead of blocking the rest.
    func fix(_ entries: [FindingEntry]) {
        guard let report else { return }
        let ids = Dictionary(grouping: FindingID.assignments(for: report.findings)) {
            FindingID.baseID(for: $0.finding)
        }
        let decisions = entries.compactMap { entry -> DecisionEntry? in
            guard let action = oneClickFix(for: entry.finding),
                let id = ids[FindingID.baseID(for: entry.finding)]?
                    .first(where: { $0.finding == entry.finding })?.id
            else { return nil }
            return DecisionEntry(findingID: id, action: action)
        }
        let built = CommandBatchBuilder().buildApplicable(report: report, decisions: decisions)
        propose(built.batch, skipped: built.skipped)
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

    /// Deletes an orphan skill (snapshot-protected file operations).
    func deleteOrphan(_ skill: Skill) {
        decide(.cleanup, choice: nil, on: skill)
    }

    /// Opens the source picker for an orphan and starts looking up
    /// skills.sh listings with its name.
    func findSource(for skill: Skill) {
        sourceSheetSkill = skill
        loadSourceSuggestions(for: skill)
    }

    /// Hands an orphan to `npx skills` from the chosen source, so it gains
    /// a lock entry and can be updated.
    func adoptOrphan(_ skill: Skill, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sourceSheetSkill = nil
        decide(.adopt, choice: .adoptVercel(source: trimmed), on: skill)
    }

    private func decide(_ action: DecisionAction, choice: DecisionChoice?, on skill: Skill) {
        guard let report, let finding = orphanFinding(for: skill),
            let id = FindingID.assignments(for: report.findings)
                .first(where: { $0.finding == finding })?.id
        else { return }
        let entry = DecisionEntry(findingID: id, action: action, choice: choice)
        let built = CommandBatchBuilder().buildApplicable(report: report, decisions: [entry])
        propose(built.batch, skipped: built.skipped)
    }

    /// Opens the batch confirmation for a freshly built batch (or for the
    /// reasons nothing could be built).
    private func propose(_ batch: CommandBatch?, skipped: [String]) {
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

    // MARK: - orphan sources

    /// skills.sh listings carrying the orphan's exact name: likely sources.
    private func loadSourceSuggestions(for skill: Skill) {
        sourceSuggestions = nil
        let client = SkillsDotShSearchClient(transport: URLSessionMarketplaceTransport())
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = (try? await client.search(query: skill.name)) ?? []
            let matches = results.filter { $0.name == skill.name && $0.repo != nil }
            await MainActor.run {
                guard let self, self.sourceSheetSkill == skill else { return }
                self.sourceSuggestions = matches
            }
        }
    }
}
