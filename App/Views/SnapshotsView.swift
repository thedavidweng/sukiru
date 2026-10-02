import SukiruCore
import SwiftUI

/// The Snapshots surface: the batch history. Every
/// executed batch appears as a row (`sukiru.snapshots.batch.<id>`) with its
/// status, command count, and post-run diff size; every rollback appears as
/// its own time-ordered event row (`sukiru.snapshots.event.rollback.<id>`),
/// so batch → rollback → re-repair reads as three distinct entries in order.
/// Non-rolled-back batches carry a one-click rollback
/// affordance (`sukiru.snapshots.rollback.<id>`), which
/// is unavailable while any execution or rollback is in flight.
/// The history is on-disk state — it survives relaunches
/// and reloads after every app-initiated mutation.
struct SnapshotsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
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
        .contextMenu(forSelectionType: String.self) { rowIDs in
            if !rowIDs.isEmpty {
                Button("Delete Snapshot…", role: .destructive) {
                    state.historyPendingDeletion = batchIDs(rowIDs)
                }
                .disabled(state.batchMutationInFlight)
            }
        }
        .onDeleteCommand {
            if let selected = state.selectedHistoryID, !state.batchMutationInFlight {
                state.historyPendingDeletion = batchIDs([selected])
            }
        }
        .confirmationDialog(
            "Delete Snapshot?",
            isPresented: Binding(
                get: { !state.historyPendingDeletion.isEmpty },
                set: { if !$0 { state.historyPendingDeletion = [] } })
        ) {
            Button("Delete", role: .destructive) {
                state.deleteHistory(batchIDs: state.historyPendingDeletion)
            }
        } message: {
            Text("snapshots.delete.message")
        }
        .overlay {
            if state.historyRows.isEmpty {
                SurfacePlaceholder(
                    token: "sukiru.snapshots.empty",
                    icon: "camera.on.rectangle",
                    title: "No snapshots yet",
                    explanation:
                        "Every command batch captures a snapshot before it runs; history appears here."
                )
            }
        }
        // Reloading is the window toolbar's Refresh, so the surface only
        // adds a bar when something is running or went wrong.
        .surfaceBar {
            if state.batchMutationInFlight {
                progressBanner
            }
            if let error = state.rollbackError {
                rollbackErrorBanner(error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressBanner: some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.pending.executing")
            ProgressView()
                .controlSize(.small)
            Text("Applying changes…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// A rollback row shares its batch's record, so it deletes that batch.
    private func batchIDs(_ rowIDs: Set<String>) -> Set<String> {
        Set(state.historyRows.filter { rowIDs.contains($0.id) }.map(\.batchID))
    }

    // MARK: - rows

    private func batchRow(_ record: ExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AXToken(token: "sukiru.snapshots.batch.\(record.batchID)")
                statusLabel(record.batchStatus)
                Text(commandsSummary(record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                // One-click rollback for every non-rolled-back batch;
                // unavailable mid-mutation (disabled with
                // the `.disabled` AX suffix, never silently inert).
                if record.batchStatus == .succeeded || record.batchStatus == .failed {
                    Button {
                        state.rollbackBatch(record.batchID)
                    } label: {
                        Label("Roll Back", systemImage: "arrow.uturn.backward")
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
                Text(RecordTimestamp.display(record.startedAt))
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
            Text("snapshots.rollbackCounts \(restored) \(deleted) \(unrestorable)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(RecordTimestamp.display(record.rolledBackAt))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func statusLabel(_ status: BatchStatus) -> some View {
        let (symbol, color): (String, Color) =
            switch status {
            case .succeeded: ("checkmark.circle.fill", .green)
            case .failed: ("xmark.octagon.fill", .red)
            case .rolledBack: ("arrow.uturn.backward.circle.fill", .purple)
            case .proposed, .reviewed, .executing: ("clock.fill", .blue)
            }
        return Label {
            Text(status.title)
                .font(.callout.weight(.medium))
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private func commandsSummary(_ record: ExecutionRecord) -> String {
        String(localized: "snapshots.commandCount \(record.commands.count)")
    }

    private func diffSummary(_ diff: BatchDiff) -> String {
        if diff.isEmpty {
            return String(localized: "snapshots.diffSummary.empty")
        }
        return String(localized: "snapshots.diffSummary \(diff.entries.count)")
    }
}
