import Testing

@testable import SukiruCore

/// Typed search input → what is sent, matching `npx skills find`'s
/// argument rules and both backends' refusals, and the owner filters
/// offered for typed text.
@Suite("Skill search request")
struct SkillSearchRequestTests {
    private func parse(
        _ query: String, owner: String? = nil, backend: SkillSearchResult.Backend = .skillsDotSh
    ) -> SkillSearchRequest? {
        SkillSearchRequest.parse(query: query, owner: owner, backend: backend)
    }

    private func request(
        _ query: String, owner: String? = nil, backend: SkillSearchResult.Backend = .skillsDotSh,
        listsOwner: Bool = false
    ) -> SkillSearchRequest {
        SkillSearchRequest(query: query, owner: owner, backend: backend, listsOwner: listsOwner)
    }

    @Test("queries are trimmed and inner whitespace collapsed")
    func whitespace() {
        #expect(parse("  react \t native \n") == request("react native"))
        #expect(parse("   ") == nil)
        #expect(parse("") == nil)
    }

    @Test("queries under two UTF-16 units wait, as both backends refuse them")
    func minimumLength() {
        #expect(parse("a") == nil)
        #expect(parse(" a ") == nil)
        #expect(parse("ab") == request("ab"))
        #expect(parse("搜索") == request("搜索"))
        #expect(parse("🔥") == request("🔥"))
    }

    @Test("an owner alone lists that owner's skills on skills.sh")
    func ownerOnly() {
        #expect(
            parse("", owner: "MattPocock")
                == request("mattpocock", owner: "mattpocock", listsOwner: true))
        #expect(
            parse("g", owner: "mattpocock")
                == request("mattpocock", owner: "mattpocock", listsOwner: true))
        #expect(parse("grill", owner: "mattpocock") == request("grill", owner: "mattpocock"))
        #expect(parse("", owner: "a") == nil)
    }

    @Test("gh skill search cannot list an owner, so it still needs a query")
    func ownerOnlyOnGitHub() {
        #expect(parse("", owner: "mattpocock", backend: .github) == nil)
        #expect(
            parse("grill", owner: "mattpocock", backend: .github)
                == request("grill", owner: "mattpocock", backend: .github))
    }

    @Test("skills.sh is asked for 100 results, as its website asks; gh for a page of 20")
    func limits() {
        #expect(parse("react")?.limit == 100)
        #expect(parse("", owner: "vercel-labs")?.limit == 100)
        #expect(parse("react", backend: .github)?.limit == 20)
    }

    @Test("logins are read as people paste them")
    func ownerLogins() {
        for typed in [
            "mattpocock", " MattPocock ", "@mattpocock", "mattpocock/skills",
            "github.com/mattpocock", "https://github.com/MattPocock/skills",
            "http://www.github.com/mattpocock"
        ] {
            #expect(SkillSearchRequest.ownerLogin(typed) == "mattpocock")
        }
        for typed in [
            "-bad", "a_b", "open.feishu.cn", "has space", String(repeating: "a", count: 40)
        ] {
            #expect(SkillSearchRequest.ownerLogin(typed) == nil)
        }
    }

    private func results(_ sources: [String]) -> [SkillSearchResult] {
        sources.enumerated().map { index, source in
            SkillSearchResult(
                name: "s\(index)", repo: source, path: nil, description: nil, installs: 1,
                stars: nil, backend: .skillsDotSh)
        }
    }

    @Test("owner suggestions come from the results: exact, then prefix, then other matches")
    func ownerSuggestions() {
        let found = results([
            "someone/matt-tools", "xmatt/y", "mattzcarey/x", "MattPocock/skills", "open.feishu.cn",
            "mattpocock/other", "matt/z"
        ])
        #expect(
            SkillSearchRequest.ownerSuggestions(for: "Matt", in: found)
                == ["matt", "mattzcarey", "mattpocock", "xmatt"])
        #expect(
            SkillSearchRequest.ownerSuggestions(for: "Matt", in: found, limit: 2) == [
                "matt", "mattzcarey"
            ])
        #expect(SkillSearchRequest.ownerSuggestions(for: "m", in: found).isEmpty)
        #expect(SkillSearchRequest.ownerSuggestions(for: "react hooks", in: found).isEmpty)
    }

    @Test("text that names an owner outright is offered even before results show it")
    func namedOwner() {
        #expect(SkillSearchRequest.ownerSuggestions(for: "@vercel-labs", in: []) == ["vercel-labs"])
        #expect(
            SkillSearchRequest.ownerSuggestions(
                for: "https://github.com/Vercel-Labs/skills", in: [])
                == ["vercel-labs"])
        #expect(SkillSearchRequest.ownerSuggestions(for: "vercel-labs", in: []).isEmpty)
    }
}
