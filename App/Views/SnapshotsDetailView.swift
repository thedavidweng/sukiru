import SukiruCore
import SwiftUI

/// The Snapshots detail column: selecting a batch row reveals its post-run
/// diff (VAL-REPAIR-046), and selecting a rollback event row reveals the
/// itemized restore record in the exact three-category vocabulary
/// (`restored-from-snapshot` / `deleted-batch-added` /
/// `unrestorable-with-reason` — VAL-REPAIR-036, D9; unrestorable items are
/// surfaced, never silently dropped).
///
/// An EMPTY diff is an explicit state, never an omitted section
/// (VAL-REPAIR-033): the pane renders `sukiru.snapshots.diff.empty` with a
/// "No changes" line.
struct SnapshotsDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let row = state.historyRows.first(where: { $0.id == state.selectedHistoryID }) {
                switch row {
                case .batch(let record):
                    batchDetail(record)
                case .rollback(let record):
                    rollbackDetail(record)
                }
            } else {
                DetailPlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - batch detail: commands + post-run diff

    private func batchDetail(_ record: ExecutionRecord) -> some View {
        Form {
            batchMetaSection(record)
            batchCommandsSection(record)
            diffSection(record)
        }
        .formStyle(.grouped)
    }

    private func batchMetaSection(_ record: ExecutionRecord) -> some View {
        Section {
            Text(record.batchID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(
                String(
                    format: String(localized: "snapshots.batchMeta %@ %@"),
                    record.startedAt, record.batchStatus.rawValue)
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        } header: {
            TokenSectionHeader(token: nil, title: "Batch")
        }
    }

    private func batchCommandsSection(_ record: ExecutionRecord) -> some View {
        Section {
            ForEach(record.commands, id: \.index) { command in
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.displayString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(command.status.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(command.status == .succeeded ? .green : .red)
                        if let exitCode = command.exitCode {
                            Text("exit \(exitCode)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        if let diagnostics = command.diagnostics {
                            Text(diagnostics)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            TokenSectionHeader(token: nil, title: "Commands", count: record.commands.count)
        }
    }

    /// The post-run diff (VAL-REPAIR-032/033). The engine's `summary` is the
    /// human-readable rendering — one line per entry, and exactly one
    /// explicit "No changes…" line when empty — so it is rendered verbatim.
    @ViewBuilder
    private func diffSection(_ record: ExecutionRecord) -> some View {
        if record.diff.isEmpty {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AXToken(token: "sukiru.snapshots.diff.empty")
                    Image(systemName: "equal.circle")
                        .foregroundStyle(.secondary)
                    Text("No changes — the executed batch left the library unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            } header: {
                TokenSectionHeader(token: nil, title: "Post-run diff")
            }
        } else {
            Section {
                ForEach(Array(record.diff.summary.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                TokenSectionHeader(
                    token: "sukiru.snapshots.diff.\(record.batchID)", title: "Post-run diff",
                    count: record.diff.summary.count)
            }
        }
    }

    // MARK: - rollback detail: itemized restore record

    private func rollbackDetail(_ record: RollbackRecord) -> some View {
        Form {
            Section {
                Text(record.rolledBackAt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                ForEach(Array(record.items.enumerated()), id: \.offset) { pair in
                    let item = pair.element
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(for: item.category))
                            .foregroundStyle(color(for: item.category))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.category.rawValue)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(color(for: item.category))
                            Text(item.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let reason = item.reason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                TokenSectionHeader(
                    token: "sukiru.snapshots.rollbackDetail.\(record.batchID)",
                    title: "Rollback", count: record.items.count)
            }
        }
        .formStyle(.grouped)
    }

    private func icon(for category: RestoreItem.Category) -> String {
        switch category {
        case .restoredFromSnapshot: return "arrow.counterclockwise.circle"
        case .deletedBatchAdded: return "trash.circle"
        case .unrestorableWithReason: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for category: RestoreItem.Category) -> Color {
        switch category {
        case .restoredFromSnapshot: return .green
        case .deletedBatchAdded: return .blue
        case .unrestorableWithReason: return .red
        }
    }
}
