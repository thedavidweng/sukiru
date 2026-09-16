import Foundation

/// Ledger diffing for the Differ: byte-level changes of the lock files
/// (compared against the snapshot's byte-exact copies) plus semantic
/// lock-entry deltas parsed from both versions.
extension Differ {
    /// Per-ledger entries: file added/removed/changed, plus lock-entry
    /// added/removed/changed rows whenever both versions parse.
    func ledgerEntries(manifest: SnapshotManifest) -> [DiffEntry] {
        let snapshotDir = HostPathResolver.join(
            SnapshotStore(environment: environment).snapshotsRoot(), manifest.id)
        var entries: [DiffEntry] = []
        for ledger in manifest.ledgers {
            let postBytes = FileManager.default.contents(atPath: ledger.path)
            if ledger.existed {
                guard let stored = ledger.storedFile,
                    let preBytes = FileManager.default.contents(
                        atPath: HostPathResolver.join(snapshotDir, stored))
                else {
                    entries.append(
                        DiffEntry(
                            kind: .fileChanged, path: ledger.path,
                            detail: "snapshot ledger copy unreadable; byte "
                                + "comparison unavailable"))
                    continue
                }
                guard let postBytes else {
                    entries.append(
                        DiffEntry(
                            kind: .fileRemoved, path: ledger.path,
                            detail: "ledger file deleted"))
                    continue
                }
                if SnapshotStore.sha256Hex(postBytes) != ledger.sha256 {
                    entries.append(
                        DiffEntry(
                            kind: .fileChanged, path: ledger.path,
                            detail: "ledger bytes changed"))
                }
                entries += Self.lockEntryDeltas(
                    path: ledger.path, pre: preBytes, post: postBytes)
            } else if let postBytes {
                entries.append(
                    DiffEntry(
                        kind: .fileAdded, path: ledger.path,
                        detail: "ledger file created"))
                entries += Self.lockEntryDeltas(path: ledger.path, pre: nil, post: postBytes)
            }
        }
        return entries
    }

    /// Lock-entry deltas between two ledger versions. A nil `Data` is an
    /// ABSENT file (empty lock); an undecodable present file suppresses the
    /// semantic delta (the byte-level entry already carries the change).
    static func lockEntryDeltas(path: String, pre: Data?, post: Data?) -> [DiffEntry] {
        guard let before = lockEntries(pre), let after = lockEntries(post) else {
            return []
        }
        var entries: [DiffEntry] = []
        for name in after.keys where before[name] == nil {
            entries.append(
                DiffEntry(
                    kind: .lockEntryAdded, path: path,
                    detail: "lock entry added: skill '\(name)'"))
        }
        for name in before.keys where after[name] == nil {
            entries.append(
                DiffEntry(
                    kind: .lockEntryRemoved, path: path,
                    detail: "lock entry removed: skill '\(name)'"))
        }
        for (name, old) in before {
            guard let new = after[name] else {
                continue
            }
            let fields = changedFields(old, new)
            if !fields.isEmpty {
                entries.append(
                    DiffEntry(
                        kind: .lockEntryChanged, path: path,
                        detail: "lock entry updated: skill '\(name)' "
                            + "(changed: \(fields.joined(separator: ", ")))"))
            }
        }
        return entries
    }

    /// The skill entries of a ledger body, nil when the bytes do not parse
    /// as a lock. Absent file (nil data) parses as an empty entry set.
    private static func lockEntries(_ data: Data?) -> [String: VercelLockEntry]? {
        guard let data else {
            return [:]
        }
        // The scope argument only affects version bookkeeping, not entry
        // parsing; deltas diff entries either way.
        return VercelLockReader.decode(data, scope: .global)?.entries
    }

    /// Names of the fields that differ between two versions of an entry,
    /// in a defined order.
    static func changedFields(_ old: VercelLockEntry, _ new: VercelLockEntry) -> [String] {
        var fields = Self.stringFields.filter { field in
            old[keyPath: field.path] != new[keyPath: field.path]
        }.map(\.name)
        if old.extras != new.extras {
            fields.append("extras")
        }
        return fields
    }

    // The comparable string fields of a lock entry, in diff-report order.
    // A computed property: KeyPath is not Sendable, so a stored static let
    // would trip Swift 6 global-state concurrency checks.
    // swift-format requires the trailing comma swiftlint forbids in
    // multi-line collection literals — suppressed for this field table only.
    // swiftlint:disable trailing_comma
    private static var stringFields: [(name: String, path: KeyPath<VercelLockEntry, String?>)] {
        [
            ("source", \.source),
            ("sourceType", \.sourceType),
            ("sourceUrl", \.sourceUrl),
            ("ref", \.ref),
            ("skillPath", \.skillPath),
            ("computedHash", \.computedHash),
            ("skillFolderHash", \.skillFolderHash),
            ("installedAt", \.installedAt),
            ("updatedAt", \.updatedAt),
            ("pluginName", \.pluginName),
            ("sourceBaseUrl", \.sourceBaseUrl),
            ("wellKnownDigest", \.wellKnownDigest),
        ]
    }
    // swiftlint:enable trailing_comma
}
