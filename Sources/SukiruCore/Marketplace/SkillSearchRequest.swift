import Foundation

/// A search as typed, normalized the way `npx skills find` normalizes its
/// arguments before calling the same skills.sh API.
///
/// Both backends reject queries under two characters, so those never reach
/// the network. The owner filter is an exact GitHub login, picked from
/// `ownerSuggestions`. With only an owner, skills.sh lists that owner's
/// skills: its fuzzy match ranks the owner's own repositories first when
/// the query is the owner name. `gh skill search` has no such match, so it
/// still needs a query.
public struct SkillSearchRequest: Equatable, Sendable {
    /// Queries shorter than this are refused by skills.sh and gh alike
    /// (measured in UTF-16 units, as their JavaScript and Go checks are).
    public static let minimumQueryLength = 2

    public let query: String
    public let owner: String?
    public let backend: SkillSearchResult.Backend
    /// Whether this lists the owner's skills because no query was typed.
    public let listsOwner: Bool

    /// skills.sh is asked for 100, as its website asks; `gh skill search`
    /// pages GitHub code search, so it keeps a page of 20.
    public var limit: Int { backend == .skillsDotSh ? 100 : 20 }

    /// The request for the typed query and owner filter, or nil while
    /// nothing is searchable yet.
    public static func parse(
        query rawQuery: String, owner rawOwner: String?, backend: SkillSearchResult.Backend
    ) -> SkillSearchRequest? {
        let query = rawQuery.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let owner = rawOwner?.lowercased()
        if query.utf16.count >= minimumQueryLength {
            return SkillSearchRequest(
                query: query, owner: owner, backend: backend, listsOwner: false)
        }
        if let owner, backend == .skillsDotSh, owner.utf16.count >= minimumQueryLength {
            return SkillSearchRequest(
                query: owner, owner: owner, backend: backend, listsOwner: true)
        }
        return nil
    }

    /// GitHub owners to offer as a filter for the typed text: owners of the
    /// current results whose login contains it (exact, then prefix, then
    /// other matches, each in result order), led by an owner the text names
    /// outright (`@vercel-labs`, `github.com/vercel-labs`).
    public static func ownerSuggestions(
        for typed: String, in results: [SkillSearchResult], limit: Int = 5
    ) -> [String] {
        guard let needle = ownerLogin(typed), needle.utf16.count >= minimumQueryLength else {
            return []
        }
        var seen = Set<String>()
        var owners = results.compactMap { result -> String? in
            guard let repo = result.repo, repo.contains("/") else { return nil }
            return repo.split(separator: "/").first.map { $0.lowercased() }
        }
        .filter { $0.contains(needle) && seen.insert($0).inserted }
        let named = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if named.hasPrefix("@") || named.contains("github.com/"), !owners.contains(needle) {
            owners.insert(needle, at: 0)
        }
        let rank = { (owner: String) in owner == needle ? 0 : owner.hasPrefix(needle) ? 1 : 2 }
        return Array(
            owners.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element)
                .prefix(limit))
    }

    /// The GitHub login in typed text, as people paste one (`@mattpocock`,
    /// `mattpocock/skills`, `https://github.com/mattpocock`), lowercased;
    /// nil when the text is not a login.
    public static func ownerLogin(_ raw: String) -> String? {
        var owner = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www.", "github.com/", "@"]
        where owner.hasPrefix(prefix) {
            owner.removeFirst(prefix.count)
        }
        owner = owner.split(separator: "/").first.map(String.init) ?? ""
        return isGitHubLogin(owner) ? owner : nil
    }

    /// The pattern `npx skills find` and `gh skill search` both enforce.
    private static func isGitHubLogin(_ owner: String) -> Bool {
        owner.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,38}/) != nil
    }
}
