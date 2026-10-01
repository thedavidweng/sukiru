import Foundation

/// One entry of a post-run diff.
///
/// The vocabulary mirrors what an independent before/after filesystem
/// comparison can see: placements (skill-dir level), files (inside
/// snapshotted payload trees and the ledger files themselves), and semantic
/// lock-entry deltas. Every entry carries the absolute path it concerns, so
/// the boundary guarantee is auditable from the diff alone.
public struct DiffEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case placementAdded = "placement-added"
        case placementRemoved = "placement-removed"
        case placementChanged = "placement-changed"
        case fileAdded = "file-added"
        case fileRemoved = "file-removed"
        case fileChanged = "file-changed"
        case lockEntryAdded = "lock-entry-added"
        case lockEntryRemoved = "lock-entry-removed"
        case lockEntryChanged = "lock-entry-changed"
    }

    public let kind: Kind
    /// The absolute path the entry concerns (placement path, file path
    /// inside a placement, or a ledger file path).
    public let path: String
    /// Human-readable specifics: hash transitions, link-target changes,
    /// lock-entry field lists.
    public let detail: String

    public init(kind: Kind, path: String, detail: String) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

/// The post-run diff attached to every executed batch's record:
/// the measured changes of the batch, computed by
/// rescanning the affected roots and comparing against the pre-run scan and
/// the snapshot. The diff is ALWAYS present on the record — a batch that
/// changed nothing yields an explicitly empty diff, never an omitted one.
public struct BatchDiff: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Every observed change, sorted by (path, kind).
    public let entries: [DiffEntry]
    /// The human-readable rendering (one line per entry; a single explicit
    /// "no changes" line when empty).
    public let summary: [String]

    public init(
        schemaVersion: Int = BatchDiff.currentSchemaVersion,
        entries: [DiffEntry],
        summary: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.summary = summary
    }

    /// True when the batch changed nothing.
    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Deterministic JSON encoding (sorted keys), like the scan report.
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}
