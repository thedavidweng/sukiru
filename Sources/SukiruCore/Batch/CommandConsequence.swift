import Foundation

/// What a destructive-by-design command does beyond its argv.
///
/// The case is the language-neutral source of truth: `BatchCommand` stores
/// it beside the English `text` so presentation layers can localize it while
/// the wire format and CLI keep the English rendering.
public enum CommandConsequence: Codable, Equatable, Sendable {
    /// A re-install from the recorded source discards local edits.
    case resetsToUpstream
    /// As `resetsToUpstream`, and the re-install erases gh frontmatter
    /// provenance (keep-vercel arbitration).
    case resetsToUpstreamErasingGitHubProvenance
    /// A gh re-install resets content to the recorded ref (keep-github arbitration).
    case resetsToGitHubRef
    /// gh adoption merge-overwrites the existing directory.
    case mergeOverwritesCollidingFiles
    /// Vercel adoption replaces local copies with links to a fresh shared copy.
    case replacesCopiesWithSharedLinks
    /// `npx skills remove` of a stale lock entry touches no skill files.
    case removesOnlyStaleLockEntry(skill: String)
    /// A re-install restores a locked skill's missing shared copy; the
    /// listed placements become links to it.
    case restoresSharedCopy(replacing: [String])
    /// `npx skills remove` drops the lock entry and deletes every listed
    /// placement, agent-made copies included.
    case removesLockedSkill(skill: String, deleting: [String])
    /// A new install enters the Vercel lockfile ledger.
    case entersVercelLedger
    /// A new install writes gh provenance into the frontmatter.
    case writesGitHubProvenance(agent: String, pinRef: String?)

    /// The English rendering written to batch files and CLI output.
    public var text: String {
        switch self {
        case .resetsToUpstream:
            return "Content resets to upstream; local edits are lost."
        case .resetsToUpstreamErasingGitHubProvenance:
            return "Content resets to upstream; local edits are lost. The "
                + "re-install erases the GitHub frontmatter provenance."
        case .resetsToGitHubRef:
            return "Content resets to the gh-recorded ref; local edits are lost."
        case .mergeOverwritesCollidingFiles:
            return "If upstream content differs from the on-disk payload, "
                + "merge-overwrite keeps extra local files but overwrites colliding "
                + "ones."
        case .replacesCopiesWithSharedLinks:
            return "Local copies are replaced by the source's version, linked "
                + "from the shared skills folder; local edits survive only in the "
                + "batch snapshot."
        case .removesOnlyStaleLockEntry(let skill):
            return "Only the lock entry and dead links named '\(skill)' are removed; "
                + "no skill files of that name exist in this scope."
        case .restoresSharedCopy(let paths):
            return "The shared copy is re-installed from the lock's source, and these "
                + "become links to it (their current content survives only in the batch "
                + "snapshot): \(paths.joined(separator: ", "))."
        case .removesLockedSkill(let skill, let paths):
            return "The lock entry for '\(skill)' is removed and these are deleted, "
                + "including copies an agent made itself: \(paths.joined(separator: ", "))."
        case .entersVercelLedger:
            return "Installing with npx skills enters the skill into the Vercel lockfile"
                + " ledger: the canonical copy lands in .agents/skills and host "
                + "placements follow the CLI's default agent coverage."
        case .writesGitHubProvenance(let agent, let pinRef):
            var text =
                "Installing with gh writes GitHub provenance into the skill's "
                + "frontmatter (metadata.github-*): GitHub-only sources, installed "
                + "for agent \(agent)."
            if let pinRef, !pinRef.isEmpty {
                text += " Pinned to \(pinRef)."
            }
            return text
        }
    }
}
