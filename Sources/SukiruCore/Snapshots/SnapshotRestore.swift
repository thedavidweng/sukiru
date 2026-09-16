import Foundation

/// Snapshot restore (architecture §4.1 SnapshotStore + D9): the rollback
/// mechanics behind one-click rollback. Restores ledger bytes and payload
/// trees, deletes batch-added paths per the manifest diff, and reports every
/// item honestly. Compensating CLI commands are NOT used in v1.
///
/// Ordering is children-before-parents (descending path depth) for both
/// deletions and restores; parent payloads contain their nested children's
/// bytes, so the outcome is byte-identical either way, and recursive
/// deletion of batch-added trees never strands a parent.
extension SnapshotStore {
    /// Restores the pre-batch state from a snapshot. `extraAddedPaths` lets
    /// the Differ pass batch-added placements its post-run rescan found in
    /// host dirs the manifest does not watch; they pass the same safety
    /// filter as swept paths. A failure on one item never aborts the others;
    /// it is reported as `unrestorable-with-reason` (VAL-REPAIR-036).
    @discardableResult
    public func restore(id: String, extraAddedPaths: [String] = []) throws -> RestoreRecord {
        let manifest = try load(id: id)
        let snapshotDir = HostPathResolver.join(snapshotsRoot(), id)
        var items: [RestoreItem] = []
        items += deleteBatchAdded(manifest: manifest, extraAddedPaths: extraAddedPaths)
        items += restoreLedgers(manifest: manifest, snapshotDir: snapshotDir)
        items += restorePayloads(manifest: manifest, snapshotDir: snapshotDir)
        items += restoreSymlinks(manifest: manifest)
        items += reportVanishedPlacements(manifest: manifest)
        return RestoreRecord(
            snapshotID: manifest.id,
            batchID: manifest.batchID,
            items: items.sorted { $0.path < $1.path })
    }

    // MARK: - batch-added deletion

    private func deleteBatchAdded(
        manifest: SnapshotManifest,
        extraAddedPaths: [String]
    ) -> [RestoreItem] {
        var items: [RestoreItem] = []
        for path in batchAddedPaths(manifest: manifest, extra: extraAddedPaths) {
            items.append(removeItem(atPath: path))
        }
        // A ledger path recorded as absent but now present is batch-added.
        for ledger in manifest.ledgers where !ledger.existed {
            if FileManager.default.fileExists(atPath: ledger.path) {
                items.append(removeItem(atPath: ledger.path))
            }
        }
        return items
    }

    /// Immediate children of watched directories that the manifest does not
    /// record, plus the caller's additions, safety-filtered and ordered
    /// children-before-parents.
    private func batchAddedPaths(manifest: SnapshotManifest, extra: [String]) -> [String] {
        let placements = Set(manifest.placements.map(\.path))
        let watched = Set(manifest.watchedDirectories)
        let ledgers = Set(manifest.ledgers.map(\.path))
        var added: [String] = []
        for directory in manifest.watchedDirectories {
            let children =
                (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for child in children {
                let path = HostPathResolver.join(directory, child)
                let known =
                    placements.contains(path) || watched.contains(path)
                    || ledgers.contains(path)
                if !known {
                    added.append(path)
                }
            }
        }
        for path in extra {
            let eligible = isSafeToDelete(path, placements: placements, ledgers: ledgers)
            if eligible && !added.contains(path) {
                added.append(path)
            }
        }
        return Self.descendingDepth(added)
    }

    /// Refuse deletions at the filesystem root, the home itself, or inside
    /// the snapshot store, whatever the caller asked for.
    private func isSafeToDelete(
        _ path: String,
        placements: Set<String>,
        ledgers: Set<String>
    ) -> Bool {
        let root = snapshotsRoot()
        return !path.isEmpty && path != "/" && path != environment.home
            && path != root && !path.hasPrefix(root + "/")
            && !placements.contains(path) && !ledgers.contains(path)
    }

    private func removeItem(atPath path: String) -> RestoreItem {
        do {
            try FileManager.default.removeItem(atPath: path)
            return RestoreItem(path: path, category: .deletedBatchAdded, reason: nil)
        } catch {
            return RestoreItem(
                path: path,
                category: .unrestorableWithReason,
                reason: "could not delete batch-added path: \(error.localizedDescription)")
        }
    }

    // MARK: - ledger + payload + symlink restore

    private func restoreLedgers(
        manifest: SnapshotManifest,
        snapshotDir: String
    ) -> [RestoreItem] {
        var items: [RestoreItem] = []
        for ledger in manifest.ledgers where ledger.existed {
            guard let stored = ledger.storedFile else {
                continue
            }
            do {
                let source = URL(fileURLWithPath: HostPathResolver.join(snapshotDir, stored))
                let bytes = try Data(contentsOf: source)
                try createParentDirectory(of: ledger.path)
                // .atomic writes via temp+rename in the same directory:
                // byte-exact and never a half-written ledger.
                try bytes.write(to: URL(fileURLWithPath: ledger.path), options: .atomic)
                items.append(
                    RestoreItem(path: ledger.path, category: .restoredFromSnapshot, reason: nil))
            } catch {
                items.append(Self.unrestorable(ledger.path, error: error))
            }
        }
        return items
    }

    private func restorePayloads(
        manifest: SnapshotManifest,
        snapshotDir: String
    ) -> [RestoreItem] {
        var items: [RestoreItem] = []
        for path in Self.descendingDepth(manifest.payloads.map(\.path)) {
            guard let payload = manifest.payloads.first(where: { $0.path == path }) else {
                continue
            }
            do {
                try removeIfPresent(atPath: payload.path)
                let source = HostPathResolver.join(snapshotDir, payload.storedDir)
                try PayloadTree.copyDirectory(from: source, to: payload.path)
                items.append(
                    RestoreItem(path: payload.path, category: .restoredFromSnapshot, reason: nil))
            } catch {
                items.append(Self.unrestorable(payload.path, error: error))
            }
        }
        return items
    }

    private func restoreSymlinks(manifest: SnapshotManifest) -> [RestoreItem] {
        let links = manifest.placements.filter { $0.kind != .directory }
        var items: [RestoreItem] = []
        for path in Self.descendingDepth(links.map(\.path)) {
            guard let placement = links.first(where: { $0.path == path }) else {
                continue
            }
            guard let target = placement.linkTarget else {
                items.append(
                    RestoreItem(
                        path: placement.path,
                        category: .unrestorableWithReason,
                        reason: "placement recorded without a link target"))
                continue
            }
            do {
                try removeIfPresent(atPath: placement.path)
                try createParentDirectory(of: placement.path)
                try FileManager.default.createSymbolicLink(
                    atPath: placement.path, withDestinationPath: target)
                items.append(
                    RestoreItem(
                        path: placement.path, category: .restoredFromSnapshot, reason: nil))
            } catch {
                items.append(Self.unrestorable(placement.path, error: error))
            }
        }
        return items
    }

    /// Directory placements without a payload are not the batch's targets;
    /// if one nonetheless vanished during the batch, report it honestly
    /// instead of silently claiming a clean rollback (VAL-REPAIR-036).
    private func reportVanishedPlacements(manifest: SnapshotManifest) -> [RestoreItem] {
        let payloadPaths = Set(manifest.payloads.map(\.path))
        let probe = DefaultFileSystemProbe()
        var items: [RestoreItem] = []
        for placement in manifest.placements where placement.kind == .directory {
            if payloadPaths.contains(placement.path) {
                continue
            }
            if probe.entryKind(atPath: placement.path) == nil {
                items.append(
                    RestoreItem(
                        path: placement.path,
                        category: .unrestorableWithReason,
                        reason: "directory vanished during the batch but was not a "
                            + "snapshot payload target"))
            }
        }
        return items
    }

    // MARK: - shared helpers

    /// Removes whatever is at `path`, if anything. Existence is checked with
    /// lstat semantics so a DANGLING symlink is still removed
    /// (`FileManager.fileExists` follows links and would miss it).
    private func removeIfPresent(atPath path: String) throws {
        if DefaultFileSystemProbe().entryKind(atPath: path) != nil {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func createParentDirectory(of path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }

    private static func unrestorable(_ path: String, error: any Error) -> RestoreItem {
        RestoreItem(
            path: path,
            category: .unrestorableWithReason,
            reason: error.localizedDescription)
    }
}
