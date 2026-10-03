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
    /// skills.sh's mark for a copy of a skill first published elsewhere.
    public let isDuplicate: Bool
    /// skills.sh's `skillId`: the slug its pages and download API use,
    /// which differs from `name` when the name is not a slug
    /// (`C++ Code Formatter` is `c-code-formatter`).
    public let slug: String?

    public init(
        name: String,
        repo: String?,
        path: String?,
        description: String?,
        installs: Int?,
        stars: Int?,
        backend: Backend,
        isDuplicate: Bool = false,
        slug: String? = nil
    ) {
        self.name = name
        self.repo = repo
        self.path = path
        self.description = description
        self.installs = installs
        self.stars = stars
        self.backend = backend
        self.isDuplicate = isDuplicate
        self.slug = slug
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
            return installs.flatMap(Self.installsLabel)
        case .github:
            return stars.map { "\($0)★" }
        }
    }

    /// `npx skills find`'s install badge: `1.3M installs`, `12K installs`,
    /// `1 install`, nothing for zero.
    static func installsLabel(_ count: Int) -> String? {
        func compact(_ value: Double, _ unit: String) -> String {
            let rounded = (value * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
            return "\(text)\(unit) installs"
        }
        switch count {
        case ..<1: return nil
        case 1: return "1 install"
        case ..<1_000: return "\(count) installs"
        case ..<1_000_000: return compact(Double(count) / 1e3, "K")
        default: return compact(Double(count) / 1e6, "M")
        }
    }

    /// The skill's page: its skills.sh listing (as the website links it),
    /// or its SKILL.md on GitHub for `gh skill search` results.
    public var webURL: URL? {
        guard let repo else { return nil }
        if let slug {
            let page = repo.contains("/") ? repo : "site/\(repo)"
            return URL(string: "https://skills.sh/\(page.lowercased())/\(slug.lowercased())")
        }
        guard let path, repo.contains("/") else { return nil }
        return URL(string: "https://github.com/\(repo)/blob/HEAD/\(path)")
    }

    /// Whether a batched install can be derived from this row: both
    /// installers need a resolvable source (owner/repo).
    public var isInstallable: Bool {
        repo != nil && !name.isEmpty
    }
}
