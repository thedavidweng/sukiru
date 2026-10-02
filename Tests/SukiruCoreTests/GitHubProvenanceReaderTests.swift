import Foundation
import Testing

@testable import SukiruCore

/// GitHub provenance extraction from `metadata.github-*` frontmatter keys
/// `github-repo` presence IS the gh-ledger claim; the pin
/// state is tri-state where an absent key means unpinned, and gh writes the
/// pin VALUE (a ref string), not a bool.
@Suite("GitHub provenance reader")
struct GitHubProvenanceReaderTests {
    private let parser = FrontmatterParser()

    private func readProvenance(_ tree: TempTree, _ metadata: String) throws -> GitHubProvenance? {
        let yaml = "---\nname: demo\ndescription: d\nmetadata:\n\(metadata)\n---\n"
        let path = try tree.file("demo-\(UUID().uuidString)/SKILL.md", contents: yaml)
        guard case .success(let parsed) = parser.parse(skillFileAt: path) else {
            return nil
        }
        return parsed.githubProvenance
    }

    @Test("Full provenance is extracted verbatim, with gh's real pin format")
    func fullProvenance() throws {
        let tree = try TempTree()
        // The shape gh 2.102.0 writes for `gh skill install --pin v1.2.3`:
        // `github-pinned` holds the pin value and `github-ref` the resolved
        // ref (probe-verified in docs/collision-matrix.md, 2026-10-02).
        let metadata = """
              github-repo: https://github.com/owner/repo
              github-path: skills/demo
              github-ref: v1.2.3
              github-pinned: v1.2.3
              github-tree-sha: 0123456789abcdef0123456789abcdef01234567
            """
        let parsed = try #require(try readProvenance(tree, metadata))
        #expect(parsed.repo == "https://github.com/owner/repo")
        #expect(parsed.path == "skills/demo")
        #expect(parsed.ref == "v1.2.3")
        #expect(parsed.pinned)
        #expect(parsed.pinnedRef == "v1.2.3")
        #expect(parsed.treeSha == "0123456789abcdef0123456789abcdef01234567")
    }

    @Test("A legacy bool github-pinned reads as pinned with no ref")
    func legacyBoolPinned() throws {
        let tree = try TempTree()
        let parsed = try #require(
            try readProvenance(
                tree, "  github-repo: https://github.com/o/r\n  github-pinned: true")
        )
        #expect(parsed.pinned)
        #expect(parsed.pinnedRef == nil)
    }

    @Test("The repo URL is preserved exactly as stored (no .git rewriting)")
    func repoPreservedVerbatim() throws {
        let tree = try TempTree()
        let parsed = try #require(try readProvenance(tree, "  github-repo: https://github.com/o/r"))
        #expect(parsed.repo == "https://github.com/o/r")
        #expect(parsed.path == nil)
        #expect(parsed.ref == nil)
        #expect(!parsed.pinned)
        #expect(parsed.treeSha == nil)
    }

    @Test("An absent github-pinned key means unpinned")
    func absentPinnedIsUnpinned() throws {
        let tree = try TempTree()
        let parsed = try #require(
            try readProvenance(
                tree, "  github-repo: https://github.com/o/r\n  github-ref: refs/tags/v1")
        )
        #expect(!parsed.pinned)
        #expect(parsed.ref == "refs/tags/v1")
    }

    @Test("A string github-pinned value is the pin ref, even one spelling a bool")
    func stringPinnedIsTheRef() throws {
        let tree = try TempTree()
        // gh only ever writes the user's --pin value here, so a quoted
        // string is a ref, not a bool — "true" included.
        let parsed = try #require(
            try readProvenance(
                tree, "  github-repo: https://github.com/o/r\n  github-pinned: \"true\"")
        )
        #expect(parsed.pinned)
        #expect(parsed.pinnedRef == "true")
    }

    @Test("No github-repo key means no gh-ledger claim")
    func noRepoNoClaim() throws {
        let tree = try TempTree()
        let metadata = "  github-path: skills/demo\n  github-ref: refs/heads/main\n  internal: true"
        let parsed = try #require(
            parser.parse(
                skillFileAt: tree.file(
                    "plain/SKILL.md",
                    contents: "---\nname: demo\ndescription: d\nmetadata:\n\(metadata)\n---\n"
                )
            ).successValue)
        #expect(parsed.githubProvenance == nil)
        #expect(parsed.internal)
    }

    @Test("No metadata block means no provenance")
    func noMetadata() throws {
        let tree = try TempTree()
        let path = try tree.file(
            "plain/SKILL.md", contents: "---\nname: demo\ndescription: d\n---\n")
        let parsed = try #require(parser.parse(skillFileAt: path).successValue)
        #expect(parsed.githubProvenance == nil)
    }
}
