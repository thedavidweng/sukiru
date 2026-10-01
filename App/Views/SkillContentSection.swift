import SukiruCore
import SwiftUI

/// The raw SKILL.md, read off the main actor, as the last section of the
/// skill inspector.
struct SkillContentSection: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill
    @State private var content: String?
    @State private var readError: String?

    var body: some View {
        Section {
            Group {
                if let content {
                    Text(content)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else if let readError {
                    Label {
                        Text("Could not read SKILL.md")
                        Text(readError)
                    } icon: {
                        Image(systemName: "doc.badge.xmark")
                    }
                } else if state.skillMarkdownURL(for: skill) == nil {
                    Label("SKILL.md is unavailable", systemImage: "doc.badge.xmark")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading SKILL.md…")
                        .controlSize(.small)
                }
            }
        } header: {
            HStack {
                Text(verbatim: "SKILL.md")
                Spacer()
                Button("Quick Look") {
                    state.quickLookSelectedSkill()
                }
                .buttonStyle(.borderless)
                .axButtonToken(
                    "sukiru.library.quicklook",
                    disabled: state.skillMarkdownURL(for: skill) == nil
                )
                .disabled(state.skillMarkdownURL(for: skill) == nil)
                .help("Quick Look SKILL.md")
            }
        }
        .task(id: skill.selfID) {
            content = nil
            readError = nil
            guard let path = state.skillMarkdownURL(for: skill)?.path else { return }
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try String(contentsOfFile: path, encoding: .utf8)
                }.value
                if !Task.isCancelled { content = loaded }
            } catch {
                if !Task.isCancelled { readError = error.localizedDescription }
            }
        }
    }
}
