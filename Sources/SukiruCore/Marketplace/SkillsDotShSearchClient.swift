import Foundation

/// The skills.sh marketplace search client (`skills.sh` backend).
///
/// `GET https://skills.sh/api/search?q=<query>&limit=<n>` returns
/// `{"skills": [{"id", "skillId", "name", "installs", "source", "isDuplicate"?}]}`.
/// It is the endpoint the skills.sh website and `npx skills find` search
/// through, so results match theirs. This is
/// a pure network read with NO subprocess (`npx` is never required), so
/// search stays available in every degraded environment. The
/// response's `source` is the `owner/repo` slug the installers
/// accept; `id` is `owner/repo/skill-name` (the display path).
public struct SkillsDotShSearchClient: Sendable {
    /// One skill entry in the marketplace response.
    public struct Skill: Decodable, Sendable {
        public let id: String
        public let skillId: String
        public let name: String
        public let installs: Int
        public let source: String
        /// Set on copies of a skill published elsewhere first; the website
        /// dims them in place.
        public let isDuplicate: Bool?
    }

    /// The decoded search response body.
    public struct Response: Decodable, Sendable {
        public let skills: [Skill]
    }

    /// The verified marketplace endpoint (probe-captured 2026-09-18).
    public static let endpoint = URL(string: "https://skills.sh/api/search")!

    private let transport: any MarketplaceTransport

    public init(transport: any MarketplaceTransport) {
        self.transport = transport
    }

    /// Searches the marketplace. `limit` maps to the API's `limit` query
    /// parameter (probe verified: supports up to at least 100). `owner` maps
    /// to the `owner` parameter that `npx skills find --owner` sends,
    /// lowercased as that command does. Results keep the server's ranking,
    /// as the website shows it: relevance first, installs as one signal
    /// (`npx skills find` re-sorts by installs alone, which buries the skill
    /// named `pdf` under unrelated popular ones).
    public func search(
        query: String, owner: String? = nil, limit: Int = 100
    ) async throws -> [SkillSearchResult] {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let owner {
            items.append(URLQueryItem(name: "owner", value: owner.lowercased()))
        }
        let data = try await transport.fetch(try Self.url(items))
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MarketplaceError.malformed(String(describing: error))
        }
        var seen = Set<String>()
        return response.skills
            .map { skill in
                SkillSearchResult(
                    name: Self.sanitized(skill.name),
                    repo: Self.sanitized(skill.source),
                    path: nil,
                    description: nil,
                    installs: skill.installs,
                    stars: nil,
                    backend: .skillsDotSh,
                    isDuplicate: skill.isDuplicate ?? false,
                    slug: skill.skillId)
            }
            // The list selects rows by id; a repeated id would select both.
            .filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
    }

    /// `URLComponents` leaves `+` bare, which the server reads as a space
    /// (`c++` would arrive as `c`); `npx skills find` sends it as `%2B`.
    private static func url(_ items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MarketplaceError.transport("cannot build search URL")
        }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw MarketplaceError.transport("cannot build search URL")
        }
        return url
    }

    /// Marketplace metadata is third-party text: control characters and
    /// line breaks are dropped, as `npx skills find` drops them.
    private static func sanitized(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) ? " " : $0
                })
        )
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
    }
}
