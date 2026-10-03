import Foundation
import Testing

@testable import SukiruCore

/// The raw SKILL.md preview fetcher: exact URL for gh results
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
            transport: StubMarketplaceTransport()
        ).preview(of: result)
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

    private func listing(_ repo: String, slug: String, name: String? = nil) -> SkillSearchResult {
        SkillSearchResult(
            name: name ?? slug, repo: repo, path: nil, description: nil, installs: 1, stars: nil,
            backend: .skillsDotSh, slug: slug)
    }

    @Test("a skills.sh result reads the skill from the download API, by slug")
    func downloadAPI() async throws {
        let body = """
            {"files": [
              {"path": "scripts/run.py", "contents": "print()"},
              {"path": "SKILL.md", "contents": "---\\nname: c-code-formatter\\n---\\nbody"},
              {"path": "agents/openai.yaml", "contents": "x"},
              {"path": "docs/SKILL.md", "contents": "nested"}
            ], "hash": "abc"}
            """
        let result = listing(
            "calcitem/sanmill", slug: "c-code-formatter", name: "C++ Code Formatter")
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/download/calcitem/sanmill/c-code-formatter":
                .success(Data(body.utf8))
        ])
        let preview = await SkillPreviewFetcher(transport: transport).skill(of: result)
        #expect(preview?.skillMD == "---\nname: c-code-formatter\n---\nbody")
        #expect(preview?.files == ["agents/openai.yaml", "docs/SKILL.md", "scripts/run.py"])
    }

    @Test("a missing download falls back to the raw locations, named by slug")
    func downloadFallback() async throws {
        let result = listing("owner/repo", slug: "notes", name: "Notes")
        let transport = StubMarketplaceTransport(responses: [
            "https://skills.sh/api/download/owner/repo/notes":
                .failure(MarketplaceError.transport("HTTP 404: not_found")),
            "https://raw.githubusercontent.com/owner/repo/HEAD/skills/notes/SKILL.md":
                .success(Data("raw".utf8))
        ])
        let preview = await SkillPreviewFetcher(transport: transport).skill(of: result)
        #expect(preview == SkillPreview(skillMD: "raw"))
    }

    @Test("download URLs encode each part and skip domain sources")
    func downloadURLs() {
        #expect(
            SkillPreviewFetcher.downloadURL(for: listing("a b/r", slug: "x/y"))?.absoluteString
                == "https://skills.sh/api/download/a%20b/r/x%2Fy")
        #expect(
            SkillPreviewFetcher.downloadURL(for: listing("open.feishu.cn", slug: "lark-doc")) == nil
        )
        #expect(
            SkillPreviewFetcher.candidateURLs(for: listing("open.feishu.cn", slug: "lark-doc"))
                .map(\.absoluteString)
                == ["https://open.feishu.cn/.well-known/skills/lark-doc/SKILL.md"])
    }

    @Test("a download without a root SKILL.md is not a preview")
    func downloadWithoutSkillMD() {
        let body = Data(#"{"files": [{"path": "docs/SKILL.md", "contents": "x"}]}"#.utf8)
        #expect(SkillPreviewFetcher.preview(fromDownload: body) == nil)
        #expect(SkillPreviewFetcher.preview(fromDownload: Data("<html>".utf8)) == nil)
    }

    @Test("results link to their skills.sh page or GitHub file")
    func webURLs() {
        #expect(
            listing("MattPocock/Skills", slug: "Grill-Me").webURL?.absoluteString
                == "https://skills.sh/mattpocock/skills/grill-me")
        #expect(
            listing("open.feishu.cn", slug: "lark-doc").webURL?.absoluteString
                == "https://skills.sh/site/open.feishu.cn/lark-doc")
        let ghResult = SkillSearchResult(
            name: "a", repo: "o/r", path: "skills/a/SKILL.md", description: nil, installs: nil,
            stars: 1, backend: .github)
        #expect(
            ghResult.webURL?.absoluteString == "https://github.com/o/r/blob/HEAD/skills/a/SKILL.md")
    }

    @Test("fetched SKILL.md text yields its name and description")
    func summary() {
        let text = "---\nname: grill-me\ndescription: Interview me.\n---\nbody"
        #expect(FrontmatterParser.summary(ofSkillMD: text)?.description == "Interview me.")
        #expect(SkillPreview(skillMD: text).description == "Interview me.")
        #expect(FrontmatterParser.summary(ofSkillMD: "no frontmatter") == nil)
        #expect(FrontmatterParser.summary(ofSkillMD: "---\nname: x\n---\n") == nil)
    }
}
