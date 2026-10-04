import SukiruCore
import SwiftUI

struct RollbackConflictSheet: View {
    @EnvironmentObject private var state: AppState
    let preview: RollbackPreview
    @State private var choices: [String: RollbackChoice] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Rollback Conflicts").font(.headline)
            Text("rollback.conflicts.message").fixedSize(horizontal: false, vertical: true)
            if let failure = preview.fileEvidenceFailure {
                Text("rollback.recovery.message").fixedSize(horizontal: false, vertical: true)
                Text(verbatim: failure).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.conflicts, id: \.path) { conflict in
                        VStack(alignment: .leading) {
                            Text(verbatim: conflict.path).font(.caption.monospaced()).textSelection(
                                .enabled)
                            Text(conflict.kind.title).font(.caption).foregroundStyle(.secondary)
                            Picker(
                                "File action",
                                selection: Binding(
                                    get: { choices[conflict.path] },
                                    set: { choices[conflict.path] = $0 })
                            ) {
                                Text("Choose…").tag(nil as RollbackChoice?)
                                if conflict.canRestore {
                                    Text("Restore snapshot").tag(
                                        RollbackChoice.restore as RollbackChoice?)
                                }
                                Text("Preserve current file").tag(
                                    RollbackChoice.preserve as RollbackChoice?)
                            }
                            .accessibilityIdentifier("rollback.choice.\(conflict.path)")
                            .help("Choose how rollback handles this changed file.")
                        }
                    }
                }
            }.frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { state.rollbackReview = nil }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("rollback.cancel")
                    .help("Cancel rollback and keep current files.")
                Button("Roll Back", role: .destructive) {
                    state.rollbackBatch(preview.batchID, choices: choices)
                }
                .disabled(preview.conflicts.contains { choices[$0.path] == nil })
                .accessibilityIdentifier("rollback.confirm")
                .help("Roll back using the selected file actions.")
            }
        }.padding(24).frame(width: 600)
    }
}

extension RollbackConflict.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .modified: "Modified after execution"
        case .deleted: "Deleted after execution"
        case .added: "Added after execution"
        }
    }
}
