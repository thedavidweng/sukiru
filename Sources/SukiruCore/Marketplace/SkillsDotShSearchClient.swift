import Foundation

/// The skills.sh marketplace search client (`skills.sh` backend).
///
/// `GET https://skills.sh/api/search?q=<query>&limit=<n>` returns
/// `{"skills": [{"id", "skillId", "name", "installs", "source"}]}`. This is
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
    /// parameter (probe verified: supports up to at least 50).
    public func search(query: String, limit: Int = 25) async throws -> [SkillSearchResult] {
        guard
            var components = URLComponents(
                url: Self.endpoint, resolvingAgainstBaseURL: false)
        else {
            throw MarketplaceError.transport("cannot build search URL")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            throw MarketplaceError.transport("cannot build search URL")
        }
        let data = try await transport.fetch(url)
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MarketplaceError.malformed(String(describing: error))
        }
        return response.skills.map { skill in
            SkillSearchResult(
                name: skill.name,
                repo: skill.source,
                path: nil,
                description: nil,
                installs: skill.installs,
                stars: nil,
                backend: .skillsDotSh)
        }
    }
}
