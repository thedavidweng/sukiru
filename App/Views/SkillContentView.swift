import SukiruCore
import SwiftUI

struct SkillContentView: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill
    @State private var content: String?
    @State private var readError: String?

    var body: some View {
        Group {
            if let content {
                ScrollView {
                    Text(content)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if let readError {
                ContentUnavailableView {
                    Label("Could not read SKILL.md", systemImage: "doc.badge.xmark")
                } description: {
                    Text(readError)
                }
            } else if state.skillMarkdownURL(for: skill) == nil {
                ContentUnavailableView("SKILL.md is unavailable", systemImage: "doc.badge.xmark")
            } else {
                ProgressView("Loading SKILL.md…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
