import Foundation
import Testing

@testable import SukiruCore

/// The skills.sh marketplace search client (skills.sh backend):
/// parse the verified API payload, normalize to SkillSearchResult, surface
/// transport failures. Offline via the stub transport.
@Suite("Skills.sh search client")
struct SkillsDotShSearchClientTests {
    /// The probe-captured response shape (2026-09-18).
    private let fixture = """
        {
          "query": "stale",
          "searchType": "fuzzy",
          "searchVersion": "legacy",
          "skills": [
            {
              "id": "posthog/ai-plugin/cleaning-up-stale-feature-flags",
              "skillId": "cleaning-up-stale-feature-flags",
              "name": "cleaning-up-stale-feature-flags",
              "installs": 305,
              "source": "posthog/ai-plugin"
            },
            {
              "id": "owenbush/decodie-skill/decodie-flag-stale",
              "skillId": "decodie-flag-stale",
              "name": "decodie-flag-stale",
              "installs": 210,
              "source": "owenbush/decodie-skill"
            }
          ],
          "count": 2,
          "duration_ms": 467
        }
        """

    private func client(fixture: String) -> SkillsDotShSearchClient {
        let data = Data(fixture.utf8)
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=stale&limit=25":
                .success(Data(data))
        ])
        return SkillsDotShSearchClient(transport: transport)
    }

    @Test("parses the marketplace payload into normalized results")
    func parsesResults() async throws {
        let results = try await client(fixture: fixture).search(query: "stale")
        #expect(results.count == 2)
        let first = results[0]
        #expect(first.name == "cleaning-up-stale-feature-flags")
        #expect(first.repo == "posthog/ai-plugin")
        #expect(first.backend == .skillsDotSh)
        #expect(first.installs == 305)
        #expect(first.path == nil)
        #expect(first.popularityLabel == "305 installs")
        #expect(first.id == "skills.sh|posthog/ai-plugin|cleaning-up-stale-feature-flags")
    }

    @Test("empty skills array is a valid empty result")
    func emptyResults() async throws {
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=zzz&limit=25":
                .success(Data("{\"skills\":[]}".utf8))
        ])
        let results = try await SkillsDotShSearchClient(transport: transport)
            .search(query: "zzz")
        #expect(results.isEmpty)
    }

    @Test("malformed JSON surfaces as a marketplace error, never a crash")
    func malformedJSON() async {
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=stale&limit=25":
                .success(Data("not json".utf8))
        ])
        do {
            _ = try await SkillsDotShSearchClient(transport: transport).search(query: "stale")
            Issue.record("expected a malformed-payload failure")
        } catch let error as MarketplaceError {
            #expect(error.message.hasPrefix("marketplace response was malformed"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("transport failure surfaces the message")
    func transportFailure() async {
        let transport = StubMarketplaceTransport()  // no stub → transport error
        do {
            _ = try await SkillsDotShSearchClient(transport: transport).search(query: "stale")
            Issue.record("expected a transport failure")
        } catch let error as MarketplaceError {
            #expect(error.message.hasPrefix("marketplace request failed"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("search URL carries the query and limit")
    func urlShape() async throws {
        // The URL is derived from the endpoint + query items; assert the
        // expectation that the transport receives the escaped query.
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=my%20skill&limit=50":
                .success(Data("{\"skills\":[]}".utf8))
        ])
        let results = try await SkillsDotShSearchClient(transport: transport)
            .search(query: "my skill", limit: 50)
        #expect(results.isEmpty)
    }
}
