import Foundation

/// A possible source for a skill no installer recorded, with how well its
/// published `SKILL.md` matches the copy on disk.
public struct SourceCandidate: Equatable, Sendable, Identifiable {
    /// Ordered from weakest to strongest evidence.
    public enum Match: Int, Comparable, Sendable {
        /// Same name; the published `SKILL.md` was not compared or not found.
        case unverified
        /// The published `SKILL.md` shares most lines with the local one: the
        /// same skill at another version.
        case similar
        /// The published `SKILL.md` equals the local one.
        case identical

        public static func < (lhs: Match, rhs: Match) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let result: SkillSearchResult
    public let match: Match

    public init(result: SkillSearchResult, match: Match) {
        self.result = result
        self.match = match
    }

    public var id: String { result.id }

    /// The listing's source as `npx skills add` accepts it: an `owner/repo`
    /// slug as is, a well-known domain as an HTTPS URL.
    public var installSource: String {
        let source = result.repo ?? ""
        return source.contains("/") ? source : "https://" + source
    }

    var isGitHub: Bool { result.repo?.contains("/") == true }
}

/// Finds where an ownerless skill came from: skills.sh listings with the
/// same name, checked by comparing each listing's published `SKILL.md` with
/// the local one, so a match can be adopted without the user typing a source.
///
/// Read-only network use only (skills.sh search plus raw `SKILL.md` reads).
public struct SourceMatcher: Sendable {
    /// Share of distinct lines two `SKILL.md` files need in common to count
    /// as the same skill at different versions.
    static let similarityThreshold = 0.8
    /// Listings whose `SKILL.md` is fetched per skill; popular names have
    /// dozens of forks, and the original is almost always among the first.
    static let verificationLimit = 5

    private let search: SkillsDotShSearchClient
    private let fetcher: SkillPreviewFetcher

    public init(transport: any MarketplaceTransport) {
        search = SkillsDotShSearchClient(transport: transport)
        fetcher = SkillPreviewFetcher(transport: transport)
    }

    /// Candidates for a skill, best first. Listings are checked in order
    /// (GitHub repositories before domains, then by installs) until one
    /// matches the local copy; that match leads. Checking stops there because
    /// a stale fork can equal an old local copy byte for byte, while the
    /// popular original has moved on and is only similar.
    public func candidates(name: String, localSkillMD: String) async throws -> [SourceCandidate] {
        var seen = Set<String>()
        let listings = try await search.search(query: name, limit: 50)
            .filter { $0.name == name && $0.repo != nil }
            .filter { seen.insert($0.repo ?? "").inserted }
            .sorted(by: Self.listingOrder)
        var candidates: [SourceCandidate] = []
        var checked = 0
        var matched: SourceCandidate?
        for listing in listings {
            var match = SourceCandidate.Match.unverified
            if matched == nil && checked < Self.verificationLimit {
                checked += 1
                if let remote = try? await fetcher.preview(of: listing) {
                    match = Self.match(local: localSkillMD, remote: remote)
                }
            }
            let candidate = SourceCandidate(result: listing, match: match)
            if match >= .similar {
                matched = candidate
            } else {
                candidates.append(candidate)
            }
        }
        return (matched.map { [$0] } ?? []) + candidates
    }

    static func listingOrder(_ lhs: SkillSearchResult, _ rhs: SkillSearchResult) -> Bool {
        let lhsGitHub = lhs.repo?.contains("/") == true
        let rhsGitHub = rhs.repo?.contains("/") == true
        if lhsGitHub != rhsGitHub {
            return lhsGitHub
        }
        return (lhs.installs ?? 0) > (rhs.installs ?? 0)
    }

    /// Compares two `SKILL.md` bodies, ignoring line endings and
    /// surrounding whitespace.
    static func match(local: String, remote: String) -> SourceCandidate.Match {
        let localLines = lines(local)
        let remoteLines = lines(remote)
        if localLines == remoteLines {
            return localLines.isEmpty ? .unverified : .identical
        }
        let localSet = Set(localLines.filter { !$0.isEmpty })
        let remoteSet = Set(remoteLines.filter { !$0.isEmpty })
        let larger = max(localSet.count, remoteSet.count)
        guard larger > 0 else { return .unverified }
        let shared = Double(localSet.intersection(remoteSet).count) / Double(larger)
        return shared >= similarityThreshold ? .similar : .unverified
    }

    private static func lines(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
