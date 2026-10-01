import SukiruCore
import SwiftUI

/// Finds a source for a skill no installer recorded: skills.sh listings with
/// the same name, or any `owner/repo` (or URL) the user knows. Adopting
/// reinstalls the skill through `npx skills`, so it gains a lock entry and
/// can be updated; the batch confirmation follows.
struct OrphanSourceSheet: View {
    @EnvironmentObject private var state: AppState
    let skill: Skill
    @State private var source = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find a Source for \(skill.name)")
                .font(.headline)
            Text("orphan.sheet.explanation")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            suggestions
            TextField("owner/repo or URL", text: $source)
                .textFieldStyle(.roundedBorder)
                .onSubmit(adoptTyped)
            HStack {
                Spacer()
                Button("Cancel") {
                    state.sourceSheetSkill = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Adopt", action: adoptTyped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
                    .axButtonToken("sukiru.orphan.adopt")
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder private var suggestions: some View {
        if let results = state.sourceSuggestions {
            if results.isEmpty {
                Text("No skills.sh listing uses this name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { result in
                        suggestionRow(result)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching skills.sh…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func suggestionRow(_ result: SkillSearchResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: result.repo ?? result.name)
                if let installs = result.installs {
                    Text("\(installs) installs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Use") {
                if let repo = result.repo {
                    state.adoptOrphan(skill, source: repo)
                }
            }
            .controlSize(.small)
        }
    }

    private func adoptTyped() {
        state.adoptOrphan(skill, source: source)
    }
}
