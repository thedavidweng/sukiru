import Foundation

/// Snapshot restore: the rollback
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
    /// it is reported as `unrestorable-with-reason`.
    @discardableResult
    public func restore(id: String, extraAddedPaths: [String] = []) throws -> RestoreRecord {
        let manifest = try load(id: id)
        let snapshotDir = HostPathResolver.join(snapshotsRoot(), id)
        var items: [RestoreItem] = []
        items += deleteBatchAdded(manifest: manifest, extraAddedPaths: extraAddedPaths)
        items += restoreMissingDirectories(manifest: manifest)
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
            let item = removeItem(atPath: path)
            items.append(item)
            if item.category == .deletedBatchAdded {
                items += pruneEmptyAncestors(of: path, manifest: manifest)
            }
        }
        // A ledger path recorded as absent but now present is batch-added.
        for ledger in manifest.ledgers where !ledger.existed {
            if FileManager.default.fileExists(atPath: ledger.path) {
                let item = removeItem(atPath: ledger.path)
                items.append(item)
                if item.category == .deletedBatchAdded {
                    items += pruneEmptyAncestors(of: ledger.path, manifest: manifest)
                }
            }
        }
        return items
    }

    /// Removes the now-empty ancestor directories of a deleted batch-added
    /// path — the containers the batch itself must have created (e.g. a
    /// symlink spray's fresh `.qoder/skills` layout) — stopping at anything
    /// that existed pre-batch: the home, the snapshot store, watched
    /// directories, every ancestor of a recorded placement or ledger, and
    /// every container dir the capture recorded as pre-existing (including
    /// EMPTY host skills dirs with zero placements, which none of the
    /// other stop sets can distinguish from batch-created containers).
    private func pruneEmptyAncestors(
        of path: String, manifest: SnapshotManifest
    ) -> [RestoreItem] {
        var stop = Set(manifest.watchedDirectories)
        stop.formUnion(manifest.preExistingDirectories)
        stop.insert(environment.home)
        stop.insert("/")
        stop.insert(snapshotsRoot())
        // Anchors that provably existed pre-batch: every ancestor of a
        // recorded placement or of an EXISTING ledger, plus the project
        // root implied by an absent-ledger probe path (the root existed
        // even though the lock candidate inside it did not).
        let ledgers = manifest.ledgers.filter(\.existed).map(\.path)
        let anchors = manifest.placements.map(\.path) + ledgers
        for anchor in anchors {
            var ancestor = anchor
            while true {
                let parent = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                if parent == ancestor || stop.contains(parent) {
                    break
                }
                stop.insert(parent)
                ancestor = parent
            }
        }
        for ledger in manifest.ledgers where !ledger.existed {
            for candidate in VercelLockReader.projectProbeOrder
            where ledger.path.hasSuffix("/" + candidate) {
                stop.insert(String(ledger.path.dropLast(candidate.count + 1)))
                break
            }
        }
        var items: [RestoreItem] = []
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while !stop.contains(directory), Self.isEmptyDirectory(directory) {
            items.append(removeItem(atPath: directory))
            let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
            if parent == directory {
                break
            }
            directory = parent
        }
        return items
    }

    private static func isEmptyDirectory(_ path: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return contents.isEmpty
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

    /// Recreates container folders that existed before the batch and are
    /// gone now (a removed leftover host folder). Placements restore into
    /// them afterwards; an empty one has no placement to recreate it.
    private func restoreMissingDirectories(manifest: SnapshotManifest) -> [RestoreItem] {
        let probe = DefaultFileSystemProbe()
        return manifest.preExistingDirectories.filter { probe.entryKind(atPath: $0) == nil }
            .map { path in
                do {
                    try FileManager.default.createDirectory(
                        atPath: path, withIntermediateDirectories: true)
                    return RestoreItem(path: path, category: .restoredFromSnapshot, reason: nil)
                } catch {
                    return Self.unrestorable(path, error: error)
                }
            }
    }

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
    /// instead of silently claiming a clean rollback.
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
