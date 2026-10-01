import Foundation
import SukiruCore

/// Repair-surface state derivations and intents (M4, seam B): the Health →
/// Pending Changes deep-link (D16, VAL-CROSS-006), the per-ownership decision
/// set with capability gating (§8, VAL-REPAIR-049), batch construction via
/// `CommandBatchBuilder`, the single batch confirmation (VAL-REPAIR-007),
/// serialized in-app execution through `CLIExecutor`,
/// one-click rollback through `Rollback`, and the on-disk batch history that
/// backs the Snapshots surface.
///
/// Views stay dumb: they render `pendingBatch` / `historyRows` and dispatch
/// these intents. All writes go through SukiruCore (zero ledger red line).
@MainActor
extension AppState {
    /// A finding the user chose to repair (Health "Fix…"), carrying the D12
    /// finding ID minted from the CURRENT report — the same ID space the
    /// batch builder validates against, so a stale draft fails naturally
    /// (VAL-REPAIR-056).
    struct RepairDraft: Equatable {
        let findingID: String
        let finding: Finding
    }

    /// Why a repair decision is unavailable in this environment (§8
    /// degradation, VAL-REPAIR-049). The view layer renders the hint text.
    enum RepairBlock: Equatable {
        /// The decision needs `npx skills`, which is not resolvable.
        case needsNode
        /// The decision needs `gh` (≥ 2.90.0), which is unavailable.
        case needsGitHub
    }

    /// One repair decision offered for a finding, with its availability.
    struct RepairOption: Equatable, Identifiable {
        let action: DecisionAction
        /// Non-nil when the required CLI is missing — the option renders as
        /// an explanatory hint instead of an actionable button.
        let blocked: RepairBlock?

        var id: String { action.rawValue }
    }

    // MARK: - Health → Pending deep-link (D16, VAL-CROSS-006)

    /// Starts the repair flow for a finding: mints its D12 ID against the
    /// current report and opens the decision panel in Pending Changes. For a
    /// double-booked finding no batch exists until the arbitration choice is
    /// made — the decision panel enforces that order.
    func beginRepair(for finding: Finding) {
        guard let report,
            let match = FindingID.assignments(for: report.findings)
                .first(where: { $0.finding == finding })
        else { return }
        repairDraft = RepairDraft(findingID: match.id, finding: finding)
        repairError = nil
        repairBlockNotice = nil
        lastExecutionRecord = nil
        lastExecutionFailure = nil
        showingArbitrationSheet = false
        showingAdoptSheet = false
        adoptRepo = ""
        adoptPath = ""
        surface = .pending
    }

    /// The skill the draft's finding implicates (nil when the finding names
    /// no on-disk skill — e.g. a lock-without-files ghost).
    func repairDraftSkill() -> Skill? {
        guard let draft = repairDraft else { return nil }
        return skill(matching: draft.finding)
    }

    // MARK: - decision set + capability gating (§8, VAL-REPAIR-049)

    /// The decisions applicable to a finding, ownership-routed exactly like
    /// `CommandBatchBuilder` (architecture §6): vercel/github get update +
    /// cleanup, double-booked gets arbitration only, ownerless (and
    /// ambiguous, attribution voided) get adopt/cleanup/leave. A decision
    /// whose owning CLI is unavailable is `blocked` — never offered as an
    /// action, so no unbuildable batch can be constructed.
    func repairOptions(for finding: Finding) -> [RepairOption] {
        guard let skill = skill(matching: finding) else { return [] }
        // Optimistic while the background probes are in flight (nil): the
        // common case is "available", and a genuinely missing CLI still
        // fails loudly at execution (VAL-REPAIR-039) — but once settled, a
        // missing capability blocks construction up front (VAL-REPAIR-049).
        let npxResolvable = capabilities?.npx.resolvable ?? true
        let ghAvailable = capabilities?.github.available ?? true
        let needsNode: RepairBlock? = npxResolvable ? nil : .needsNode
        let needsGitHub: RepairBlock? = ghAvailable ? nil : .needsGitHub
        func option(_ action: DecisionAction, _ block: RepairBlock?) -> RepairOption {
            RepairOption(action: action, blocked: block)
        }
        if skill.ambiguous {
            // Attribution voided (D23): the ownerless decision set only.
            return [
                option(.adopt, needsGitHub),
                option(.cleanup, nil),
                option(.leave, nil)
            ]
        }
        switch skill.ownership {
        case .vercel:
            // Update AND removal both go through `npx skills` (gh has no
            // remove command), so both need Node. Relinking host copies is
            // a snapshot-protected file operation needing no CLI.
            var options = [option(.update, needsNode)]
            if ProblemKind.oneClickFix(for: finding) == .relink {
                options.append(option(.relink, nil))
            }
            return options + [option(.cleanup, needsNode), option(.leave, nil)]
        case .github:
            return [
                option(.update, needsGitHub),
                option(.cleanup, needsNode),
                option(.leave, nil)
            ]
        case .doubleBooked:
            // Both D10 arbitration paths start with an `npx skills` command;
            // keep-github additionally needs gh (gated inside the sheet).
            return [
                option(.arbitrate, needsNode),
                option(.leave, nil)
            ]
        case .ownerless:
            // Direct cleanup is a snapshot-protected file operation — it
            // needs NO CLI and stays available in every degraded environment.
            return [
                option(.adopt, needsGitHub),
                option(.cleanup, nil),
                option(.leave, nil)
            ]
        case .agent:
            // The agent's own ledger manages these; Sukiru only reports.
            return [option(.leave, nil)]
        }
    }

    /// The Health-row degradation hint (VAL-CROSS-014): non-nil when EVERY
    /// actionable repair of this finding needs a missing CLI — the row then
    /// says so inline instead of pretending a batch could be built.
    func repairBlockHint(for finding: Finding) -> RepairBlock? {
        guard capabilities != nil, skill(matching: finding) != nil else { return nil }
        let actionable = repairOptions(for: finding).filter { $0.action != .leave }
        guard !actionable.isEmpty, actionable.allSatisfy({ $0.blocked != nil }) else {
            return nil
        }
        return actionable.contains { $0.blocked == .needsNode } ? .needsNode : .needsGitHub
    }

    /// Whether a decision is currently choosable: a draft is open and the
    /// option exists and is not capability-blocked (Repair-menu enablement).
    func repairActionAvailable(_ action: DecisionAction) -> Bool {
        guard let draft = repairDraft else { return false }
        return repairOptions(for: draft.finding)
            .contains { $0.action == action && $0.blocked == nil }
    }

    // MARK: - decision dispatch

    /// Dispatches a chosen decision. `arbitrate` and `adopt` open their
    /// sheets (D10/D11 input collection); `leave` closes the draft without
    /// creating anything (VAL-REPAIR-019); `update`/`cleanup` build the
    /// batch immediately.
    func chooseRepair(_ action: DecisionAction) {
        guard let draft = repairDraft else { return }
        let blocked = repairOptions(for: draft.finding)
            .first(where: { $0.action == action })?.blocked
        if let blocked {
            // Defense in depth — the button is never rendered, but a menu
            // shortcut must refuse just as loudly (VAL-REPAIR-049).
            repairBlockNotice = blocked
            return
        }
        repairError = nil
        repairBlockNotice = nil
        switch action {
        case .leave:
            repairDraft = nil
        case .arbitrate:
            showingArbitrationSheet = true
        case .adopt:
            // D11: both inputs are user-supplied; never prefilled
            // (VAL-REPAIR-051).
            adoptRepo = ""
            adoptPath = ""
            showingAdoptSheet = true
        case .update, .cleanup, .relink:
            buildPendingBatch(action: action, choice: nil)
        }
    }

    /// Dismisses the decision panel without creating a batch.
    func cancelRepairDraft() {
        repairDraft = nil
        repairError = nil
        repairBlockNotice = nil
        showingArbitrationSheet = false
        showingAdoptSheet = false
    }

    /// D10: the arbitration sheet's explicit surviving-ledger choice. There
    /// is no default; dismissing the sheet creates no batch.
    func confirmArbitration(keepVercel: Bool) {
        showingArbitrationSheet = false
        if !keepVercel, capabilities?.github.available == false {
            // keep-github re-anchors through gh (D10); refuse up front when
            // gh is unavailable.
            repairBlockNotice = .needsGitHub
            return
        }
        buildPendingBatch(
            action: .arbitrate, choice: keepVercel ? .keepVercel : .keepGitHub)
    }

    /// D11: the adopt sheet's proceed action. Both inputs are required; the
    /// sheet's proceed control is disabled while either is empty, and this
    /// re-guards so a keyboard path cannot slip past.
    func confirmAdoption() {
        let repo = adoptRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = adoptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !path.isEmpty else { return }
        showingAdoptSheet = false
        buildPendingBatch(action: .adopt, choice: .adoptSource(repo: repo, path: path))
    }

    /// Builds the proposed batch from the draft decision against the CURRENT
    /// report. Construction problems (stale finding, ownership routing) are
    /// surfaced inline, never swallowed.
    private func buildPendingBatch(action: DecisionAction, choice: DecisionChoice?) {
        guard let draft = repairDraft, let report else { return }
        let entry = DecisionEntry(findingID: draft.findingID, action: action, choice: choice)
        do {
            if let batch = try CommandBatchBuilder().build(report: report, decisions: [entry]) {
                pendingBatch = batch
                repairDraft = nil
                repairError = nil
                repairBlockNotice = nil
                fixSkipped = []
                showingBatchConfirm = true
            } else {
                // All-leave decisions produce no batch (VAL-REPAIR-019).
                repairDraft = nil
            }
        } catch {
            repairError = UserFacingError.message(for: error)
        }
    }

    // MARK: - confirm + execute (VAL-REPAIR-007)

    /// A batch runs only from the batch confirmation, once per batch, and
    /// never while another mutation is in flight.
    var canExecutePendingBatch: Bool {
        pendingBatch != nil && !batchMutationInFlight
    }

    /// Executes the reviewed batch through the serialized CLIExecutor:
    /// snapshot → commands → post-run diff, off the main actor. On
    /// completion every surface auto-refreshes (D7 — the app initiated the
    /// mutation, so it rescans without waiting for explicit Refresh).
    func executePendingBatch() {
        guard let batch = pendingBatch, let report, canExecutePendingBatch,
            let reviewed = try? batch.transitioned(to: .reviewed)
        else { return }
        batchMutationInFlight = true
        lastExecutionFailure = nil
        let environment = Self.makeEnvironment(roots: projectRoots)
        let token = ProcessInfo.processInfo.environment["GH_TOKEN"]
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let executor = CLIExecutor(environment: environment, ghToken: token)
                let result = try executor.execute(batch: reviewed, report: report)
                await self?.finishExecution(record: result.record, failure: nil)
            } catch {
                await self?.finishExecution(
                    record: nil, failure: UserFacingError.message(for: error))
            }
        }
    }

    private func finishExecution(record: ExecutionRecord?, failure: String?) {
        batchMutationInFlight = false
        pendingBatch = nil
        lastExecutionRecord = record
        lastExecutionFailure = failure
        loadHistory()
        rescan()
    }

    // MARK: - rollback (D9, VAL-REPAIR-034/055)

    /// Whether a batch row currently offers rollback: succeeded/failed (not
    /// already rolled back) and no mutation in flight (VAL-REPAIR-055).
    func canRollback(batchID: String) -> Bool {
        guard !batchMutationInFlight else { return false }
        let row = historyRows.first(where: { $0.id == "batch-" + batchID })
        guard let row, case .batch(let record) = row else { return false }
        return record.batchStatus == .succeeded || record.batchStatus == .failed
    }

    /// The selected Snapshots row's rollback eligibility (keyboard menu).
    var canRollbackSelectedBatch: Bool {
        guard let selectedHistoryID, selectedHistoryID.hasPrefix("batch-") else {
            return false
        }
        return canRollback(batchID: String(selectedHistoryID.dropFirst("batch-".count)))
    }

    func rollbackSelectedBatch() {
        guard let selectedHistoryID, selectedHistoryID.hasPrefix("batch-") else { return }
        rollbackBatch(String(selectedHistoryID.dropFirst("batch-".count)))
    }

    /// One-click rollback (D9): restores the batch's pre-execution state
    /// from its snapshot, then auto-refreshes every surface (D7). Rollback
    /// takes the same cross-process execution lock as executions.
    func rollbackBatch(_ batchID: String) {
        guard canRollback(batchID: batchID) else { return }
        batchMutationInFlight = true
        rollbackError = nil
        let environment = Self.makeEnvironment(roots: projectRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try Rollback(environment: environment).rollback(batchID: batchID)
                await self?.finishRollback(failure: nil)
            } catch {
                await self?.finishRollback(failure: UserFacingError.message(for: error))
            }
        }
    }

    private func finishRollback(failure: String?) {
        batchMutationInFlight = false
        rollbackError = failure
        loadHistory()
        rescan()
    }
}
