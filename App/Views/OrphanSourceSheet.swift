import SukiruCore
import SwiftUI

/// Finds a source for a skill no installer recorded: skills.sh listings with
/// the same name, each checked against the local `SKILL.md`, so the right
/// one is usually marked and one click away. Any `owner/repo` (or URL) the
/// user knows still works under Other Source. Choosing a source queues the
/// adoption in Pending Changes; adopting reinstalls the skill through
/// `npx skills`, so it gains a lock entry and can be updated.
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
            DisclosureGroup("Other Source") {
                TextField("owner/repo or URL", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(adoptTyped)
                    .padding(.top, 4)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    state.sourceSheetSkill = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Queue Adoption", action: adoptTyped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
                    .axButtonToken("sukiru.orphan.adopt")
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder private var suggestions: some View {
        switch state.sourceLookup(for: skill) {
        case .found(let candidates) where candidates.isEmpty:
            Text("No skills.sh listing uses this name.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .found(let candidates):
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .frame(maxHeight: 240)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .searching, nil:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching skills.sh…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func candidateRow(_ candidate: SourceCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: candidate.result.repo ?? candidate.result.name)
                HStack(spacing: 6) {
                    matchLabel(candidate.match)
                    if let installs = candidate.result.installs {
                        Text("\(installs) installs")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button("Use") {
                state.adoptOrphan(skill, source: candidate.installSource)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func matchLabel(_ match: SourceCandidate.Match) -> some View {
        switch match {
        case .identical:
            Label("Same as your copy", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .similar:
            Label("Another version of your copy", systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
        case .unverified:
            EmptyView()
        }
    }

    private func adoptTyped() {
        state.adoptOrphan(skill, source: source)
    }
}
