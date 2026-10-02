import SukiruCore
import SwiftUI

/// The repository half of the install sheet: the typed source, the chosen
/// installer's listing of it, and the skills to install.
struct RepositorySkillPicker: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.install.source")
                Text("Repository")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            HStack(spacing: 8) {
                TextField("owner/repo or URL", text: $state.repositoryInstall.source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(state.listRepositorySkills)
                Button("Show Skills", action: state.listRepositorySkills)
                    .axButtonToken("sukiru.search.install.list", disabled: !canList)
                    .disabled(!canList)
            }
            listing
        }
    }

    private var canList: Bool {
        state.repositoryInstall.listing != .listing
            && !state.repositoryInstall.source.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    @ViewBuilder
    private var listing: some View {
        switch state.repositoryInstall.listing {
        case .idle:
            Text(
                "The installer you choose lists the repository's skills without installing anything."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .listing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Listing skills…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .listed:
            let skills = state.listedRepositorySkills
            if skills.isEmpty {
                Text("The installer found no skills in this repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                skillList(skills)
            }
        }
    }

    private func skillList(_ skills: [RepositorySkill]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(state.repositoryInstall.selection.count) of \(skills.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                let title: LocalizedStringKey =
                    state.repositoryInstall.selection.count == skills.count
                    ? "Deselect All" : "Select All"
                Button(title, action: state.toggleAllRepositorySkills)
                    .axButtonToken("sukiru.search.install.selectAll")
            }
            List(skills) { skill in
                Toggle(isOn: selected(skill.name)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                        if let description = skill.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)
            .frame(height: 180)
        }
    }

    private func selected(_ name: String) -> Binding<Bool> {
        Binding(
            get: { state.repositoryInstall.selection.contains(name) },
            set: { isOn in
                if isOn {
                    state.repositoryInstall.selection.insert(name)
                } else {
                    state.repositoryInstall.selection.remove(name)
                }
            })
    }
}
