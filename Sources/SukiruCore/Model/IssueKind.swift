/// Stable `Issue.kind` vocabulary (architecture §5, D18).
///
/// Issue kinds are part of the scan wire surface — validators match on these
/// strings, so they must never be renamed casually.
public enum IssueKind {
    /// A `SKILL.md` whose frontmatter fails to parse or validate.
    public static let skillMDInvalid = "skill-md-invalid"
    /// A `SKILL.md` that cannot be read at all (I/O failure, non-UTF-8 bytes).
    public static let skillMDUnreadable = "skill-md-unreadable"
    /// A lock file whose JSON cannot be parsed.
    public static let ledgerUnreadable = "ledger-unreadable"
    /// A lock file whose schema version is older (incompatible) or newer than
    /// supported (best-effort parsed).
    public static let lockVersionUnsupported = "lock-version-unsupported"
    /// A skill directory (or an entry inside it) that cannot be read for
    /// content hashing.
    public static let contentHashUnreadable = "content-hash-unreadable"
    /// A dangling symlink. The placement is still inventoried (first-class
    /// `brokenSymlink`), and a `broken-symlink` finding rides alongside.
    public static let brokenSymlink = "broken-symlink"
    /// A directory (or directory entry) that cannot be read or inspected.
    /// Never fatal: the scan continues past it.
    public static let directoryUnreadable = "directory-unreadable"
    /// realpath(3) failed on an existing placement path; the placement is
    /// kept with a nil canonical path.
    public static let canonicalPathUnreadable = "canonical-path-unreadable"
}
