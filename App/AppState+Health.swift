import Foundation
import SukiruCore

/// Health-surface state derivations: skill focus, per-workspace
/// filtering, issue attribution, and
/// the finding → Library reveal. Stored
/// properties live in `AppState.swift`; everything here is computed from
/// them so the views stay dumb.
@MainActor
extension AppState {
    /// A finding paired with its index in the full report — the stable
    /// identity (`Self.findingID`) that survives filtering and surface
    /// switches.
    struct FindingEntry: Equatable {
        let reportIndex: Int
        let finding: Finding

        var id: String { AppState.findingID(finding, index: reportIndex) }
    }

    /// The ownership-bucket workspace id for a skill (`user` /
    /// `project:<root>`). Matches the invariant that a scope's canonical
    /// workspace id equals the ownership bucket key.
    func scopeGroup(for skill: Skill) -> String {
        switch skill.scope {
        case .user, .all:
            return "user"
        case .project:
            if let root = projectRoot(of: skill) {
                return "project:\(root)"
            }
            return "project:?"
        }
    }

    /// Attributes a project-scope skill to its project root by placement path
    /// prefix (workspace roots live under the project root).
    func projectRoot(of skill: Skill) -> String? {
        projectRoots.first { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return skill.placements.contains { $0.path.hasPrefix(prefix) }
        }
    }

    // MARK: - Deep-link: Library skill → Health findings

    /// Navigates to Health showing only the findings that implicate `skill`
    /// (the "show findings" action), each with its evidence open. The
    /// workspace filter is cleared so the focused list is never additionally
    /// narrowed by a stale selection.
    func showFindings(for skill: Skill) {
        healthFocus = HealthFocus(skillName: skill.name, scopeGroup: scopeGroup(for: skill))
        healthWorkspaceFilter = nil
        expandedFindings.formUnion(findingEntries(for: skill).map(\.id))
        surface = .health
    }

    /// Clears the Health skill focus (shows every finding again).
    func clearHealthFocus() {
        healthFocus = nil
    }

    /// Applies the active health focus: findings implicating the focused
    /// skill in its scope. A finding's workspace id is either the scope group
    /// itself or a host workspace nested under it.
    func focusedFindings(_ findings: [Finding]) -> [Finding] {
        guard healthFocus != nil else { return findings }
        return findings.filter(isFocused)
    }

    private func isFocused(_ finding: Finding) -> Bool {
        guard let focus = healthFocus else { return true }
        guard finding.skillName == focus.skillName else { return false }
        let workspaceID = finding.workspaceID
        if workspaceID == focus.scopeGroup { return true }
        if focus.scopeGroup == "user" && workspaceID.hasPrefix("host:") { return true }
        return workspaceID.hasPrefix(focus.scopeGroup + "#")
    }

    // MARK: - Workspace filter

    /// Finding entries after applying the skill focus AND the workspace
    /// filter. The filter is scope-level (`user` / `project:<root>`): most
    /// rules attribute findings to the scope, not a host workspace, so a
    /// per-host filter would show every host as clean. The sum of the
    /// per-scope counts equals the total.
    func visibleHealthEntries() -> [FindingEntry] {
        healthModel.visible
    }

    /// Finding entries with only the skill focus applied — the "All"
    /// workspace filter option's count.
    func visibleHealthEntriesIgnoringWorkspaceFilter() -> [FindingEntry] {
        healthModel.focused
    }

    /// The scopes the filter offers (the user scope, then each project), in
    /// report order, each with its (focus-aware) finding count so a
    /// zero-finding scope is visible and selectable.
    func workspaceFilterOptions() -> [(workspace: Workspace, count: Int)] {
        let counts = healthModel.countsByScope
        return scopeWorkspaces.map { ($0, counts[$0.id, default: 0]) }
    }

    /// The canonical workspace of each scope; its id is the scope group.
    private var scopeWorkspaces: [Workspace] {
        (report?.workspaces ?? []).filter { Self.scopeGroup(ofWorkspaceID: $0.id) == $0.id }
    }

    /// Visible findings grouped by problem kind, most actionable first;
    /// notes come last.
    func problemGroups() -> [ProblemGroup] {
        healthModel.groups
    }

    /// The Health derivations for the current inputs, computed in one pass
    /// and reused until the report, focus, filter, or project roots change.
    private var healthModel: HealthModel {
        let key = HealthModel.Key(
            reportRevision: reportRevision, focus: healthFocus,
            workspaceFilter: healthWorkspaceFilter, projectRoots: projectRoots)
        if let cached = derived.health, cached.key == key { return cached }
        let entries = (report?.findings ?? []).enumerated().map {
            FindingEntry(reportIndex: $0.offset, finding: $0.element)
        }
        let focused = healthFocus == nil ? entries : entries.filter { isFocused($0.finding) }
        let visible =
            healthWorkspaceFilter.map { filter in
                focused.filter { Self.scopeGroup(ofWorkspaceID: $0.finding.workspaceID) == filter }
            } ?? focused
        let byKind = Dictionary(grouping: visible) { ProblemKind.of($0.finding) }
        let model = HealthModel(
            key: key,
            focused: focused,
            visible: visible,
            groups: ProblemKind.allCases.compactMap { kind in
                byKind[kind].map { ProblemGroup(kind: kind, entries: $0) }
            },
            countsByScope: focused.reduce(into: [:]) {
                $0[Self.scopeGroup(ofWorkspaceID: $1.finding.workspaceID), default: 0] += 1
            },
            issues: computeVisibleIssues())
        derived.health = model
        return model
    }

    /// Cycles the workspace filter across "All" (nil) plus every workspace
    /// in report order — the keyboard path to the filter-bar option buttons,
    /// which are not Tab stops with Full Keyboard Access off.
    func cycleWorkspaceFilter(step: Int) {
        guard canCycleWorkspaceFilter else { return }
        let ids: [String?] = [nil] + scopeWorkspaces.map(\.id)
        let current = ids.firstIndex(of: healthWorkspaceFilter) ?? 0
        let next = (current + step + ids.count) % ids.count
        healthWorkspaceFilter = ids[next]
    }

    /// Whether the workspace-filter cycling menu commands can do anything.
    var canCycleWorkspaceFilter: Bool {
        !(report?.workspaces.isEmpty ?? true)
    }

    // MARK: - Issues (malformed data renders sanely)

    /// Issues are environment-level (they carry a path, not a workspace id),
    /// so they are attributed to a workspace by path: longest matching
    /// workspace root wins; otherwise a project root; otherwise the user
    /// scope (e.g. the global lock lives next to, not under, a skills root).
    /// While a skill focus is active, only issues whose path names the
    /// focused skill show — an unrelated issue must never read as a stale
    /// finding for the focused skill.
    func visibleIssues() -> [Issue] {
        healthModel.issues
    }

    private func computeVisibleIssues() -> [Issue] {
        guard let report else { return [] }
        var issues = report.issues
        if let focus = healthFocus {
            issues = issues.filter { $0.path.contains(focus.skillName) }
        }
        guard let filter = healthWorkspaceFilter else { return issues }
        return issues.filter { issue in
            Self.scopeGroup(ofWorkspaceID: attributedWorkspaceID(of: issue, in: report)) == filter
        }
    }

    private func attributedWorkspaceID(of issue: Issue, in report: ScanReport) -> String {
        let underRoot = report.workspaces
            .filter { workspace in
                let prefix = workspace.root.hasSuffix("/") ? workspace.root : workspace.root + "/"
                return issue.path.hasPrefix(prefix) || issue.path == workspace.root
            }
            .max { $0.root.count < $1.root.count }
        if let underRoot { return underRoot.id }
        if let root = projectRoots.first(where: {
            let prefix = $0.hasSuffix("/") ? $0 : $0 + "/"
            return issue.path.hasPrefix(prefix)
        }) {
            return "project:\(root)"
        }
        return "user"
    }

    // MARK: - Deep-link: Health finding → Library skill (reveal)

    /// The skill a finding implicates: same name AND same scope group as the
    /// finding's workspace, so a same-named skill in another workspace is
    /// never selected by mistake.
    func skill(matching finding: Finding) -> Skill? {
        guard let name = finding.skillName else { return nil }
        let group = Self.scopeGroup(ofWorkspaceID: finding.workspaceID)
        return skillIndex[SkillIndex.key(name: name, scopeGroup: group)]
    }

    /// Skills by name and scope group (first in report order wins), rebuilt
    /// only when the report or project roots change.
    private var skillIndex: [String: Skill] {
        let key = SkillIndex.Key(reportRevision: reportRevision, projectRoots: projectRoots)
        if let cached = derived.skills, cached.key == key { return cached.skills }
        var skills: [String: Skill] = [:]
        for skill in report?.skills ?? [] {
            let indexKey = SkillIndex.key(name: skill.name, scopeGroup: scopeGroup(for: skill))
            if skills[indexKey] == nil { skills[indexKey] = skill }
        }
        derived.skills = SkillIndex(key: key, skills: skills)
        return skills
    }

    /// Maps a finding's workspace id to its ownership-bucket scope group
    /// (`user` for `user` and `host:*`; `project:<root>` for
    /// `project:<root>` and `project:<root>#<host>`).
    nonisolated static func scopeGroup(ofWorkspaceID workspaceID: String) -> String {
        if workspaceID == "user" || workspaceID.hasPrefix("host:") { return "user" }
        if workspaceID.hasPrefix("project:") {
            var rest = String(workspaceID.dropFirst("project:".count))
            if let hash = rest.firstIndex(of: "#") {
                rest = String(rest[..<hash])
            }
            return "project:\(rest)"
        }
        return workspaceID
    }

    /// Reveal-in-Library action:
    /// navigates to Library with the implicated skill's row selected and its
    /// detail open. No-op when the finding names no on-disk skill (e.g. a
    /// lock-without-files ghost has no placement).
    func revealInLibrary(for finding: Finding) {
        guard let skill = skill(matching: finding) else { return }
        libraryScope = .all
        selectedSkillID = Self.skillID(skill)
        surface = .library
    }

    /// The currently selected finding, if it still resolves.
    func selectedFinding() -> Finding? {
        guard let report, let selectedFindingID else { return nil }
        for index in report.findings.indices
        where Self.findingID(report.findings[index], index: index) == selectedFindingID {
            return report.findings[index]
        }
        return nil
    }

    /// Toggles evidence disclosure for the selected finding (keyboard path).
    func toggleSelectedFindingEvidence() {
        guard let selectedFindingID else { return }
        if expandedFindings.contains(selectedFindingID) {
            expandedFindings.remove(selectedFindingID)
        } else {
            expandedFindings.insert(selectedFindingID)
        }
    }
}
