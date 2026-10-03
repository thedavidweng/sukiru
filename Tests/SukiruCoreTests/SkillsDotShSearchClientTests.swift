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
            "https://skills.sh/api/search?q=stale&limit=100":
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
        #expect(first.slug == "cleaning-up-stale-feature-flags")
        #expect(first.popularityLabel == "305 installs")
        #expect(first.id == "skills.sh|posthog/ai-plugin|cleaning-up-stale-feature-flags")
    }

    @Test("empty skills array is a valid empty result")
    func emptyResults() async throws {
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=zzz&limit=100":
                .success(Data("{\"skills\":[]}".utf8))
        ])
        let results = try await SkillsDotShSearchClient(transport: transport)
            .search(query: "zzz")
        #expect(results.isEmpty)
    }

    @Test("malformed JSON surfaces as a marketplace error, never a crash")
    func malformedJSON() async {
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=stale&limit=100":
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

    @Test("an owner filter adds the lowercased owner parameter")
    func ownerFilter() async throws {
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=react&limit=100&owner=vercel-labs":
                .success(Data("{\"skills\":[]}".utf8))
        ])
        let results = try await SkillsDotShSearchClient(transport: transport)
            .search(query: "react", owner: "Vercel-Labs")
        #expect(results.isEmpty)
    }

    @Test("a plus sign is percent-encoded, as the server reads a bare + as a space")
    func plusIsEncoded() async throws {
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=c%2B%2B%20%26%20go&limit=100":
                .success(Data("{\"skills\":[]}".utf8))
        ])
        let results = try await SkillsDotShSearchClient(transport: transport)
            .search(query: "c++ & go")
        #expect(results.isEmpty)
    }

    @Test("results keep the server's ranking, deduplicated and sanitized")
    func orderingAndSanitizing() async throws {
        let body = """
            {"skills": [
              {"id": "a/r/low", "skillId": "low", "name": "low", "installs": 5, "source": "a/r"},
              {"id": "b/r/high", "skillId": "high", "name": "hi\\u0007gh\\nx", "installs": 900,
               "source": "b/r", "isDuplicate": true},
              {"id": "a/r/low", "skillId": "low", "name": "low", "installs": 5, "source": "a/r"},
              {"id": "c/r/tie", "skillId": "tie", "name": "tie", "installs": 5, "source": "c/r"}
            ]}
            """
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/search?q=x%20y&limit=100": .success(Data(body.utf8))
        ])
        let results = try await SkillsDotShSearchClient(transport: transport)
            .search(query: "x y")
        #expect(results.map(\.name) == ["low", "hi gh x", "tie"])
        #expect(results.map(\.isDuplicate) == [false, true, false])
    }

    @Test("install counts read like npx skills find")
    func installsLabel() {
        #expect(SkillSearchResult.installsLabel(0) == nil)
        #expect(SkillSearchResult.installsLabel(1) == "1 install")
        #expect(SkillSearchResult.installsLabel(999) == "999 installs")
        #expect(SkillSearchResult.installsLabel(1_000) == "1K installs")
        #expect(SkillSearchResult.installsLabel(12_345) == "12.3K installs")
        #expect(SkillSearchResult.installsLabel(1_274_516) == "1.3M installs")
        #expect(SkillSearchResult.installsLabel(2_000_000) == "2M installs")
    }

    @Test("a refusal body becomes the error reason")
    func refusalReason() {
        let body = Data("{\"error\":\"Query must be at least 2 characters\"}".utf8)
        #expect(
            URLSessionMarketplaceTransport.errorReason(body)
                == "Query must be at least 2 characters")
        #expect(URLSessionMarketplaceTransport.errorReason(Data("<html>".utf8)) == nil)
    }
}
