import Foundation
import SukiruCore

@MainActor
extension AppState {
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
        guard let report else { return [] }
        let group = scopeGroup(for: skill)
        return report.findings.filter { finding in
            guard finding.skillName == skill.name else { return false }
            if finding.workspaceID == group { return true }
            if group == "user" { return finding.workspaceID.hasPrefix("host:") }
            return finding.workspaceID.hasPrefix(group + "#")
        }
    }
}
