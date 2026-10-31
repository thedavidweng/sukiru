import AppKit
import SukiruCore

@MainActor
extension AppState {
    /// Stable identity for a skill row: scope + name + first placement path
    /// (a name can legitimately appear once per scope and per project root).
    nonisolated static func skillID(_ skill: Skill) -> String {
        if let package = skill.provenance.pnpm?.first, let identity = skill.packageQualifiedName {
            return "project|\(package.projectRoot)|pnpm|\(identity)|\(package.target)"
        }
        let anchor = skill.placements.first?.path ?? "-"
        return "\(skill.scope.rawValue)|\(skill.name)|\(anchor)"
    }

    /// Stable identity for a finding row within one report.
    nonisolated static func findingID(_ finding: Finding, index: Int) -> String {
        "\(finding.ruleID)|\(finding.workspaceID)|\(finding.skillName ?? "-")|\(index)"
    }

    /// Presents a folder picker and adds the chosen project root.
    func addProjectRootViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProjectRoot(url.path)
    }

    func loadSkillDescriptions(for report: ScanReport, generation: Int) {
        skillDescriptions = [:]
        Task.detached(priority: .utility) { [weak self] in
            let parser = FrontmatterParser()
            var descriptions: [String: String] = [:]
            for skill in report.skills {
                for placement in skill.placements {
                    let path = URL(fileURLWithPath: placement.path)
                        .appendingPathComponent("SKILL.md").path
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    if case .success(let metadata) = parser.parse(skillFileAt: path) {
                        descriptions[AppState.skillID(skill)] = metadata.description
                        break
                    }
                }
            }
            await MainActor.run {
                guard let self, self.scanGeneration == generation else { return }
                self.skillDescriptions = descriptions
            }
        }
    }

    func findings(for skill: Skill) -> [Finding] {
        findingEntries(for: skill).map(\.finding)
    }

    func findingEntries(for skill: Skill) -> [FindingEntry] {
        guard let report else { return [] }
        let group = scopeGroup(for: skill)
        return findingIndices(named: skill.name).compactMap { index in
            let finding = report.findings[index]
            let inScope =
                finding.workspaceID == group
                || (group == "user"
                    ? finding.workspaceID.hasPrefix("host:")
                    : finding.workspaceID.hasPrefix(group + "#"))
            guard inScope else { return nil }
            let paths = Set(
                finding.evidence.filter {
                    [
                        "placementPath", "memberPath", "hostPath", "canonicalPath", "impostorPath",
                        "linkPath"
                    ]
                    .contains($0.kind)
                }.map(\.detail))
            if !paths.isEmpty && !skill.placements.contains(where: { paths.contains($0.path) }) {
                return nil
            }
            return FindingEntry(reportIndex: index, finding: finding)
        }
    }

    /// Notes (a skill shared by several hosts, the name-based removal
    /// advisory) describe the library rather than ask for a fix, so they
    /// never flag a skill or count toward the Health badge — the same
    /// problem definition Health counts by.
    func needsAttention(_ skill: Skill) -> Bool {
        let id = Self.skillID(skill)
        if let cached = findingIndex.attention[id] { return cached }
        let attention = findings(for: skill).contains { ProblemKind.of($0).isProblem }
        derived.findings?.attention[id] = attention
        return attention
    }

    private var findingIndex: FindingIndex {
        if let cached = derived.findings, cached.reportRevision == reportRevision { return cached }
        var byName: [String: [Int]] = [:]
        for (index, finding) in (report?.findings ?? []).enumerated() {
            if let name = finding.skillName { byName[name, default: []].append(index) }
        }
        let index = FindingIndex(reportRevision: reportRevision, byName: byName)
        derived.findings = index
        return index
    }

    private func findingIndices(named name: String) -> [Int] {
        findingIndex.byName[name] ?? []
    }

    var attentionFindingCount: Int {
        report?.findings.filter { ProblemKind.of($0).isProblem }.count ?? 0
    }

    func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The previewable `SKILL.md` for a skill: the first placement (the
    /// report's canonical-first ordering) whose SKILL.md is actually on
    /// disk. Broken-symlink placements whose file vanished are skipped —
    /// Quick Look of a missing file would show an empty panel. Resolved once
    /// per report: views and menu validation ask on every render.
    func skillMarkdownURL(for skill: Skill) -> URL? {
        if derived.markdownURLs?.reportRevision != reportRevision {
            derived.markdownURLs = (reportRevision, [:])
        }
        let id = Self.skillID(skill)
        if let cached = derived.markdownURLs?.urls[id] { return cached }
        let url = Self.locateMarkdown(of: skill)
        derived.markdownURLs?.urls[id] = .some(url)
        return url
    }

    private static func locateMarkdown(of skill: Skill) -> URL? {
        for placement in skill.placements {
            let url = URL(fileURLWithPath: placement.path)
                .appendingPathComponent("SKILL.md", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Opens Quick Look for every selected skill with a readable SKILL.md.
    func quickLookSelectedSkill() {
        QuickLookPreviewer.shared.preview(
            filesAt: selectedSkills.compactMap(skillMarkdownURL(for:)))
    }

    func canQuickLookSelectedSkill() -> Bool {
        selectedSkills.contains { skillMarkdownURL(for: $0) != nil }
    }

    /// Selected skills in report order, never Set iteration order.
    var selectedSkills: [Skill] {
        report?.skills.filter { selectedSkillIDs.contains(Self.skillID($0)) } ?? []
    }

    /// A single selected skill for actions that cannot operate on a group.
    func selectedSkill() -> Skill? {
        guard selectedSkillIDs.count == 1, let id = selectedSkillIDs.first else { return nil }
        return skill(withID: id)
    }

    /// The skill with an `AppState.skillID`, if it still exists in the report.
    func skill(withID id: String) -> Skill? {
        if derived.skillsByID?.reportRevision != reportRevision {
            let skills = report?.skills ?? []
            derived.skillsByID = (
                reportRevision,
                Dictionary(skills.map { (Self.skillID($0), $0) }) { first, _ in first }
            )
        }
        return derived.skillsByID?.skills[id]
    }
}
