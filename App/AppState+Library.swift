import AppKit
import SukiruCore

@MainActor
extension AppState {
    /// Stable identity for a skill row: scope + name + first placement path
    /// (a name can legitimately appear once per scope and per project root).
    nonisolated static func skillID(_ skill: Skill) -> String {
        let anchor = skill.placements.first?.path ?? "-"
        return "\(skill.scope.rawValue)|\(skill.name)|\(anchor)"
    }

    /// Stable identity for a finding row within one report.
    nonisolated static func findingID(_ finding: Finding, index: Int) -> String {
        "\(finding.ruleID)|\(finding.workspaceID)|\(finding.skillName ?? "-")|\(index)"
    }

    /// Presents a folder picker and adds the chosen project root (D20).
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
        return report.findings.enumerated().compactMap { index, finding in
            guard finding.skillName == skill.name else { return nil }
            let inScope =
                finding.workspaceID == group
                || (group == "user"
                    ? finding.workspaceID.hasPrefix("host:")
                    : finding.workspaceID.hasPrefix(group + "#"))
            return inScope ? FindingEntry(reportIndex: index, finding: finding) : nil
        }
    }

    /// Info-level findings (for example a skill shared by several hosts)
    /// describe the library rather than ask for a fix, so they never flag a
    /// skill or count toward the Health badge.
    func needsAttention(_ skill: Skill) -> Bool {
        findings(for: skill).contains { $0.severity != .info }
    }

    var attentionFindingCount: Int {
        report?.findings.filter { $0.severity != .info }.count ?? 0
    }

    func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
