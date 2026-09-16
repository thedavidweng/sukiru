import SukiruCore
import SwiftUI

/// The Pending Changes surface (architecture §4.3/§7): the Command Batch
/// safety model made visible.
///
/// - **Decision** — a Health "Fix…" deep-link (D16) opens the decision
///   panel (`RepairDraftPanel`): ownership-routed repair options, with
///   capability-blocked options rendered as hints (§8, VAL-REPAIR-049).
/// - **Review** — the proposed batch: one row per command with the full
///   argv (nothing elided, VAL-REPAIR-006), intent, owning-CLI badge, and
///   danger badges (`sukiru.pending.command.<i>.dangerBadge`,
///   VAL-REPAIR-008) plus a batch-level dangerous-deletion warning
///   (`sukiru.pending.dangerWarning`, VAL-REPAIR-022). Execute stays
///   disabled until EVERY command is acknowledged (VAL-REPAIR-007).
/// - **Result** — the terminal record banner (`PendingResultBanners`) while
///   the D7 auto-refresh repopulates every other surface.
struct PendingChangesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if hasContent {
                content
            } else {
                SurfacePlaceholder(
                    token: "sukiru.pending.empty",
                    icon: "list.bullet.rectangle",
                    title: "No pending changes",
                    explanation:
                        "Repairs arrive here as reviewable command batches — use a finding's Fix button in Health."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.showingArbitrationSheet) {
            ArbitrationSheet()
        }
        .sheet(isPresented: $state.showingAdoptSheet) {
            AdoptSheet()
        }
    }

    private var hasContent: Bool {
        state.repairDraft != nil || state.pendingBatch != nil
            || state.lastExecutionRecord != nil || state.lastExecutionFailure != nil
    }

    // MARK: - layout

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PendingResultBanners()
                    if let draft = state.repairDraft {
                        RepairDraftPanel(draft: draft)
                    }
                    if let batch = state.pendingBatch {
                        batchReview(batch)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AXToken(token: "sukiru.pending.title")
            Text("Pending Changes")
                .font(.headline)
            if state.batchMutationInFlight {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    AXToken(token: "sukiru.pending.executing")
                    Text("Working…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - batch review (VAL-REPAIR-006/007/008/022)

    private func batchReview(_ batch: CommandBatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.pending.batch")
                Text("Review every command, then execute")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            if batch.commands.contains(where: { !$0.dangerFlags.isEmpty }) {
                dangerWarning(batch)
            }
            List(selection: $state.selectedCommandIndex) {
                ForEach(Array(batch.commands.enumerated()), id: \.offset) { pair in
                    commandRow(pair.element, index: pair.offset)
                        .tag(pair.offset)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: CGFloat(batch.commands.count) * 118, maxHeight: 400)
            executeBar
        }
    }

    /// The batch-level dangerous-deletion warning (VAL-REPAIR-022): visible
    /// BEFORE Execute is reachable, naming the cross-ledger blast radius
    /// (at-risk skills with their owning ledger, VAL-REPAIR-021).
    private func dangerWarning(_ batch: CommandBatch) -> some View {
        let atRisk = batch.commands.flatMap(\.atRiskSkills)
        let text: String
        if atRisk.isEmpty {
            text = String(localized: "pending.dangerWarning.generic")
        } else {
            let named = atRisk.map { "\($0.skill) (\($0.ownership))" }.joined(separator: ", ")
            text = String(format: String(localized: "pending.dangerWarning.atRisk %@"), named)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            AXToken(token: "sukiru.pending.dangerWarning")
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
    }

    private func commandRow(_ command: BatchCommand, index: Int) -> some View {
        let reviewed = state.reviewedCommands.contains(index)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AXToken(token: "sukiru.pending.command.\(index)")
                Text(String(format: String(localized: "Command %lld"), index + 1))
                    .font(.callout.weight(.semibold))
                cliBadge(command.owningCLI, index: index)
                if !command.dangerFlags.isEmpty {
                    dangerBadge(index: index)
                }
                Spacer()
                Button {
                    state.toggleCommandReview(index)
                } label: {
                    if reviewed {
                        Label("Reviewed", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("Mark as Reviewed")
                    }
                }
                .controlSize(.small)
                .axButtonToken("sukiru.pending.command.\(index).review")
            }
            // The complete invocation, wrapped but NEVER elided
            // (VAL-REPAIR-006).
            Text(command.displayString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(command.intent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = command.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let consequence = command.consequence {
                Text(consequence)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func cliBadge(_ cli: OwningCLI, index: Int) -> some View {
        let label: LocalizedStringKey =
            switch cli {
            case .vercel: "Vercel CLI (npx skills)"
            case .github: "GitHub CLI (gh)"
            case .file: "Direct file operation"
            }
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.pending.command.\(index).cli")
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.14), in: Capsule())
                .foregroundStyle(.blue)
        }
        .accessibilityElement(children: .contain)
    }

    /// VAL-REPAIR-008: danger-flagged commands render a badge distinct from
    /// ordinary rows; benign rows carry no such element at all.
    private func dangerBadge(index: Int) -> some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.pending.command.\(index).dangerBadge")
            Text("Danger")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.16), in: Capsule())
                .foregroundStyle(.red)
        }
        .accessibilityElement(children: .contain)
    }

    /// Execute is gated on per-command review (VAL-REPAIR-007): the control
    /// is disabled — with the `.disabled` AX suffix — until every command is
    /// acknowledged, and activating it earlier does nothing.
    private var executeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    state.executePendingBatch()
                } label: {
                    Text("Execute Batch")
                }
                .axButtonToken(
                    "sukiru.pending.execute", disabled: !state.canExecutePendingBatch
                )
                .disabled(!state.canExecutePendingBatch)
                Button {
                    state.discardPendingBatch()
                } label: {
                    Text("Discard Batch")
                }
                .axButtonToken(
                    "sukiru.pending.discard", disabled: state.batchMutationInFlight
                )
                .disabled(state.batchMutationInFlight)
            }
            if !state.allCommandsReviewed {
                Text("Review every command to enable Execute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
