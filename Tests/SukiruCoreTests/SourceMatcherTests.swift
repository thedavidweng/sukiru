import Foundation
import Testing

@testable import SukiruCore

/// Source matching for ownerless skills: same-name skills.sh listings,
/// ranked by how closely their published SKILL.md matches the local copy.
@Suite("Source matcher")
struct SourceMatcherTests {
    private static let local =
        "---\nname: notes\n---\n" + (1...10).map { "line \($0)" }.joined(separator: "\n")

    private static func searchURL(_ name: String) -> String {
        "https://skills.sh/api/search?q=\(name)&limit=50"
    }

    private static func listing(_ source: String, installs: Int, name: String = "notes") -> String {
        #"{"id":"\#(source)/\#(name)","skillId":"\#(name)","name":"\#(name)","#
            + #""installs":\#(installs),"source":"\#(source)"}"#
    }

    private static func search(_ listings: [String]) -> Result<Data, MarketplaceError> {
        .success(Data(#"{"skills":[\#(listings.joined(separator: ","))]}"#.utf8))
    }

    private static func raw(_ repo: String, _ path: String) -> String {
        "https://raw.githubusercontent.com/\(repo)/HEAD/\(path)"
    }

    @Test("A matching SKILL.md outranks a more popular unrelated listing")
    func identicalWins() async throws {
        let transport = StubMarketplaceTransport(responses: [
            Self.searchURL("notes"): Self.search([
                Self.listing("popular/fork", installs: 900),
                Self.listing("origin/notes", installs: 10),
                Self.listing("other/notes", installs: 5, name: "notes-pro")
            ]),
            Self.raw("popular/fork", "skills/notes/SKILL.md"): .success(Data("unrelated".utf8)),
            Self.raw("origin/notes", "skills/notes/SKILL.md"): .success(Data(Self.local.utf8))
        ])
        let candidates = try await SourceMatcher(transport: transport)
            .candidates(name: "notes", localSkillMD: Self.local)
        #expect(candidates.map(\.result.repo) == ["origin/notes", "popular/fork"])
        #expect(candidates.map(\.match) == [.identical, .unverified])
        #expect(candidates[0].installSource == "origin/notes")
    }

    @Test("A popular listing at another version beats a stale identical fork")
    func popularSimilarWins() async throws {
        let transport = StubMarketplaceTransport(responses: [
            Self.searchURL("notes"): Self.search([
                Self.listing("stale/fork", installs: 5),
                Self.listing("origin/notes", installs: 900)
            ]),
            Self.raw("origin/notes", "skills/notes/SKILL.md"):
                .success(Data((Self.local + "\nline 11").utf8)),
            Self.raw("stale/fork", "skills/notes/SKILL.md"): .success(Data(Self.local.utf8))
        ])
        let candidates = try await SourceMatcher(transport: transport)
            .candidates(name: "notes", localSkillMD: Self.local)
        #expect(candidates.map(\.result.repo) == ["origin/notes", "stale/fork"])
        #expect(candidates.map(\.match) == [.similar, .unverified])
    }

    @Test("Another version of the same file counts as similar")
    func similarVersion() {
        let newer = Self.local + "\nline 11"
        #expect(SourceMatcher.match(local: Self.local, remote: newer) == .similar)
        #expect(
            SourceMatcher.match(local: Self.local, remote: Self.local + "\n\n") == .identical)
        #expect(
            SourceMatcher.match(
                local: Self.local.replacingOccurrences(of: "\n", with: "\r\n"),
                remote: Self.local) == .identical)
        #expect(SourceMatcher.match(local: Self.local, remote: "other") == .unverified)
    }

    @Test("GitHub repositories are checked before domains; domains use HTTPS")
    func domainSources() async throws {
        let transport = StubMarketplaceTransport(responses: [
            Self.searchURL("notes"): Self.search([
                Self.listing("docs.example.com", installs: 900),
                Self.listing("origin/notes", installs: 10)
            ]),
            "https://docs.example.com/.well-known/skills/notes/SKILL.md":
                .success(Data(Self.local.utf8))
        ])
        let candidates = try await SourceMatcher(transport: transport)
            .candidates(name: "notes", localSkillMD: Self.local)
        #expect(candidates.map(\.result.repo) == ["docs.example.com", "origin/notes"])
        #expect(candidates[0].match == .identical)
        #expect(candidates[0].installSource == "https://docs.example.com")
    }
}
