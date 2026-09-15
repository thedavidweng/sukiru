import SukiruCore
import SwiftUI

/// The Library surface (§4.3): every skill every host sees, grouped per
/// workspace with project vs user scope separated. Rows carry
/// `sukiru.library.skillRow.<name>` labels and ownership badges
/// (`sukiru.library.badge.ownership.<name>`); internal skills carry
/// `sukiru.library.badge.internal.<name>`.
///
/// Scrolling correctness (VAL-HEALTH-043) comes from `List`: all rows are
/// exposed in the AX tree and pointer/keyboard scrolling reaches them.
struct LibraryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.scanPhase {
            case .loading:
                loadingState
            case .homeMissing(let path):
                homeMissingState(path)
            case .failed(let message):
                failureState(message)
            case .loaded:
                loadedState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - states

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.loading")
                Text("Loading library…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func homeMissingState(_ path: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.error")
                Text("Library root not found")
                    .font(.title3.weight(.semibold))
            }
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            // swiftlint:disable line_length
            let guidance: LocalizedStringKey =
                "The library root (SUKIRU_HOME) does not exist. Fix the path and press Refresh, or relaunch with a valid root."
            // swiftlint:enable line_length
            Text(guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.error")
                Text("Scan failed")
                    .font(.title3.weight(.semibold))
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    @ViewBuilder
    private var loadedState: some View {
        if let report = state.report, !report.skills.isEmpty {
            skillList(report)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.library.empty")
                    Text("No skills found")
                        .font(.title3.weight(.semibold))
                }
                // swiftlint:disable line_length
                let emptyNote: LocalizedStringKey =
                    "This library has no skill installations. Install skills with the official CLIs, or add a project root in Settings."
                // swiftlint:enable line_length
                Text(emptyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(32)
        }
    }

    // MARK: - skill list

    private func skillList(_ report: ScanReport) -> some View {
        List(selection: $state.selectedSkillID) {
            let userSkills = skills(in: .user, report: report)
            if !userSkills.isEmpty {
                Section {
                    ForEach(userSkills, id: \.selfID) { skill in
                        SkillRow(skill: skill)
                            .tag(skill.selfID)
                    }
                } header: {
                    HStack(spacing: 0) {
                        AXToken(token: "sukiru.library.section.user")
                        Text("User scope")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            ForEach(projectRootsWithSkills(report), id: \.self) { root in
                Section {
                    ForEach(skills(projectRoot: root, report: report), id: \.selfID) { skill in
                        SkillRow(skill: skill)
                            .tag(skill.selfID)
                    }
                } header: {
                    HStack(spacing: 0) {
                        AXToken(token: "sukiru.library.section.project.\(AXTokens.path(root))")
                        Text(root)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .listStyle(.inset)
    }

    private func skills(in scope: Scope, report: ScanReport) -> [Skill] {
        report.skills.filter { $0.scope == scope }
    }

    /// Project roots that own at least one skill in the report, sorted for
    /// deterministic section order.
    private func projectRootsWithSkills(_ report: ScanReport) -> [String] {
        var roots: Set<String> = []
        for skill in report.skills where skill.scope == .project {
            if let root = projectRoot(of: skill) {
                roots.insert(root)
            }
        }
        return roots.sorted()
    }

    private func skills(projectRoot root: String, report: ScanReport) -> [Skill] {
        report.skills.filter { $0.scope == .project && projectRoot(of: $0) == root }
    }

    private func projectRoot(of skill: Skill) -> String? {
        state.projectRoot(of: skill)
    }
}

/// One skill row: token carrier + name + ownership badge (+ internal marker).
struct SkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.library.skillRow.\(AXTokens.skill(skill.name))")
            Text(skill.name)
                .font(.body.weight(.medium))
            if skill.ambiguous {
                badge(text: "Ambiguous", color: .orange)
            }
            Spacer()
            if skill.placements.contains(where: \.internal) {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.library.badge.internal.\(AXTokens.skill(skill.name))")
                    badge(text: "Internal", color: .purple)
                }
            }
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.badge.ownership.\(AXTokens.skill(skill.name))")
                badge(text: ownershipText, color: ownershipColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var ownershipText: LocalizedStringKey {
        switch skill.ownership {
        case .vercel: "Vercel"
        case .github: "GitHub"
        case .doubleBooked: "Double-booked"
        case .ownerless: "Ownerless"
        }
    }

    private var ownershipColor: Color {
        switch skill.ownership {
        case .vercel: .blue
        case .github: .green
        case .doubleBooked: .orange
        case .ownerless: .gray
        }
    }
}

extension Skill {
    /// The AppState skill identity, as an `Identifiable` convenience.
    var selfID: String { AppState.skillID(self) }
}
