import Foundation
import Testing

@testable import SukiruCore

/// The raw SKILL.md preview fetcher (story 24): exact URL for gh results
/// (which carry the repo-relative path), the standard-location candidates
/// for skills.sh results, first-200-wins, and nil when nothing resolves —
/// preview failure never blocks the install.
@Suite("Skill preview fetcher")
struct SkillPreviewFetcherTests {
    @Test("gh result with path fetches the exact raw URL")
    func exactPathFromGH() async throws {
        let result = SkillSearchResult(
            name: "stale-docs",
            repo: "SectionTN/stale-docs",
            path: "skills/stale-docs/SKILL.md",
            description: nil,
            installs: nil,
            stars: 3,
            backend: .github)
        let transport = StubMarketplaceTransport(responses: [
            "https://raw.githubusercontent.com/SectionTN/stale-docs/HEAD/skills/stale-docs/SKILL.md":
                .success(Data("---\nname: stale-docs\n---\nbody".utf8))
        ])
        let preview = try await SkillPreviewFetcher(transport: transport).preview(of: result)
        #expect(preview == "---\nname: stale-docs\n---\nbody")
    }

    @Test("skills.sh result tries the standard locations in order")
    func skillsShCandidates() async throws {
        let result = SkillSearchResult(
            name: "notes",
            repo: "owner/notes",
            path: nil,
            description: nil,
            installs: 10,
            stars: nil,
            backend: .skillsDotSh)
        let transport = StubMarketplaceTransport(responses: [
            "https://raw.githubusercontent.com/owner/notes/HEAD/skills/notes/SKILL.md":
                .failure(MarketplaceError.transport("HTTP 404")),
            "https://raw.githubusercontent.com/owner/notes/HEAD/notes/SKILL.md":
                .success(Data("found at notes/SKILL.md".utf8))
        ])
        let preview = try await SkillPreviewFetcher(transport: transport).preview(of: result)
        #expect(preview == "found at notes/SKILL.md")
    }

    @Test("no candidate resolves → nil, not an error")
    func unavailablePreview() async throws {
        let result = SkillSearchResult(
            name: "nothing",
            repo: "owner/repo",
            path: nil,
            description: nil,
            installs: 1,
            stars: nil,
            backend: .skillsDotSh)
        let transport = StubMarketplaceTransport()
        let preview = try await SkillPreviewFetcher(transport: transport).preview(of: result)
        #expect(preview == nil)
    }

    @Test("repo-less result yields no candidates → nil")
    func repoLessResult() async throws {
        let result = SkillSearchResult(
            name: "x",
            repo: nil,
            path: nil,
            description: nil,
            installs: nil,
            stars: nil,
            backend: .skillsDotSh)
        #expect(SkillPreviewFetcher.candidateURLs(for: result).isEmpty)
        let preview = try await SkillPreviewFetcher(
            transport: StubMarketplaceTransport()).preview(of: result)
        #expect(preview == nil)
    }

    @Test("empty body counts as no preview")
    func emptyBody() async throws {
        let result = SkillSearchResult(
            name: "empty",
            repo: "owner/repo",
            path: "SKILL.md",
            description: nil,
            installs: nil,
            stars: nil,
            backend: .github)
        let transport = StubMarketplaceTransport(responses: [
            "https://raw.githubusercontent.com/owner/repo/HEAD/SKILL.md":
                .success(Data("".utf8))
        ])
        let preview = try await SkillPreviewFetcher(transport: transport).preview(of: result)
        #expect(preview == nil)
    }
}
