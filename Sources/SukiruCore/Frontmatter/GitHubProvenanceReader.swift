import Foundation
import Yams

/// GitHub ledger provenance carried in `SKILL.md` frontmatter
/// (`metadata.github-*`).
///
/// The archive has zero `gh skill` knowledge — this side is greenfield. gh
/// writes: `github-repo` (URL without a `.git` suffix, preserved verbatim),
/// `github-path`, `github-ref` (a FULL ref such as `refs/heads/main` or
/// `refs/tags/vX`, never truncated), `github-pinned`, and `github-tree-sha`.
/// `github-pinned` holds the user's `--pin` VALUE (a tag, branch, or commit
/// SHA string; an ABSENT key means unpinned) — probe-verified against gh
/// 2.102.0 and its `frontmatter.InjectGitHubMetadata` source. A legacy bool
/// `true` (Sukiru's own early fixtures) also reads as pinned.
///
/// Codable: this is also the wire shape (`github: {repo, path, ref,
/// pinned, pinnedRef, treeSha}`); nil optionals are omitted from the JSON.
public struct GitHubProvenance: Codable, Equatable, Sendable {
    /// Repository URL exactly as stored (no `.git` rewriting).
    public let repo: String
    /// Repo-relative skill path, when recorded.
    public let path: String?
    /// Full git ref, when recorded.
    public let ref: String?
    /// Pin state: `github-pinned` carries a ref string (gh's real format) or
    /// a legacy bool `true`; absent or bool `false` means unpinned.
    public let pinned: Bool
    /// The pinned ref, when `github-pinned` recorded it as a string.
    public let pinnedRef: String?
    /// Recorded tree SHA, when present.
    public let treeSha: String?

    public init(
        repo: String, path: String?, ref: String?, pinned: Bool, pinnedRef: String? = nil,
        treeSha: String?
    ) {
        self.repo = repo
        self.path = path
        self.ref = ref
        self.pinned = pinned
        self.pinnedRef = pinnedRef
        self.treeSha = treeSha
    }
}

/// Reads `metadata.github-*` from an already-parsed frontmatter mapping.
///
/// Presence of a non-empty `github-repo` string IS the gh-ledger claim;
/// without it the other `github-*` keys are ignored.
public enum GitHubProvenanceReader {
    /// Extracts the provenance claim, or nil when `github-repo` is absent.
    public static func provenance(in frontmatter: Node.Mapping) -> GitHubProvenance? {
        guard let metadataNode = frontmatter["metadata"],
            case .mapping(let metadata) = metadataNode,
            let repo = FrontmatterParser.scalarString(metadata["github-repo"])
        else {
            return nil
        }
        // gh writes `github-pinned: <pin value>` (a string); only a
        // bool-tagged node is read as the legacy bool form, so a string
        // that happens to spell "true"/"false" still reads as a ref.
        let pinnedNode = metadata["github-pinned"]
        let pinnedBool = FrontmatterParser.bool(pinnedNode)
        let pinnedRef = pinnedBool == nil ? FrontmatterParser.scalarString(pinnedNode) : nil
        return GitHubProvenance(
            repo: repo,
            path: FrontmatterParser.scalarString(metadata["github-path"]),
            ref: FrontmatterParser.scalarString(metadata["github-ref"]),
            pinned: pinnedBool ?? (pinnedRef != nil),
            pinnedRef: pinnedRef,
            treeSha: FrontmatterParser.scalarString(metadata["github-tree-sha"])
        )
    }
}
