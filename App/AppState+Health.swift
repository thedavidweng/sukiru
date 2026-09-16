import Foundation
import SukiruCore

/// Health-surface state derivations: skill focus (D16), per-workspace
/// filtering (VAL-HEALTH-015/047), issue attribution (VAL-HEALTH-022), and
/// the finding → Library reveal (VAL-HEALTH-038, VAL-CROSS-004). Stored
/// properties live in `AppState.swift`; everything here is computed from
/// them so the views stay dumb.
@MainActor
extension AppState {
    /// A finding paired with its index in the full report — the stable
    /// identity (`Self.findingID`) that survives filtering and surface
    /// switches (VAL-HEALTH-045).
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

    // MARK: - D16 deep-link: Library skill → Health findings

    /// Navigates to Health showing only the findings that implicate `skill`
    /// (D16 "show findings" action). The workspace filter is cleared so the
    /// focused list is never additionally narrowed by a stale selection.
    func showFindings(for skill: Skill) {
        healthFocus = HealthFocus(skillName: skill.name, scopeGroup: scopeGroup(for: skill))
        healthWorkspaceFilter = nil
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
        guard let focus = healthFocus else { return findings }
        return findings.filter { finding in
            guard finding.skillName == focus.skillName else { return false }
            let workspaceID = finding.workspaceID
            if workspaceID == focus.scopeGroup { return true }
            if focus.scopeGroup == "user" && workspaceID.hasPrefix("host:") { return true }
            return workspaceID.hasPrefix(focus.scopeGroup + "#")
        }
    }

    // MARK: - Workspace filter (VAL-HEALTH-015/047)

    /// All findings with their report-wide indices, in report order.
    func healthEntries() -> [FindingEntry] {
        (report?.findings ?? []).enumerated().map {
            FindingEntry(reportIndex: $0.offset, finding: $0.element)
        }
    }

    /// Finding entries after applying the skill focus AND the workspace
    /// filter. The workspace filter matches a finding's workspace id exactly
    /// (per-workspace filtering; the sum of per-workspace counts equals the
    /// total — VAL-HEALTH-034).
    func visibleHealthEntries() -> [FindingEntry] {
        var entries = visibleHealthEntriesIgnoringWorkspaceFilter()
        if let filter = healthWorkspaceFilter {
            entries = entries.filter { $0.finding.workspaceID == filter }
        }
        return entries
    }

    /// Finding entries with only the skill focus applied — the "All"
    /// workspace filter option's count.
    func visibleHealthEntriesIgnoringWorkspaceFilter() -> [FindingEntry] {
        let entries = healthEntries()
        guard healthFocus != nil else { return entries }
        return entries.filter { entry in
            focusedFindings([entry.finding]).isEmpty == false
        }
    }

    /// The workspaces the filter offers, in report order, each with its
    /// (focus-aware) finding count so a zero-finding workspace is visible
    /// and selectable (VAL-HEALTH-047).
    func workspaceFilterOptions() -> [(workspace: Workspace, count: Int)] {
        guard let report else { return [] }
        let focused = focusedFindings(report.findings)
        return report.workspaces.map { workspace in
            let count = focused.filter { $0.workspaceID == workspace.id }.count
            return (workspace, count)
        }
    }

    /// Cycles the workspace filter across "All" (nil) plus every workspace
    /// in report order — the keyboard path to the filter-bar option buttons,
    /// which are not Tab stops with Full Keyboard Access off.
    func cycleWorkspaceFilter(step: Int) {
        guard canCycleWorkspaceFilter, let report else { return }
        var ids: [String?] = [nil]
        for workspace in report.workspaces {
            ids.append(workspace.id)
        }
        let current = ids.firstIndex(of: healthWorkspaceFilter) ?? 0
        let next = (current + step + ids.count) % ids.count
        healthWorkspaceFilter = ids[next]
    }

    /// Whether the workspace-filter cycling menu commands can do anything.
    var canCycleWorkspaceFilter: Bool {
        !(report?.workspaces.isEmpty ?? true)
    }

    // MARK: - Issues (VAL-HEALTH-022: malformed data renders sanely)

    /// Issues are environment-level (they carry a path, not a workspace id),
    /// so they are attributed to a workspace by path: longest matching
    /// workspace root wins; otherwise a project root; otherwise the user
    /// scope (e.g. the global lock lives next to, not under, a skills root).
    /// While a skill focus is active, only issues whose path names the
    /// focused skill show — an unrelated issue must never read as a stale
    /// finding for the focused skill (VAL-CROSS-005).
    func visibleIssues() -> [Issue] {
        guard let report else { return [] }
        var issues = report.issues
        if let focus = healthFocus {
            issues = issues.filter { $0.path.contains(focus.skillName) }
        }
        guard let filter = healthWorkspaceFilter else { return issues }
        return issues.filter { issue in
            attributedWorkspaceID(of: issue, in: report) == filter
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

    // MARK: - D16 deep-link: Health finding → Library skill (reveal)

    /// The skill a finding implicates: same name AND same scope group as the
    /// finding's workspace, so a same-named skill in another workspace is
    /// never selected by mistake (VAL-CROSS-004).
    func skill(matching finding: Finding) -> Skill? {
        guard let report, let name = finding.skillName else { return nil }
        let group = Self.scopeGroup(ofWorkspaceID: finding.workspaceID)
        return report.skills.first { $0.name == name && scopeGroup(for: $0) == group }
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

    /// Reveal-in-Library action (D16, VAL-HEALTH-038, VAL-CROSS-004):
    /// navigates to Library with the implicated skill's row selected and its
    /// detail open. No-op when the finding names no on-disk skill (e.g. a
    /// lock-without-files ghost has no placement — VAL-SCAN-028).
    func revealInLibrary(for finding: Finding) {
        guard let skill = skill(matching: finding) else { return }
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
