import Foundation
import Yams

/// GitHub ledger provenance carried in `SKILL.md` frontmatter
/// (`metadata.github-*`, architecture §4.1).
///
/// The archive has zero `gh skill` knowledge — this side is greenfield. gh
/// writes: `github-repo` (URL without a `.git` suffix, preserved verbatim),
/// `github-path`, `github-ref` (a FULL ref such as `refs/heads/main` or
/// `refs/tags/vX`, never truncated), `github-pinned` (bool; an ABSENT key
/// means unpinned), and `github-tree-sha`.
///
/// Codable: this is also the D18 wire shape (`github: {repo, path, ref,
/// pinned, treeSha}`); nil optionals are omitted from the JSON.
public struct GitHubProvenance: Codable, Equatable, Sendable {
    /// Repository URL exactly as stored (no `.git` rewriting).
    public let repo: String
    /// Repo-relative skill path, when recorded.
    public let path: String?
    /// Full git ref, when recorded.
    public let ref: String?
    /// Pin state; absent or non-bool `github-pinned` means unpinned.
    public let pinned: Bool
    /// Recorded tree SHA, when present.
    public let treeSha: String?

    public init(repo: String, path: String?, ref: String?, pinned: Bool, treeSha: String?) {
        self.repo = repo
        self.path = path
        self.ref = ref
        self.pinned = pinned
        self.treeSha = treeSha
    }
}

/// Reads `metadata.github-*` from an already-parsed frontmatter mapping.
///
/// Presence of a non-empty `github-repo` string IS the gh-ledger claim
/// (architecture §6); without it the other `github-*` keys are ignored.
public enum GitHubProvenanceReader {
    /// Extracts the provenance claim, or nil when `github-repo` is absent.
    public static func provenance(in frontmatter: Node.Mapping) -> GitHubProvenance? {
        guard let metadataNode = frontmatter["metadata"],
            case .mapping(let metadata) = metadataNode,
            let repo = FrontmatterParser.scalarString(metadata["github-repo"])
        else {
            return nil
        }
        return GitHubProvenance(
            repo: repo,
            path: FrontmatterParser.scalarString(metadata["github-path"]),
            ref: FrontmatterParser.scalarString(metadata["github-ref"]),
            pinned: FrontmatterParser.bool(metadata["github-pinned"]) ?? false,
            treeSha: FrontmatterParser.scalarString(metadata["github-tree-sha"])
        )
    }
}
