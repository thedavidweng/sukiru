import SukiruCore
import SwiftUI

/// The single confirmation every batch needs before it runs: what will
/// change in plain words, the exact commands one click away, then progress
/// and the result with Undo. A snapshot is taken before the first command,
/// so a confirmed batch stays reversible (ADR-0007).
struct BatchConfirmSheet: View {
    @EnvironmentObject private var state: AppState
    /// The window-level rollback confirmation cannot present over this
    /// sheet, so Undo confirms here.
    @State private var confirmingUndo = false

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
            skillsDownloadNotice(batch)
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
            proposalButtons
        }
    }

    /// Confirming is what downloads a skills CLI not yet on this Mac, so the
    /// sheet says so before the user agrees.
    @ViewBuilder private func skillsDownloadNotice(_ batch: CommandBatch) -> some View {
        let runsSkills = batch.commands.contains { $0.argv.starts(with: ["npx", "skills"]) }
        if runsSkills && state.capabilities?.npx.reason == .notDownloaded {
            Label {
                Group {
                    if let version = state.skillsLatestVersion {
                        Text("confirm.downloadsSkillsCLI \(version)")
                    } else {
                        Text("confirm.downloadsSkillsCLI")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .font(.callout)
        }
    }

    private var proposalButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                state.dismissBatchConfirm()
            }
            .keyboardShortcut(.cancelAction)
            .axButtonToken("sukiru.confirm.cancel")
            // No count: one command can update several skills, so a command
            // count would disagree with the summary above.
            Button("Apply") {
                state.executePendingBatch()
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
                    Button("Undo…") {
                        confirmingUndo = true
                    }
                    .disabled(!state.canRollback(batchID: record.batchID))
                    .axButtonToken("sukiru.confirm.undo")
                    .confirmationDialog("Roll Back This Batch?", isPresented: $confirmingUndo) {
                        Button("Roll Back", role: .destructive) {
                            state.rollbackBatch(record.batchID)
                            state.dismissBatchConfirm()
                        }
                    } message: {
                        Text("snapshots.rollback.message")
                    }
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
        case removeLeftover, remove, install, reinstall, pin, unpin, update

        init(_ command: BatchCommand) {
            if let operation = command.fileOperation {
                self = Self.fileOperation(
                    operation,
                    discardsLocalChanges: command.dangerFlags.contains(
                        .discardsLocalChanges))
            } else {
                self = Self.cliCommand(command)
            }
        }

        private static func fileOperation(
            _ operation: FileOperation, discardsLocalChanges: Bool
        ) -> Kind {
            switch operation {
            case .deleteLink: .deleteLink
            case .relink: discardsLocalChanges ? .relinkDiverged : .relink
            case .materialize: .materialize
            case .deleteDirectory: .deleteDirectory
            case .removeLeftoverSkillsDir: .removeLeftover
            }
        }

        private static func cliCommand(_ command: BatchCommand) -> Kind {
            switch command.consequenceKind {
            case .pinsGitHubSkill: return .pin
            case .unpinsAndUpdates: return .unpin
            default: break
            }
            switch (command.argv.first, command.argv.dropFirst(2).first) {
            case ("npx", "remove"): return .remove
            // A forced gh install re-anchors a skill already on disk
            // (Restore Files, adoption, keep-GitHub arbitration).
            case ("gh", "install") where command.argv.contains("--force"): return .reinstall
            case ("npx", "add"), ("gh", "install"): return .install
            default: return .update
            }
        }

        /// One update or unpin command can name several skills.
        var countsNames: Bool { self == .update || self == .unpin }

        func line(_ count: Int) -> String {
            fileOperationLine(count) ?? cliCommandLine(count)
        }

        private func fileOperationLine(_ count: Int) -> String? {
            switch self {
            case .deleteLink: String(localized: "summary.deleteLink \(count)")
            case .relink: String(localized: "summary.relink \(count)")
            case .relinkDiverged: String(localized: "summary.relinkDiverged \(count)")
            case .materialize: String(localized: "summary.materialize \(count)")
            case .deleteDirectory: String(localized: "summary.deleteDirectory \(count)")
            case .removeLeftover: String(localized: "summary.removeLeftover \(count)")
            default: nil
            }
        }

        private func cliCommandLine(_ count: Int) -> String {
            switch self {
            case .remove: String(localized: "summary.remove \(count)")
            case .install: String(localized: "summary.install \(count)")
            case .reinstall: String(localized: "summary.reinstall \(count)")
            case .pin: String(localized: "summary.pin \(count)")
            case .unpin: String(localized: "summary.unpin \(count)")
            default: String(localized: "summary.update \(count)")
            }
        }
    }

    let lines: [String]

    init(_ batch: CommandBatch) {
        var counts: [Kind: Int] = [:]
        var order: [Kind] = []
        for command in batch.commands {
            let kind = Kind(command)
            if counts[kind] == nil {
                order.append(kind)
            }
            let names = command.argv.dropFirst(3).prefix { !$0.hasPrefix("-") }.count
            counts[kind, default: 0] += kind.countsNames ? max(names, 1) : 1
        }
        lines = order.map { $0.line(counts[$0] ?? 0) }
    }
}
