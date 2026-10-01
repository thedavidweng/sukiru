import Foundation

/// One normalized skill from marketplace search.
///
/// Both search backends (skills.sh marketplace API and `gh skill search`)
/// normalize into this one value so the app renders a single row shape and
/// the installer choice (npx vs gh) is driven by the row's repo/source,
/// never by which backend found it.
public struct SkillSearchResult: Equatable, Sendable, Identifiable, Codable {
    /// Which search backend produced the result.
    public enum Backend: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        /// The skills.sh marketplace API (network read; works with zero CLIs).
        case skillsDotSh = "skills.sh"
        /// `gh skill search` (needs gh ≥ 2.90.0).
        case github
    }

    /// The skill's short name (the directory/SKILL.md name).
    public let name: String
    /// `owner/repo` for GitHub-hosted skills (both backends). nil only for
    /// skills.sh results whose source is not an owner/repo GitHub slug.
    public let repo: String?
    /// Repo-relative path to the skill's SKILL.md, when the backend reveals
    /// it (`gh skill search` does; the skills.sh API does not).
    public let path: String?
    /// One-line description, when the backend provides one.
    public let description: String?
    /// skills.sh install count (backed by `installs`).
    public let installs: Int?
    /// GitHub stars (backed by the `gh skill search` stars field).
    public let stars: Int?
    /// Which backend found this skill.
    public let backend: Backend

    public init(
        name: String,
        repo: String?,
        path: String?,
        description: String?,
        installs: Int?,
        stars: Int?,
        backend: Backend
    ) {
        self.name = name
        self.repo = repo
        self.path = path
        self.description = description
        self.installs = installs
        self.stars = stars
        self.backend = backend
    }

    /// The canonical row id: backend + source + name. Deterministic.
    public var id: String {
        let source = repo ?? "(none)"
        return "\(backend.rawValue)|\(source)|\(name)"
    }

    /// The popularity badge value, preferring whichever backend populated
    /// the row (installs for skills.sh, stars for gh).
    public var popularityLabel: String? {
        switch backend {
        case .skillsDotSh:
            return installs.map { "\($0) installs" }
        case .github:
            return stars.map { "\($0)★" }
        }
    }

    /// Whether a batched install can be derived from this row: both
    /// installers need a resolvable source (owner/repo).
    public var isInstallable: Bool {
        repo != nil && !name.isEmpty
    }
}
