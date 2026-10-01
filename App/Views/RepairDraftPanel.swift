import SukiruCore
import SwiftUI

/// The repair decision panel (D16 deep-link target, VAL-CROSS-006): the
/// ownership-routed repair options for one finding
/// (`sukiru.pending.decision.<action>`). Options whose owning CLI is
/// unavailable in this environment render as explicit hints
/// (`sukiru.pending.hint.needsNode` / `sukiru.pending.hint.needsGH`), never
/// as buttons that would build a doomed batch (§8, VAL-REPAIR-049).
struct RepairDraftPanel: View {
    @EnvironmentObject private var state: AppState
    let draft: AppState.RepairDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.pending.decision.prompt")
                Text("Choose a repair for this finding")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            Text(draftSummary)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(state.repairOptions(for: draft.finding)) { option in
                if let blocked = option.blocked {
                    RepairBlockedHint(block: blocked, action: option.action)
                } else {
                    Button {
                        state.chooseRepair(option.action)
                    } label: {
                        Text(option.action.title)
                    }
                    .axButtonToken("sukiru.pending.decision.\(option.action.rawValue)")
                }
            }
            Button {
                state.cancelRepairDraft()
            } label: {
                Text("Cancel")
            }
            .axButtonToken("sukiru.pending.decision.cancel")
        }
    }

    private var draftSummary: String {
        let finding = draft.finding
        let name = finding.skillName ?? "-"
        return "\(finding.ruleID) — \(name) — \(finding.workspaceID)"
    }

}

extension DecisionAction {
    var title: LocalizedStringResource {
        switch self {
        case .update: "Update via Owning CLI"
        case .cleanup: "Clean Up"
        case .relink: "Link to Shared Copy"
        case .adopt: "Adopt into GitHub Ledger…"
        case .arbitrate: "Choose Surviving Ledger…"
        case .leave: "Leave As-Is"
        }
    }
}

/// §8 degradation hint (VAL-REPAIR-049): a repair whose owning CLI is
/// missing is refused UP FRONT with a clear, localized explanation — no
/// batch is ever built. Renders both per-decision (in the draft panel) and
/// as a banner when a menu shortcut hit a blocked decision.
struct RepairBlockedHint: View {
    let block: AppState.RepairBlock
    /// The blocked decision, nil for the banner form (generic copy).
    let action: DecisionAction?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AXToken(
                token: block == .needsNode
                    ? "sukiru.pending.hint.needsNode" : "sukiru.pending.hint.needsGH")
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        let actionName = action.map { String(localized: $0.title) }
        switch (block, actionName) {
        case (.needsNode, .some(let name)):
            return String(localized: "pending.hint.needsNode \(name)")
        case (.needsGitHub, .some(let name)):
            return String(localized: "pending.hint.needsGH \(name)")
        case (.needsNode, .none):
            return String(localized: "pending.hint.needsNodeGeneric")
        case (.needsGitHub, .none):
            return String(localized: "pending.hint.needsGHGeneric")
        }
    }
}

/// The Pending Changes banners: construction refusals
/// (`sukiru.pending.buildError`), capability blocks (RepairBlockedHint), and
/// the terminal execution result (`sukiru.pending.result.succeeded` /
/// `.failed` — the latter naming the failed command's diagnostics so a
/// missing CLI or non-zero exit is never silent, VAL-REPAIR-039…042).
struct PendingResultBanners: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let failure = state.lastExecutionFailure {
            banner(
                token: "sukiru.pending.result.failed", icon: "xmark.octagon.fill",
                color: .red, text: failure)
        }
        if let record = state.lastExecutionRecord {
            resultBanner(record)
        }
        if let error = state.repairError {
            banner(
                token: "sukiru.pending.buildError", icon: "exclamationmark.triangle.fill",
                color: .orange, text: error)
        }
        if let block = state.repairBlockNotice {
            RepairBlockedHint(block: block, action: nil)
        }
    }

    private func resultBanner(_ record: ExecutionRecord) -> some View {
        Group {
            switch record.batchStatus {
            case .succeeded:
                banner(
                    token: "sukiru.pending.result.succeeded",
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: String(
                        localized:
                            "Batch executed — the post-run diff is listed in Snapshots."))
            default:
                banner(
                    token: "sukiru.pending.result.failed",
                    icon: "xmark.octagon.fill",
                    color: .red,
                    text: failedSummary(record))
            }
        }
    }

    private func failedSummary(_ record: ExecutionRecord) -> String {
        let failed = record.commands.filter { $0.status != .succeeded }
        guard let first = failed.first else {
            let status = String(localized: record.batchStatus.title)
            return String(localized: "pending.result.failed \(status)")
        }
        let detail = first.diagnostics ?? String(localized: first.status.title)
        return String(localized: "pending.result.failedCommand \(first.index + 1) \(detail)")
    }

    private func banner(
        token: String, icon: String, color: Color, text: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AXToken(token: token)
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
    }
}
