import Foundation

/// Scope selector for a scan.
public enum Scope: String, Codable, Equatable, Sendable, CaseIterable {
    case user
    case project
    case all

    /// Whether a workspace of the given kind belongs to this scope.
    public func includes(_ kind: Workspace.Kind) -> Bool {
        switch self {
        case .user:
            return kind == .user
        case .project:
            return kind == .project
        case .all:
            return true
        }
    }
}

/// The read-only scan report, serialized with the stable wire schema.
///
public struct ScanReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let workspaces: [Workspace]
    public let skills: [Skill]
    public let findings: [Finding]
    public let issues: [Issue]
    /// Unknown TOP-LEVEL lock keys, preserved verbatim, keyed
    /// by the scope's ownership-bucket/canonical workspace id (`user` /
    /// `project:<root>`). Nil when no read lock carries unknown keys, so the
    /// key is omitted from the wire JSON (the schema stays additive).
    public let lockExtras: [String: [String: JSONValue]]?

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = ScanReport.currentSchemaVersion,
        workspaces: [Workspace] = [],
        skills: [Skill] = [],
        findings: [Finding] = [],
        issues: [Issue] = [],
        lockExtras: [String: [String: JSONValue]]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.skills = skills
        self.findings = findings
        self.issues = issues
        self.lockExtras = lockExtras
    }

    /// Deterministic JSON encoding (sorted keys) so identical scans yield
    /// byte-identical output.
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}

/// A scanned workspace (`{id, kind, root, installed}`).
public struct Workspace: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case user
        case project
    }

    public let id: String
    public let kind: Kind
    public let root: String
    public let installed: Bool

    public init(id: String, kind: Kind, root: String, installed: Bool) {
        self.id = id
        self.kind = kind
        self.root = root
        self.installed = installed
    }
}

/// Ownership classes.
public enum Ownership: String, Codable, Equatable, Sendable {
    case vercel
    case github
    case doubleBooked = "double-booked"
    case ownerless
    /// Neither installer ledger claims the skill, but the agent host that
    /// holds it manages it through its own ledger (`managingAgent`).
    case agent
}

/// One logical skill, collapsing alias placements.
///
/// `ownership` is the resolved verdict; `provenance` carries
/// the raw per-ledger claims as data — for an ambiguous name the claims stay
/// visible while ownership is voided to `ownerless`.
public struct Skill: Codable, Equatable, Sendable {
    public let name: String
    public let scope: Scope
    public let ownership: Ownership
    public let ambiguous: Bool
    public let provenance: SkillProvenance
    public let placements: [Placement]
    /// The host id behind `Ownership.agent`; omitted from the wire otherwise.
    public let managingAgent: String?
}

/// A physical placement of a skill on disk.
public struct Placement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case directory
        case symlink
        case brokenSymlink
    }

    public let path: String
    public let kind: Kind
    public let linkTarget: String?
    public let canonicalPath: String?
    public let contentHash: String?
    public let `internal`: Bool
    /// The host that manages this physical directory through its own
    /// ledger (`AgentManagedDirectories`); omitted from the wire otherwise.
    public let managingAgent: String?
}

/// Detection-rule severities.
public enum Severity: String, Codable, Equatable, Sendable {
    case action
    case warning
    case info
}

/// A single piece of structured evidence backing a finding.
public struct Evidence: Codable, Equatable, Sendable {
    public let kind: String
    public let detail: String
}

/// A health finding.
public struct Finding: Codable, Equatable, Sendable {
    public let ruleID: String
    public let severity: Severity
    public let skillName: String?
    public let workspaceID: String
    public let evidence: [Evidence]
}

/// A non-fatal problem surfaced during a scan (`{kind, path, message}`).
///
/// `Error` conformance lets parsers hand issues back through `Result` without
/// wrapping; semantically an issue is always data, never a thrown failure.
public struct Issue: Codable, Hashable, Sendable, Error {
    public let kind: String
    public let path: String
    public let message: String
}
