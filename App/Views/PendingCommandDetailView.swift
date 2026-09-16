import SukiruCore
import SwiftUI

/// The Pending Changes detail column: the per-command inspection view
/// (VAL-REPAIR-006/047). Shows the selected command's COMPLETE argument
/// vector — one argument per line, nothing elided — plus intent, owning
/// CLI, danger flags with their warning, consequence text, at-risk skills,
/// and the working directory the command runs in.
struct PendingCommandDetailView: View {
    @EnvironmentObject private var state: AppState

    /// The selected command with its index, nil when nothing valid is
    /// selected.
    private var selection: (index: Int, command: BatchCommand)? {
        guard let batch = state.pendingBatch, let index = state.selectedCommandIndex,
            batch.commands.indices.contains(index)
        else { return nil }
        return (index, batch.commands[index])
    }

    var body: some View {
        Group {
            if let selection {
                detail(selection.command, index: selection.index)
            } else {
                DetailPlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ command: BatchCommand, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                argvSection(command, index: index)
                intentSection(command, index: index)
                if !command.dangerFlags.isEmpty {
                    dangerSection(command, index: index)
                }
                if let consequence = command.consequence {
                    consequenceSection(consequence, index: index)
                }
                if let workingDirectory = command.workingDirectory {
                    workdirSection(workingDirectory, index: index)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func argvSection(_ command: BatchCommand, index: Int) -> some View {
        DetailSection(token: "sukiru.pending.command.\(index).argv", title: "Full command") {
            // One argument per line: the full argv is inspectable with
            // nothing hidden (VAL-REPAIR-006).
            ForEach(Array(command.argv.enumerated()), id: \.offset) { pair in
                Text(pair.element)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(command.displayString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func intentSection(_ command: BatchCommand, index: Int) -> some View {
        DetailSection(token: "sukiru.pending.command.\(index).intent", title: "Intent") {
            Text(command.intent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dangerSection(_ command: BatchCommand, index: Int) -> some View {
        DetailSection(token: "sukiru.pending.command.\(index).danger", title: "Danger") {
            ForEach(command.dangerFlags, id: \.self) { flag in
                Text(flag.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            }
            if let warning = command.warning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !command.atRiskSkills.isEmpty {
                let named = command.atRiskSkills
                    .map { "\($0.skill) (\($0.ownership))" }
                    .joined(separator: ", ")
                Text(String(format: String(localized: "command.atRisk %@"), named))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func consequenceSection(_ consequence: String, index: Int) -> some View {
        DetailSection(
            token: "sukiru.pending.command.\(index).consequence", title: "Consequences"
        ) {
            Text(consequence)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func workdirSection(_ workingDirectory: String, index: Int) -> some View {
        DetailSection(
            token: "sukiru.pending.command.\(index).workdir", title: "Working directory"
        ) {
            Text(workingDirectory)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// A headed detail section carrying its D21 token on the heading row.
struct DetailSection<Content: View>: View {
    let token: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                AXToken(token: token)
                Text(title)
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            content
        }
    }
}
