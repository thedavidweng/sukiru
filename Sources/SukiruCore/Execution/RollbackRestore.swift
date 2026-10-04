import Foundation

extension RollbackFiles {
    func recoveryConflicts(
        manifest: SnapshotManifest, snapshotDirectory: String
    ) throws -> [RollbackConflict] {
        let sources = try snapshotSources(manifest: manifest, snapshotDirectory: snapshotDirectory)
        return entries.keys.sorted().compactMap { path in
            guard entries[path]?.kind != "directory" else { return nil }
            let available =
                entries[path]?.kind == "link"
                || sources[path].map { FileManager.default.fileExists(atPath: $0) } == true
            return RollbackConflict(path: path, kind: .modified, canRestore: available)
        }
    }

    private struct RestorePlan {
        let sources: [String: String]
        let links: [String: String]
        let added: Set<String>
        let directories: Set<String>
        let preserved: Set<String>
        let evidenceIncomplete: Bool

        var restoredPaths: [String] {
            Set(sources.keys).union(links.keys).union(directories).subtracting(added)
                .sorted { ($0.count, $0) < ($1.count, $1) }
        }
    }

    /// Entries restore independently so preserving a file never rewrites siblings.
    func restore(
        manifest: SnapshotManifest, snapshotDirectory: String,
        after: RollbackFiles, current: RollbackFiles,
        choices: [String: RollbackChoice], evidenceIncomplete: Bool = false
    ) throws -> [RestoreItem] {
        let plan = try restorePlan(
            manifest: manifest, snapshotDirectory: snapshotDirectory,
            after: after, current: current, choices: choices, evidenceIncomplete: evidenceIncomplete
        )
        var items = deleteAdded(plan: plan, current: current)
        items += restoreEntries(plan: plan)
        if !evidenceIncomplete { items += try pruneContainers(roots: after.roots) }
        items = reportPayloadFailures(manifest: manifest, items: items)
        items += plan.preserved.sorted().map {
            RestoreItem(path: $0, category: .preservedCurrent, reason: nil)
        }
        return items.sorted { $0.path < $1.path }
    }

    private func restorePlan(
        manifest: SnapshotManifest, snapshotDirectory: String,
        after: RollbackFiles, current: RollbackFiles,
        choices: [String: RollbackChoice], evidenceIncomplete: Bool = false
    ) throws -> RestorePlan {
        let sources = try snapshotSources(manifest: manifest, snapshotDirectory: snapshotDirectory)
        var links = Dictionary(
            uniqueKeysWithValues: manifest.placements.compactMap { placement in
                placement.linkTarget.map { (placement.path, $0) }
            })
        for (path, entry) in entries where entry.kind == "link" {
            links[path] = entry.detail
        }
        let added = Set(after.entries.keys).subtracting(entries.keys)
        let preserved = Set(choices.filter { $0.value == .preserve }.keys).union(
            Set(current.entries.keys).subtracting(entries.keys).subtracting(after.entries.keys))
        return RestorePlan(
            sources: sources, links: links, added: added,
            directories: Set(
                manifest.preExistingDirectories.filter { entries[$0]?.kind == "directory" }),
            preserved: preserved, evidenceIncomplete: evidenceIncomplete)
    }

    private func snapshotSources(
        manifest: SnapshotManifest, snapshotDirectory: String
    ) throws -> [String: String] {
        var sources = try SnapshotStore.genericSources(snapshotDirectory: snapshotDirectory)
        for payload in manifest.payloads {
            let stored = HostPathResolver.join(snapshotDirectory, payload.storedDir)
            for path in entries.keys
            where path == payload.path || path.hasPrefix(payload.path + "/") {
                sources[path] = stored + path.dropFirst(payload.path.count)
            }
        }
        for ledger in manifest.ledgers {
            if let stored = ledger.storedFile {
                sources[ledger.path] = HostPathResolver.join(snapshotDirectory, stored)
            }
        }
        return sources
    }

    private func deleteAdded(plan: RestorePlan, current: RollbackFiles) -> [RestoreItem] {
        var items: [RestoreItem] = []
        for path in SnapshotStore.descendingDepth(Array(plan.added)) {
            if protected(path, by: plan.preserved) || current.entries[path] == nil { continue }
            do {
                let manager = FileManager.default
                if current.entries[path]?.kind == "directory" {
                    if !(try manager.contentsOfDirectory(atPath: path)).isEmpty { continue }
                }
                try checkParents(path)
                try manager.removeItem(atPath: path)
                items.append(RestoreItem(path: path, category: .deletedBatchAdded, reason: nil))
            } catch { items.append(failure(path, error)) }
        }
        return items
    }

    private func restoreEntries(plan: RestorePlan) -> [RestoreItem] {
        var items: [RestoreItem] = []
        for path in plan.restoredPaths {
            if protected(path, by: plan.preserved) { continue }
            let existingDirectory = DefaultFileSystemProbe().entryKind(atPath: path) == .directory
            let directoryOnly = plan.sources[path] == nil && plan.links[path] == nil
            if plan.directories.contains(path), directoryOnly, existingDirectory {
                continue
            }
            do {
                try checkParents(path)
                try restoreEntry(path, plan: plan)
                items.append(RestoreItem(path: path, category: .restoredFromSnapshot, reason: nil))
            } catch { items.append(failure(path, error)) }
        }
        return items
    }

    private func restoreEntry(_ path: String, plan: RestorePlan) throws {
        let manager = FileManager.default
        let kind = DefaultFileSystemProbe().entryKind(atPath: path)
        if let target = plan.links[path], case .symlink(let current) = kind, current == target {
            return
        }
        if entries[path]?.kind == "directory" || plan.directories.contains(path) {
            if plan.evidenceIncomplete, kind != nil, kind != .directory {
                throw SnapshotError.captureFailed(
                    "recovery cannot replace an uncaptured entry at \(path)")
            }
            if DefaultFileSystemProbe().entryKind(atPath: path) != .directory {
                try replace(path, preserved: plan.preserved)
                try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            return
        }
        if plan.evidenceIncomplete, kind == .directory {
            if !(try manager.contentsOfDirectory(atPath: path)).isEmpty {
                throw SnapshotError.captureFailed(
                    "recovery cannot remove uncaptured children at \(path)")
            }
        }
        if let source = plan.sources[path], entries[path]?.kind == "file" {
            _ = try Data(contentsOf: URL(fileURLWithPath: source))
        }
        try replace(path, preserved: plan.preserved)
        try manager.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        if let target = plan.links[path] {
            try manager.createSymbolicLink(atPath: path, withDestinationPath: target)
        } else if let source = plan.sources[path] {
            try manager.copyItem(atPath: source, toPath: path)
        }
    }

    private func pruneContainers(roots: [String]) throws -> [RestoreItem] {
        var items: [RestoreItem] = []
        for root in roots {
            var parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
            while parent != "/" && !containers.contains(parent) {
                guard DefaultFileSystemProbe().entryKind(atPath: parent) == .directory,
                    try FileManager.default.contentsOfDirectory(atPath: parent).isEmpty
                else { break }
                try FileManager.default.removeItem(atPath: parent)
                items.append(RestoreItem(path: parent, category: .deletedBatchAdded, reason: nil))
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
        }
        return items
    }

    private func reportPayloadFailures(
        manifest: SnapshotManifest, items: [RestoreItem]
    ) -> [RestoreItem] {
        var items = items
        for payload in manifest.payloads {
            if let failure = items.first(where: {
                $0.path.hasPrefix(payload.path + "/") && $0.category == .unrestorableWithReason
            }) {
                items.removeAll { $0.path == payload.path }
                items.append(
                    RestoreItem(
                        path: payload.path, category: .unrestorableWithReason,
                        reason: failure.reason))
            }
        }
        return items
    }

    private func protected(_ path: String, by preserved: Set<String>) -> Bool {
        preserved.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func checkParents(_ path: String) throws {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" {
            let insideBounds = roots.contains { parent == $0 || parent.hasPrefix($0 + "/") }
            let kind = DefaultFileSystemProbe().entryKind(atPath: parent)
            let isLink = if case .symlink = kind { true } else { false }
            if entries[parent]?.kind == "link", !isLink {
                throw SnapshotError.captureFailed(
                    "restore would traverse changed link at \(parent)")
            }
            if insideBounds || entries[parent]?.kind == "link", isLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: parent)
                guard entries[parent] == Entry(kind: "link", detail: target) else {
                    throw SnapshotError.captureFailed(
                        "restore would traverse changed link at \(parent)")
                }
            }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
    }

    private func replace(_ path: String, preserved: Set<String>) throws {
        guard DefaultFileSystemProbe().entryKind(atPath: path) != nil else { return }
        if preserved.contains(where: { $0.hasPrefix(path + "/") }) {
            throw SnapshotError.captureFailed("replacement would remove preserved files at \(path)")
        }
        try FileManager.default.removeItem(atPath: path)
    }

    private func failure(_ path: String, _ error: any Error) -> RestoreItem {
        RestoreItem(
            path: path, category: .unrestorableWithReason, reason: error.localizedDescription)
    }
}
