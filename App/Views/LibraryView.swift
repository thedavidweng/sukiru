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

    /// Name filter, transient view state (the app keeps no ledger).
    @State private var filter = ""
    /// Sections the user collapsed, keyed by `SkillGroup.id`.
    @State private var collapsedGroups: Set<String> = []

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
        // swiftlint:disable line_length
        let guidance: LocalizedStringKey =
            "The library root (SUKIRU_HOME) does not exist. Fix the path and press Refresh, or relaunch with a valid root."
        // swiftlint:enable line_length
        return ContentUnavailableView {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.error")
                Label("Library root not found", systemImage: "exclamationmark.triangle")
            }
        } description: {
            VStack(spacing: 8) {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text(guidance)
            }
        }
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.error")
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            }
        } description: {
            Text(message)
        }
    }

    @ViewBuilder
    private var loadedState: some View {
        if let report = state.report, !report.skills.isEmpty {
            skillList(report)
        } else {
            // swiftlint:disable line_length
            let emptyNote: LocalizedStringKey =
                "This library has no skill installations. Install skills with the official CLIs, or add a project root in Settings."
            // swiftlint:enable line_length
            ContentUnavailableView {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.library.empty")
                    Label("No skills found", systemImage: "tray")
                }
            } description: {
                Text(emptyNote)
            }
        }
    }

    // MARK: - skill list

    private func skillList(_ report: ScanReport) -> some View {
        ScrollViewReader { proxy in
            skillListContent(report)
                // The Health → Library deep-link (D16, VAL-HEALTH-038,
                // VAL-CROSS-004) must land with the implicated row visible,
                // not merely selected somewhere offscreen.
                .onChange(of: state.selectedSkillID) { _, newSelection in
                    if let newSelection {
                        withAnimation {
                            proxy.scrollTo(newSelection, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let selection = state.selectedSkillID {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
        }
    }

    private func skillListContent(_ report: ScanReport) -> some View {
        let groups = groups(in: report)
        return List(selection: $state.selectedSkillID) {
            ForEach(groups) { group in
                Section(isExpanded: expansion(of: group)) {
                    ForEach(group.skills, id: \.selfID) { skill in
                        SkillRow(skill: skill)
                            .tag(skill.selfID)
                    }
                } header: {
                    header(group)
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $filter, prompt: Text("Search skills"))
        .overlay {
            if groups.isEmpty && !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
    }

    // MARK: - grouping

    /// Groups matching skills into sections, dropping sections the filter
    /// empties so a search never leaves a stranded header behind.
    private func groups(in report: ScanReport) -> [SkillGroup] {
        var groups: [SkillGroup] = []
        let userSkills = report.skills.filter { $0.scope == .user && matches($0) }
        if !userSkills.isEmpty {
            groups.append(SkillGroup(kind: .user, skills: userSkills))
        }
        for root in projectRootsWithSkills(report) {
            let skills = report.skills.filter {
                $0.scope == .project && state.projectRoot(of: $0) == root && matches($0)
            }
            if !skills.isEmpty {
                groups.append(SkillGroup(kind: .project(root), skills: skills))
            }
        }
        return groups
    }

    private func matches(_ skill: Skill) -> Bool {
        filter.isEmpty || skill.name.localizedCaseInsensitiveContains(filter)
    }

    /// Project roots that own at least one skill in the report, sorted for
    /// deterministic section order.
    private func projectRootsWithSkills(_ report: ScanReport) -> [String] {
        var roots: Set<String> = []
        for skill in report.skills where skill.scope == .project {
            if let root = state.projectRoot(of: skill) {
                roots.insert(root)
            }
        }
        return roots.sorted()
    }

    private func expansion(of group: SkillGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group.id) },
            set: { expanded in
                if expanded {
                    collapsedGroups.remove(group.id)
                } else {
                    collapsedGroups.insert(group.id)
                }
            })
    }

    @ViewBuilder
    private func header(_ group: SkillGroup) -> some View {
        HStack(spacing: 6) {
            switch group.kind {
            case .user:
                AXToken(token: "sukiru.library.section.user")
                Text("User scope")
            case .project(let root):
                AXToken(token: "sukiru.library.section.project.\(AXTokens.path(root))")
                Text(root)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(group.skills.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

/// One Library list section: the canonical user store, or one project root.
private struct SkillGroup: Identifiable {
    enum Kind: Equatable {
        case user
        case project(String)
    }

    let kind: Kind
    let skills: [Skill]

    var id: String {
        switch kind {
        case .user: "user"
        case .project(let root): "project:\(root)"
        }
    }
}

/// One skill row: token carrier, name, and trailing state. Ownership reads as
/// plain secondary text; color is reserved for the states that need a fix, so
/// a healthy library shows no alarm colors at all.
struct SkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.library.skillRow.\(AXTokens.skill(skill.name))")
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(skill.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            if skill.ambiguous {
                badge(text: "Ambiguous", color: .orange)
            }
            Spacer(minLength: 8)
            if skill.placements.contains(where: \.internal) {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.library.badge.internal.\(AXTokens.skill(skill.name))")
                    Text("Internal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.badge.ownership.\(AXTokens.skill(skill.name))")
                ownershipMarker
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var ownershipMarker: some View {
        switch skill.ownership {
        case .vercel:
            Text("Vercel")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .github:
            Text("GitHub")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .doubleBooked:
            badge(text: "Double-booked", color: .orange)
        case .ownerless:
            badge(text: "Ownerless", color: .orange)
        }
    }

    private func badge(text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension Skill {
    /// The AppState skill identity, as an `Identifiable` convenience.
    var selfID: String { AppState.skillID(self) }
}
