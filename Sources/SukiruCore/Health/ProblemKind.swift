/// The user-facing problem a finding belongs to (Health surface grouping).
///
/// Detection rules are precise but technical (`lock-without-files`,
/// `cross-host-duplicate` with subtypes…); a person repairing a library thinks
/// in problems: "the lock lists skills that are gone", "this link is dead",
/// "this agent holds a stale copy instead of a link". Several rules can map
/// to one problem, and rules that describe a healthy layout or a standing
/// risk (alias links into the shared store, the name-based removal advisory)
/// are `note`s, never counted as problems.
///
/// Case order is the Health section order: most actionable first.
public enum ProblemKind: String, CaseIterable, Codable, Equatable, Sendable {
    /// A Vercel lock entry whose skill folder no longer exists.
    case staleLockEntry = "stale-lock-entry"
    /// A locked skill whose shared copy is gone while agents still hold
    /// their own copies or links to it.
    case missingSharedCopy = "missing-shared-copy"
    /// A symlink in a skills folder whose target is gone.
    case deadLink = "dead-link"
    /// A physical copy where a link into the shared store belongs.
    case copyInsteadOfLink = "copy-instead-of-link"
    /// Copies of one skill whose contents disagree.
    case outOfSync = "out-of-sync"
    /// A folder of links a CLI left for an agent that is not installed.
    case leftoverHostDir = "leftover-host-dir"
    /// A skill no installer ledger or agent records: no remote source.
    case orphan
    /// Two ledgers (or unexplained copies) claim the same name.
    case ownerConflict = "owner-conflict"
    /// One host discovers multiple entries for the same skill name.
    case duplicateName = "duplicate-name"
    /// A lock file written by a newer installer than Sukiru reads.
    case unsupportedLock = "unsupported-lock"
    /// Informational: expected layout or standing advisories.
    case note

    /// Classifies a finding by rule (and, for duplicates, by subtype).
    public static func of(_ finding: Finding) -> ProblemKind {
        guard finding.ruleID == "cross-host-duplicate" else {
            return byRule[finding.ruleID] ?? .note
        }
        switch finding.evidence.first(where: { $0.kind == "subtype" })?.detail {
        case "exact":
            return .copyInsteadOfLink
        case "divergent":
            return .outOfSync
        default:
            return .note
        }
    }

    private static let byRule: [String: ProblemKind] = [
        "lock-without-files": .staleLockEntry,
        MissingSharedCopyRule.ruleID: .missingSharedCopy,
        "broken-symlink": .deadLink,
        "symlink-authenticity": .copyInsteadOfLink,
        "canonical-host-divergence": .outOfSync,
        "vercel-lock-drift": .outOfSync,
        LeftoverHostRule.ruleID: .leftoverHostDir,
        "files-without-lock": .orphan,
        "double-booked": .ownerConflict,
        "ambiguous-name": .ownerConflict,
        HostNameCollisionRule.ruleID: .duplicateName,
        "lock-version-unsupported": .unsupportedLock
    ]

    /// Whether findings of this kind count as problems.
    public var isProblem: Bool {
        self != .note
    }

    /// The decision that repairs a finding with no further user input, or
    /// nil when the repair needs a choice (adoption source, surviving
    /// ledger) or there is nothing to repair. Fix All applies exactly this.
    public static func oneClickFix(for finding: Finding) -> DecisionAction? {
        switch of(finding) {
        case .staleLockEntry, .deadLink, .leftoverHostDir:
            return .cleanup
        case .copyInsteadOfLink:
            return .relink
        case .outOfSync:
            // Project drift is repaired by re-installing from the lock's
            // source; every other disagreement relinks host copies to the
            // shared store's copy.
            return finding.ruleID == "vercel-lock-drift" ? .update : .relink
        case .missingSharedCopy:
            // Reinstall and removal both rewrite or delete agent copies; the
            // user picks one.
            return nil
        case .orphan, .ownerConflict, .duplicateName, .unsupportedLock, .note:
            return nil
        }
    }
}
