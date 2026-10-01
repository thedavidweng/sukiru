import SukiruCore
import SwiftUI

/// The Library surface: every skill every host sees, grouped per
/// workspace with project vs user scope separated. Rows carry
/// `sukiru.library.skillRow.<name>` labels and ownership badges
/// (`sukiru.library.badge.ownership.<name>`); internal skills carry
/// `sukiru.library.badge.internal.<name>`.
///
/// Scrolling correctness comes from `List`: all rows are
/// exposed in the AX tree and pointer/keyboard scrolling reaches them.
struct LibraryView: View {
    @EnvironmentObject private var state: AppState

    /// Name filter, transient view state (the app keeps no ledger).
    @State private var filter = ""
    @State private var attentionOnly = false
    @State private var ownershipFilter: Ownership?
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
        .navigationTitle(libraryTitle)
        .navigationSubtitle(Text("\(skillCount) skills"))
        .toolbar {
            ToolbarItem {
                filterMenu
            }
        }
    }

    private var isFiltering: Bool { attentionOnly || ownershipFilter != nil }

    /// A Mail-style filter: the symbol fills while any filter is active, so a
    /// shortened list never looks like a smaller library.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $attentionOnly) {
                Text("All Skills").tag(false)
                Text("Needs Attention").tag(true)
            }
            .pickerStyle(.inline)
            Picker("Installer", selection: $ownershipFilter) {
                Text("Any Installer").tag(Ownership?.none)
                Text("Vercel").tag(Ownership?.some(.vercel))
                Text("GitHub").tag(Ownership?.some(.github))
                Text("Double-booked").tag(Ownership?.some(.doubleBooked))
                Text("Ownerless").tag(Ownership?.some(.ownerless))
                Text("Agent-managed").tag(Ownership?.some(.agent))
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter skills", systemImage: "line.3.horizontal.decrease.circle")
                .symbolVariant(isFiltering ? .fill : .none)
        }
        .help("Filter skills by status or installer")
    }

    private var libraryTitle: Text {
        switch state.libraryScope {
        case .all: Text("Library")
        case .user: Text("User Library")
        case .project(let root): Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
        }
    }

    private var skillCount: Int {
        guard let report = state.report else { return 0 }
        return groups(in: report).reduce(0) { $0 + $1.skills.count }
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
                // The Health → Library deep-link must land with the implicated row visible,
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
            if state.libraryScope == .all {
                ForEach(groups) { group in
                    Section(isExpanded: expansion(of: group)) {
                        skillRows(group.skills)
                    } header: {
                        header(group)
                    }
                }
            } else {
                skillRows(groups.flatMap(\.skills))
            }
        }
        .listStyle(.inset)
        .searchable(text: $filter, placement: .toolbar, prompt: Text("Search skills"))
        .overlay {
            if groups.isEmpty && !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if groups.isEmpty && isFiltering {
                ContentUnavailableView {
                    Label("No Matching Skills", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filters") {
                        attentionOnly = false
                        ownershipFilter = nil
                    }
                }
            }
        }
    }

    private func skillRows(_ skills: [Skill]) -> some View {
        ForEach(skills, id: \.selfID) { skill in
            SkillRow(skill: skill)
                .tag(skill.selfID)
        }
    }

    // MARK: - grouping

    /// Groups matching skills into sections, dropping sections the filter
    /// empties so a search never leaves a stranded header behind.
    private func groups(in report: ScanReport) -> [SkillGroup] {
        var groups: [SkillGroup] = []
        let userSkills = report.skills.filter {
            $0.scope == .user && isInSelectedScope($0) && matches($0)
        }
        if !userSkills.isEmpty {
            groups.append(SkillGroup(kind: .user, skills: userSkills))
        }
        for root in projectRootsWithSkills(report) {
            let skills = report.skills.filter {
                $0.scope == .project && state.projectRoot(of: $0) == root
                    && isInSelectedScope($0) && matches($0)
            }
            if !skills.isEmpty {
                groups.append(SkillGroup(kind: .project(root), skills: skills))
            }
        }
        return groups
    }

    private func matches(_ skill: Skill) -> Bool {
        if attentionOnly && !state.needsAttention(skill) { return false }
        if let ownershipFilter, skill.ownership != ownershipFilter { return false }
        return filter.isEmpty || skill.name.localizedCaseInsensitiveContains(filter)
            || state.skillDescriptions[skill.selfID]?.localizedCaseInsensitiveContains(filter)
                == true
            || skill.provenance.github?.repo.localizedCaseInsensitiveContains(filter) == true
            || skill.provenance.vercel?.source?.localizedCaseInsensitiveContains(filter) == true
    }

    private func isInSelectedScope(_ skill: Skill) -> Bool {
        switch state.libraryScope {
        case .all: true
        case .user: skill.scope == .user
        case .project(let root): skill.scope == .project && state.projectRoot(of: skill) == root
        }
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
                Text("User Library")
            case .project(let root):
                AXToken(token: "sukiru.library.section.project.\(AXTokens.path(root))")
                Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
                    .lineLimit(1)
                    .help(root)
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

extension Skill {
    /// The AppState skill identity, as an `Identifiable` convenience.
    var selfID: String { AppState.skillID(self) }
}
