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
            contextMenu(batchIDs(rowIDs))
        }
        .onDeleteCommand {
            if let selected = state.selectedHistoryID, !state.batchMutationInFlight {
                state.historyPendingDeletion = batchIDs([selected])
            }
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

    /// A rollback row shares its batch's record, so it acts on that batch.
    private func batchIDs(_ rowIDs: Set<String>) -> Set<String> {
        Set(state.historyRows.filter { rowIDs.contains($0.id) }.map(\.batchID))
    }

    @ViewBuilder private func contextMenu(_ batchIDs: Set<String>) -> some View {
        if let batchID = batchIDs.first, batchIDs.count == 1 {
            if state.canRollback(batchID: batchID) {
                Button("Roll Back…") {
                    state.requestRollback(batchID)
                }
            }
            Button("Show in Finder") {
                state.revealHistory(batchID: batchID)
            }
            Button("Copy Batch ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(batchID, forType: .string)
            }
            Divider()
        }
        if !batchIDs.isEmpty {
            Button("Delete Snapshot…", role: .destructive) {
                state.historyPendingDeletion = batchIDs
            }
            .disabled(state.batchMutationInFlight)
        }
    }

    // MARK: - rows

    private func batchRow(_ record: ExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AXToken(token: "sukiru.snapshots.batch.\(record.batchID)")
                statusLabel(record.batchStatus)
                    .fixedSize()
                Text(commandsSummary(record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Rollback for every non-rolled-back batch, and deletion for
                // every batch, both confirmed first; unavailable mid-mutation
                // (disabled with the `.disabled` AX suffix, never silently
                // inert).
                if record.batchStatus == .succeeded || record.batchStatus == .failed {
                    Button {
                        state.requestRollback(record.batchID)
                    } label: {
                        Label("Roll Back…", systemImage: "arrow.uturn.backward")
                    }
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                    .help("Roll Back…")
                    .axButtonToken(
                        "sukiru.snapshots.rollback.\(record.batchID)",
                        disabled: state.batchMutationInFlight
                    )
                    .disabled(state.batchMutationInFlight)
                }
                Button(role: .destructive) {
                    state.historyPendingDeletion = [record.batchID]
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Delete Snapshot…")
                .axButtonToken(
                    "sukiru.snapshots.delete.\(record.batchID)",
                    disabled: state.batchMutationInFlight
                )
                .disabled(state.batchMutationInFlight)
            }
            HStack(spacing: 8) {
                Text(RecordTimestamp.display(record.startedAt))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Text(diffSummary(record.diff))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func rollbackRow(_ record: RollbackRecord) -> some View {
        let restored = record.items.filter { $0.category == .restoredFromSnapshot }.count
        let deleted = record.items.filter { $0.category == .deletedBatchAdded }.count
        let unrestorable = record.items.filter { $0.category == .unrestorableWithReason }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AXToken(token: "sukiru.snapshots.event.rollback.\(record.batchID)")
                Label {
                    Text("Rolled back")
                        .font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(unrestorable > 0 ? .orange : .purple)
                }
            }
            HStack(spacing: 8) {
                Text(RecordTimestamp.display(record.rolledBackAt))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Text("snapshots.rollbackCounts \(restored) \(deleted) \(unrestorable)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
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
