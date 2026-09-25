import SukiruCore
import SwiftUI

/// The selected skill's reading surface. A compact summary stays visible
/// while the system picker switches between its overview, source, and paths.
struct LibraryDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedTab: DetailTab = .overview

    private enum DetailTab: String, CaseIterable {
        case overview
        case content
        case locations

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .content: "Content"
            case .locations: "Locations"
            }
        }
    }

    var body: some View {
        if let skill = state.selectedSkill() {
            detail(skill)
        } else {
            ContentUnavailableView {
                Label("Select a skill to inspect it", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private func detail(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(skill)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Picker("Skill detail", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            switch selectedTab {
            case .overview:
                LibraryOverviewView(skill: skill)
            case .content:
                SkillContentView(skill: skill)
            case .locations:
                LibraryLocationsView(skill: skill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: skill.selfID) { _, _ in selectedTab = .overview }
    }

    private func header(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail")
                Text(skill.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text(ownershipText(skill))
                Text(verbatim: "·")
                scopeText(skill)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let description = state.skillDescriptions[skill.selfID] {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            actions(for: skill)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func actions(for skill: Skill) -> some View {
        HStack(spacing: 18) {
            Button {
                state.quickLookSelectedSkill()
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .buttonStyle(.borderless)
            .axButtonToken(
                "sukiru.library.quicklook",
                disabled: state.skillMarkdownURL(for: skill) == nil
            )
            .disabled(state.skillMarkdownURL(for: skill) == nil)
            .help("Quick Look SKILL.md")

            if !state.findings(for: skill).isEmpty {
                Button {
                    state.showFindings(for: skill)
                } label: {
                    Label("View findings", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.borderless)
                .axButtonToken("sukiru.library.detail.showFindings")
            }
        }
        .padding(.top, 2)
    }

    private func ownershipText(_ skill: Skill) -> LocalizedStringKey {
        switch skill.ownership {
        case .vercel: "Vercel"
        case .github: "GitHub"
        case .doubleBooked: "Double-booked"
        case .ownerless: "Ownerless"
        }
    }

    @ViewBuilder
    private func scopeText(_ skill: Skill) -> some View {
        if skill.scope == .user {
            Text("User scope")
        } else if let root = state.projectRoot(of: skill) {
            Text(root)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Project scope")
        }
    }
}
