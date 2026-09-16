import SukiruCore
import SwiftUI

/// The Snapshots surface (architecture §4.3, D9): the batch history. Every
/// executed batch appears as a row (`sukiru.snapshots.batch.<id>`) with its
/// status, command count, and post-run diff size; every rollback appears as
/// its own time-ordered event row (`sukiru.snapshots.event.rollback.<id>`),
/// so batch → rollback → re-repair reads as three distinct entries in order
/// (VAL-CROSS-023). Non-rolled-back batches carry a one-click rollback
/// affordance (`sukiru.snapshots.rollback.<id>`, VAL-REPAIR-036/046), which
/// is unavailable while any execution or rollback is in flight
/// (VAL-REPAIR-055). The history is on-disk state — it survives relaunches
/// (VAL-CROSS-012) and reloads after every app-initiated mutation (D7).
struct SnapshotsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.historyRows.isEmpty {
                SurfacePlaceholder(
                    token: "sukiru.snapshots.empty",
                    icon: "camera.on.rectangle",
                    title: "No snapshots yet",
                    explanation:
                        "Every command batch captures a snapshot before it runs; history appears here."
                )
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            if let error = state.rollbackError {
                Divider()
                rollbackErrorBanner(error)
            }
            Divider()
            List(selection: $state.selectedHistoryID) {
                ForEach(state.historyRows) { row in
                    switch row {
                    case .batch(let record):
                        batchRow(record)
                            .tag(row.id)
                    case .rollback(let record):
                        rollbackRow(record)
                            .tag(row.id)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AXToken(token: "sukiru.snapshots.title")
            Text("Snapshots")
                .font(.headline)
            if state.batchMutationInFlight {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    AXToken(token: "sukiru.pending.executing")
                }
            }
            Spacer()
            Button {
                state.loadHistory()
            } label: {
                Text("Reload")
            }
            .axButtonToken("sukiru.snapshots.reload")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func rollbackErrorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AXToken(token: "sukiru.snapshots.rollbackError")
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: - rows

    private func batchRow(_ record: ExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AXToken(token: "sukiru.snapshots.batch.\(record.batchID)")
                statusBadge(record.batchStatus)
                Text(commandsSummary(record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                // One-click rollback (D9) for every non-rolled-back batch;
                // unavailable mid-mutation (VAL-REPAIR-055 — disabled with
                // the `.disabled` AX suffix, never silently inert).
                if record.batchStatus == .succeeded || record.batchStatus == .failed {
                    Button {
                        state.rollbackBatch(record.batchID)
                    } label: {
                        Text("Roll Back")
                    }
                    .controlSize(.small)
                    .axButtonToken(
                        "sukiru.snapshots.rollback.\(record.batchID)",
                        disabled: state.batchMutationInFlight
                    )
                    .disabled(state.batchMutationInFlight)
                }
            }
            HStack(spacing: 8) {
                Text(record.startedAt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Text(diffSummary(record.diff))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func rollbackRow(_ record: RollbackRecord) -> some View {
        let restored = record.items.filter { $0.category == .restoredFromSnapshot }.count
        let deleted = record.items.filter { $0.category == .deletedBatchAdded }.count
        let unrestorable = record.items.filter { $0.category == .unrestorableWithReason }.count
        return HStack(spacing: 8) {
            AXToken(token: "sukiru.snapshots.event.rollback.\(record.batchID)")
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(unrestorable > 0 ? .orange : .purple)
            Text("Rolled back")
                .font(.callout.weight(.medium))
            Text(
                String(
                    format: String(localized: "snapshots.rollbackCounts %lld %lld %lld"),
                    restored, deleted, unrestorable)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Text(record.rolledBackAt)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ status: BatchStatus) -> some View {
        let label: LocalizedStringKey =
            switch status {
            case .proposed: "Proposed"
            case .reviewed: "Reviewed"
            case .executing: "Executing"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .rolledBack: "Rolled Back"
            }
        let color: Color =
            switch status {
            case .succeeded: .green
            case .failed: .red
            case .rolledBack: .purple
            case .proposed, .reviewed, .executing: .blue
            }
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func commandsSummary(_ record: ExecutionRecord) -> String {
        String(
            format: String(localized: "snapshots.commandCount %lld"), record.commands.count)
    }

    private func diffSummary(_ diff: BatchDiff) -> String {
        if diff.isEmpty {
            return String(localized: "snapshots.diffSummary.empty")
        }
        return String(format: String(localized: "snapshots.diffSummary %lld"), diff.entries.count)
    }
}
