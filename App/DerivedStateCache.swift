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
    var agents: AgentIndex?
    var hostEntries: HostEntryCache?
    var findings: FindingIndex?
}

/// Agents per skill ID, and hosts per skills root keyed by project root ("" for user scope).
struct HostEntryCache {
    let reportRevision: Int
    var entries: [String: [LibraryHostsSection.HostEntry]] = [:]
    var roots: [String: [String: [HostSpec]]] = [:]
}

/// Report finding indices per skill name, and whether each skill needs attention.
struct FindingIndex {
    let reportRevision: Int
    let byName: [String: [Int]]
    var attention: [String: Bool] = [:]
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
    let countsByScope: [String: Int]
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
