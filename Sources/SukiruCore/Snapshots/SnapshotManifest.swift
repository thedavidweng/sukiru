import Foundation

/// The on-disk manifest of one snapshot (architecture §4.1 SnapshotStore,
/// D9): what existed before the batch ran — both ledger files byte-exact,
/// every placement of the affected scopes, and full payload copies of every
/// skill directory the batch may touch.
///
/// Serialized as deterministic JSON (sorted keys) at
/// `<snapshotsRoot>/<id>/manifest.json`.
public struct SnapshotManifest: Codable, Equatable, Sendable {
    /// Schema 2 adds `preExistingDirectories`; schema-1 manifests do not
    /// decode (no cross-schema restore, same pre-release posture as
    /// ExecutionRecord schema 2).
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    /// The snapshot id; equals its directory name under the snapshots root.
    public let id: String
    /// The batch this snapshot protects (correlates with batch history).
    public let batchID: String
    /// ISO-8601 capture timestamp.
    public let createdAt: String
    /// Ledger file records, sorted by path.
    public let ledgers: [LedgerSnapshot]
    /// The placement manifest (VAL-REPAIR-024), sorted by path.
    public let placements: [PlacementSnapshot]
    /// Full payload copies of touched skill dirs, sorted by original path.
    public let payloads: [PayloadSnapshot]
    /// Directories swept for batch-added children at restore time: the
    /// parent directory of every recorded placement, sorted.
    public let watchedDirectories: [String]
    /// Container dirs of the affected scope that existed at capture time —
    /// including EMPTY ones with zero placements (e.g. an empty
    /// `~/.qoder/skills`). Restore adds them to the empty-ancestor pruning
    /// stop set so a spray rollback never deletes pre-existing containers
    /// (VAL-REPAIR-034 byte-equality). Sorted.
    public let preExistingDirectories: [String]

    public init(
        schemaVersion: Int,
        id: String,
        batchID: String,
        createdAt: String,
        ledgers: [LedgerSnapshot],
        placements: [PlacementSnapshot],
        payloads: [PayloadSnapshot],
        watchedDirectories: [String],
        preExistingDirectories: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.batchID = batchID
        self.createdAt = createdAt
        self.ledgers = ledgers
        self.placements = placements
        self.payloads = payloads
        self.watchedDirectories = watchedDirectories
        self.preExistingDirectories = preExistingDirectories
    }
}

/// One ledger file's pre-batch state: byte-exact copy when it existed, an
/// explicit absent record otherwise (so rollback deletes a batch-created
/// lock at that path).
public struct LedgerSnapshot: Codable, Equatable, Sendable {
    /// Absolute path of the ledger file (XDG-resolved).
    public let path: String
    public let existed: Bool
    /// Snapshot-relative path of the byte copy (`ledgers/<n>`), iff existed.
    public let storedFile: String?
    /// SHA-256 hex of the captured bytes, iff existed.
    public let sha256: String?

    public init(path: String, existed: Bool, storedFile: String?, sha256: String?) {
        self.path = path
        self.existed = existed
        self.storedFile = storedFile
        self.sha256 = sha256
    }
}

/// One placement of the pre-run scan (VAL-REPAIR-024: path, kind, link
/// target, content hash), carried verbatim from the ScanReport.
public struct PlacementSnapshot: Codable, Equatable, Sendable {
    public let path: String
    public let kind: Placement.Kind
    public let linkTarget: String?
    /// The scan's content hash for the placement (nil when the scan had
    /// none, e.g. broken symlinks).
    public let hash: String?

    public init(path: String, kind: Placement.Kind, linkTarget: String?, hash: String?) {
        self.path = path
        self.kind = kind
        self.linkTarget = linkTarget
        self.hash = hash
    }
}

/// A full recursive copy of one skill directory the batch may touch
/// (VAL-REPAIR-025/050), stored at a snapshot-relative path.
public struct PayloadSnapshot: Codable, Equatable, Sendable {
    /// Absolute path of the skill directory on disk.
    public let path: String
    /// Snapshot-relative directory holding the copy (`payloads/<n>`).
    public let storedDir: String
    /// Deterministic digest of the stored tree (PayloadTree.digest).
    public let digest: String

    public init(path: String, storedDir: String, digest: String) {
        self.path = path
        self.storedDir = storedDir
        self.digest = digest
    }
}

/// A snapshot-store listing entry (VAL-REPAIR-026 history correlation).
public struct SnapshotSummary: Codable, Equatable, Sendable {
    public let id: String
    public let batchID: String
    public let createdAt: String

    public init(id: String, batchID: String, createdAt: String) {
        self.id = id
        self.batchID = batchID
        self.createdAt = createdAt
    }
}

/// One restored or deleted path in a rollback record. The three categories
/// are exactly the VAL-REPAIR-036 vocabulary; there is no
/// "compensated-via-CLI" category in v1 (D9).
public struct RestoreItem: Codable, Equatable, Sendable {
    public enum Category: String, Codable, Equatable, Sendable {
        case restoredFromSnapshot = "restored-from-snapshot"
        case deletedBatchAdded = "deleted-batch-added"
        case unrestorableWithReason = "unrestorable-with-reason"
    }

    public let path: String
    public let category: Category
    /// The failure detail, present iff category is `unrestorableWithReason`.
    public let reason: String?

    public init(path: String, category: Category, reason: String?) {
        self.path = path
        self.category = category
        self.reason = reason
    }
}

/// The itemized outcome of a restore, sorted by path.
public struct RestoreRecord: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let batchID: String
    public let items: [RestoreItem]

    public init(snapshotID: String, batchID: String, items: [RestoreItem]) {
        self.snapshotID = snapshotID
        self.batchID = batchID
        self.items = items
    }
}

/// Snapshot-store failures. Capture failures are total: nothing is committed
/// and the batch must not execute (the snapshot is the safety gate).
public enum SnapshotError: Error, Equatable, Sendable {
    /// The id is not a single safe path component.
    case invalidSnapshotID(String)
    /// No committed snapshot with this id exists.
    case snapshotNotFound(String)
    /// The manifest.json is missing, malformed, or names a different id.
    case manifestUnreadable(String)
    /// A manifest stored path is absolute or escapes the snapshot directory.
    case unsafeManifestEntry(String)
    /// A ledger or payload could not be captured; nothing was committed.
    case captureFailed(String)
}
