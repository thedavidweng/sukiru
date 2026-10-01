import SukiruCore
import SwiftUI

/// The single confirmation every batch needs before it runs: what will
/// change in plain words, the exact commands one click away, then progress
/// and the result with Undo. A snapshot is taken before the first command,
/// so a confirmed batch stays reversible (ADR-0007).
struct BatchConfirmSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.batchMutationInFlight {
                running
            } else if let batch = state.pendingBatch {
                proposal(batch)
            } else if state.lastExecutionRecord != nil || state.lastExecutionFailure != nil {
                result
            } else {
                nothingToRun
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(state.batchMutationInFlight)
    }

    // MARK: - proposal

    private func proposal(_ batch: CommandBatch) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.confirm.title")
                Text("Review Changes")
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(BatchSummary(batch).lines, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle")
                }
            }
            if !batch.commands.allSatisfy({ $0.dangerFlags.isEmpty }) {
                Label {
                    Text("confirm.caution")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .font(.callout)
            }
            skippedList
            DisclosureGroup("Show Commands (\(batch.commands.count))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(batch.commands.enumerated()), id: \.offset) { pair in
                            commandLine(pair.element)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            Text("confirm.snapshot")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            proposalButtons(batch)
        }
    }

    private func proposalButtons(_ batch: CommandBatch) -> some View {
        HStack {
            Spacer()
            Button("Cancel") {
                state.dismissBatchConfirm()
            }
            .keyboardShortcut(.cancelAction)
            .axButtonToken("sukiru.confirm.cancel")
            Button {
                state.executePendingBatch()
            } label: {
                Text("Apply \(batch.commands.count) Changes")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canExecutePendingBatch)
            .axButtonToken("sukiru.confirm.apply", disabled: !state.canExecutePendingBatch)
        }
    }

    private func commandLine(_ command: BatchCommand) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary = command.fileOperation?.localizedSummary {
                Text(verbatim: summary)
                    .font(.caption.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: command.displayString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(command.reviewNotes, id: \.self) {
                Text(verbatim: $0)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !command.atRiskSkills.isEmpty {
                Text("command.atRisk \(command.atRiskList)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var skippedList: some View {
        if !state.fixSkipped.isEmpty {
            DisclosureGroup("Not included (\(state.fixSkipped.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("confirm.skipped.explanation")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(state.fixSkipped, id: \.self) { reason in
                        Text(verbatim: reason)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - running / result

    private var running: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            AXToken(token: "sukiru.confirm.running")
            Text("Applying changes…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            PendingResultBanners()
            HStack {
                if let record = state.lastExecutionRecord {
                    Button("Undo") {
                        state.rollbackBatch(record.batchID)
                        state.dismissBatchConfirm()
                    }
                    .disabled(!state.canRollback(batchID: record.batchID))
                    .axButtonToken("sukiru.confirm.undo")
                }
                Spacer()
                Button("Done") {
                    state.dismissBatchConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .axButtonToken("sukiru.confirm.done")
            }
        }
    }

    private var nothingToRun: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing to Change")
                .font(.headline)
            skippedList
            HStack {
                Spacer()
                Button("OK") {
                    state.dismissBatchConfirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Plain-language lines describing what a batch changes, counted by kind.
struct BatchSummary {
    private enum Kind: CaseIterable {
        case deleteLink, relink, relinkDiverged, materialize, deleteDirectory
        case remove, install, update

        init(_ command: BatchCommand) {
            if let operation = command.fileOperation {
                switch operation {
                case .deleteLink: self = .deleteLink
                case .relink:
                    self =
                        command.dangerFlags.contains(.discardsLocalChanges)
                        ? .relinkDiverged : .relink
                case .materialize: self = .materialize
                case .deleteDirectory: self = .deleteDirectory
                }
                return
            }
            switch (command.argv.first, command.argv.dropFirst(2).first) {
            case ("npx", "remove"): self = .remove
            case ("npx", "add"), ("gh", "install"): self = .install
            default: self = .update
            }
        }

        func line(_ count: Int) -> String {
            switch self {
            case .deleteLink: String(localized: "summary.deleteLink \(count)")
            case .relink: String(localized: "summary.relink \(count)")
            case .relinkDiverged: String(localized: "summary.relinkDiverged \(count)")
            case .materialize: String(localized: "summary.materialize \(count)")
            case .deleteDirectory: String(localized: "summary.deleteDirectory \(count)")
            case .remove: String(localized: "summary.remove \(count)")
            case .install: String(localized: "summary.install \(count)")
            case .update: String(localized: "summary.update \(count)")
            }
        }
    }

    let lines: [String]

    init(_ batch: CommandBatch) {
        var counts: [Kind: Int] = [:]
        var order: [Kind] = []
        for kind in batch.commands.map(Kind.init) {
            if counts[kind] == nil {
                order.append(kind)
            }
            counts[kind, default: 0] += 1
        }
        lines = order.map { $0.line(counts[$0] ?? 0) }
    }
}
