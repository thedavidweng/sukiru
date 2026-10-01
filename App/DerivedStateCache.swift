import Foundation
import SukiruCore

/// Memoized view-model derivations. SwiftUI re-evaluates bodies often; these
/// keep each derivation to one pass per change of its inputs.
@MainActor
final class DerivedStateCache {
    var health: HealthModel?
    var skills: SkillIndex?
    var skillsByID: (reportRevision: Int, skills: [String: Skill])?
    /// SKILL.md locations per skill ID, resolved once per report.
    var markdownURLs: (reportRevision: Int, urls: [String: URL?])?
}

/// The Health surface's findings after focus and workspace filter.
struct HealthModel {
    struct Key: Equatable {
        let reportRevision: Int
        let focus: AppState.HealthFocus?
        let workspaceFilter: String?
        let projectRoots: [String]
    }

    let key: Key
    let focused: [AppState.FindingEntry]
    let visible: [AppState.FindingEntry]
    let groups: [AppState.ProblemGroup]
    let countsByWorkspace: [String: Int]
    let issues: [Issue]
}

/// Report skills by name and scope group.
struct SkillIndex {
    struct Key: Equatable {
        let reportRevision: Int
        let projectRoots: [String]
    }

    let key: Key
    let skills: [String: Skill]

    static func key(name: String, scopeGroup: String) -> String {
        name + "\u{1F}" + scopeGroup
    }
}
