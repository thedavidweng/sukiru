/// Per-ledger provenance surfaced on a skill.
///
/// Provenance is DATA, not a verdict: an ambiguous name keeps its ledger
/// claims visible here while `ownership` stays voided.
public struct SkillProvenance: Codable, Equatable, Sendable {
    /// The Vercel lock claim, when the skill's scope lock carries its name.
    public let vercel: VercelProvenance?
    /// The gh ledger claim, when a placement carries `metadata.github-repo`.
    public let github: GitHubProvenance?

    public init(vercel: VercelProvenance?, github: GitHubProvenance?) {
        self.vercel = vercel
        self.github = github
    }
}

/// The Vercel lock entry as surfaced on a skill.
///
/// The hash key is scope-correct: a PROJECT lock entry exposes
/// `computedHash` and never `skillFolderHash`; a GLOBAL entry exposes
/// `skillFolderHash` and never `computedHash`. Nil optionals are omitted from
/// the wire JSON entirely (synthesized Codable drops them).
public struct VercelProvenance: Codable, Equatable, Sendable {
    public let source: String?
    public let sourceType: String?
    public let sourceUrl: String?
    public let ref: String?
    public let skillPath: String?
    /// Project-scope content hash (nil for global-scope entries).
    public let computedHash: String?
    /// Global-scope git tree SHA (nil for project-scope entries).
    public let skillFolderHash: String?
    public let installedAt: String?
    public let updatedAt: String?
    /// Unknown entry-level keys, preserved verbatim. Nil when
    /// the entry carries none, so the key is omitted from the wire JSON.
    public let extras: [String: JSONValue]?

    /// Projects the lock entry onto the wire shape for its lock's scope.
    public init(entry: VercelLockEntry, scope: VercelLock.Scope) {
        source = entry.source
        sourceType = entry.sourceType
        sourceUrl = entry.sourceUrl
        ref = entry.ref
        skillPath = entry.skillPath
        switch scope {
        case .project:
            computedHash = entry.computedHash
            skillFolderHash = nil
        case .global:
            computedHash = nil
            skillFolderHash = entry.skillFolderHash
        }
        installedAt = entry.installedAt
        updatedAt = entry.updatedAt
        extras = entry.extras.isEmpty ? nil : entry.extras
    }
}
