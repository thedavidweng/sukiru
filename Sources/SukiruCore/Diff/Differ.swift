import Foundation

/// The workspace coordinates a batch touched — what the post-run rescan and
/// the rollback-time rescan cover (architecture §4.1 Differ: "rescan of
/// affected roots"). Derived from the batch's finding refs and persisted on
/// the execution record so a later rollback process rescans exactly the
/// same surface.
public struct AffectedScope: Equatable, Sendable {
    /// Touched ownership buckets (`user` / `project:<root>`), sorted.
    public let workspaceIDs: [String]
    /// Touched project roots, sorted (empty for a user-scope-only batch).
    public let roots: [String]
    /// The narrowest scope covering every touched bucket.
    public let scope: Scope

    public init(workspaceIDs: [String]) {
        let ids = Set(workspaceIDs)
        self.workspaceIDs = ids.sorted()
        roots = SnapshotPlan.touchedProjectRoots(ids)
        let hasUser = ids.contains("user")
        if roots.isEmpty {
            scope = hasUser ? .user : .all
        } else {
            scope = hasUser ? .all : .project
        }
    }

    /// The rescan request covering exactly the affected roots.
    public var scanRequest: ScanRequest {
        ScanRequest(explicitRoots: roots, scope: scope)
    }
}

/// The post-run Differ (architecture §4.1 + D9): diffs a post-run rescan of
/// the affected roots against the pre-run scan and the snapshot, producing
/// the human-readable change list attached to the batch record.
///
/// Correspondence rule (VAL-REPAIR-032): added/removed placements are single
/// entries (an independent recursive diff reports an added/vanished tree at
/// its root); placements changed in place decompose into file-level entries
/// via the snapshot's payload copies; ledger files report byte changes plus
/// semantic lock-entry deltas. A symlink placement's on-disk identity is its
/// target string, so a symlink whose TARGET DIR's content changed is
/// reported on the canonical placement, never double-reported on the alias.
public struct Differ: Sendable {
    /// Internal (not private) so the ledgers extension file can read it.
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) {
        self.environment = environment
    }

    /// Computes the batch's diff. `pre` is the scan the batch was built
    /// from; `post` is a fresh rescan of the affected scope; `manifest` is
    /// the pre-execution snapshot (payload trees + ledger bytes).
    public func diff(
        touchedWorkspaceIDs: Set<String>,
        pre: ScanReport,
        post: ScanReport,
        manifest: SnapshotManifest
    ) -> BatchDiff {
        var entries = placementEntries(touched: touchedWorkspaceIDs, pre: pre, post: post)
        entries += payloadFileEntries(manifest: manifest)
        entries += ledgerEntries(manifest: manifest)
        let sorted = entries.sorted { ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue) }
        return BatchDiff(entries: sorted, summary: Self.summary(for: sorted))
    }

    // MARK: - placements

    /// Placements of the touched ownership buckets, keyed by path.
    static func placements(
        in report: ScanReport, touched: Set<String>
    ) -> [String: Placement] {
        var byPath: [String: Placement] = [:]
        for skill in report.skills
        where touched.contains(where: { SnapshotPlan.skill(skill, isIn: $0) }) {
            for placement in skill.placements {
                byPath[placement.path] = placement
            }
        }
        return byPath
    }

    /// The paths variant, for rollback's batch-added computation.
    static func placementPaths(in report: ScanReport, touched: Set<String>) -> Set<String> {
        Set(placements(in: report, touched: touched).keys)
    }

    private func placementEntries(
        touched: Set<String>, pre: ScanReport, post: ScanReport
    ) -> [DiffEntry] {
        let before = Self.placements(in: pre, touched: touched)
        let after = Self.placements(in: post, touched: touched)
        var entries: [DiffEntry] = []
        for (path, placement) in after where before[path] == nil {
            entries.append(
                DiffEntry(
                    kind: .placementAdded, path: path,
                    detail: Self.describe(placement)))
        }
        for (path, placement) in before where after[path] == nil {
            entries.append(
                DiffEntry(
                    kind: .placementRemoved, path: path,
                    detail: "was " + Self.describe(placement)))
        }
        for (path, old) in before {
            guard let new = after[path], let detail = Self.changeDetail(old, new) else {
                continue
            }
            entries.append(DiffEntry(kind: .placementChanged, path: path, detail: detail))
        }
        return entries
    }

    private static func describe(_ placement: Placement) -> String {
        switch placement.kind {
        case .directory:
            return "directory"
        case .symlink:
            return "symlink → \(placement.linkTarget ?? "?")"
        case .brokenSymlink:
            return "broken symlink → \(placement.linkTarget ?? "?")"
        }
    }

    /// The change detail between two scans of one placement path, or nil
    /// when nothing on disk changed. Content hashes are compared for
    /// DIRECTORY placements only: a symlink placement's disk identity is
    /// its target string (its content hash follows the canonical dir and
    /// is reported there).
    private static func changeDetail(_ old: Placement, _ new: Placement) -> String? {
        var parts: [String] = []
        if old.kind != new.kind {
            var part = "kind \(old.kind.rawValue) → \(new.kind.rawValue)"
            if new.kind == .brokenSymlink {
                part += " (the link now dangles)"
            }
            parts.append(part)
        }
        if old.linkTarget != new.linkTarget {
            parts.append("link target \(old.linkTarget ?? "none") → \(new.linkTarget ?? "none")")
        }
        let bothDirectories = old.kind == .directory && new.kind == .directory
        if bothDirectories, old.contentHash != new.contentHash {
            let before = old.contentHash ?? "none"
            let after = new.contentHash ?? "none"
            parts.append("content hash \(before) → \(after)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: - payload file trees

    /// One parsed line of a PayloadTree manifest.
    struct TreeEntry: Equatable {
        let kind: String
        let detail: String?
    }

    /// File-level entries for every snapshotted payload: the stored tree
    /// diffed against the live tree. Payloads whose live directory vanished
    /// are covered by their placement-removed entry (the payload path is
    /// itself a recorded placement); a vanished payload that was NOT a
    /// placement (a canonical target behind an alias) still gets an honest
    /// single entry.
    private func payloadFileEntries(manifest: SnapshotManifest) -> [DiffEntry] {
        let snapshotDir = HostPathResolver.join(
            SnapshotStore(environment: environment).snapshotsRoot(), manifest.id)
        let placementPaths = Set(manifest.placements.map(\.path))
        let probe = DefaultFileSystemProbe()
        var entries: [DiffEntry] = []
        for payload in manifest.payloads {
            let stored = HostPathResolver.join(snapshotDir, payload.storedDir)
            guard let preTree = try? Self.treeEntries(root: stored) else {
                continue
            }
            guard probe.entryKind(atPath: payload.path) != nil else {
                if !placementPaths.contains(payload.path) {
                    entries.append(
                        DiffEntry(
                            kind: .fileRemoved, path: payload.path,
                            detail: "payload directory removed entirely"))
                }
                continue
            }
            guard probe.isDirectory(atPath: payload.path),
                let postTree = try? Self.treeEntries(root: payload.path)
            else {
                entries.append(
                    DiffEntry(
                        kind: .fileChanged, path: payload.path,
                        detail: "payload is unreadable or no longer a directory"))
                continue
            }
            entries += Self.treeDiff(pre: preTree, post: postTree, base: payload.path)
        }
        return entries
    }

    /// Parses a PayloadTree manifest into relative-path-keyed entries,
    /// skipping the "." root line.
    static func treeEntries(root: String) throws -> [String: TreeEntry] {
        var map: [String: TreeEntry] = [:]
        for line in try PayloadTree.manifestLines(root: root) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 2, parts[0] != "." else {
                continue
            }
            let detail = parts.count > 2 ? parts.dropFirst(2).joined(separator: "\t") : nil
            map[parts[0]] = TreeEntry(kind: parts[1], detail: detail)
        }
        return map
    }

    /// The file-level diff of two payload trees, emitted at absolute paths
    /// under `base`.
    static func treeDiff(
        pre: [String: TreeEntry], post: [String: TreeEntry], base: String
    ) -> [DiffEntry] {
        var entries: [DiffEntry] = []
        for (relative, old) in pre {
            let path = HostPathResolver.join(base, relative)
            guard let new = post[relative] else {
                entries.append(
                    DiffEntry(kind: .fileRemoved, path: path, detail: "removed \(old.kind)"))
                continue
            }
            if new != old {
                entries.append(
                    DiffEntry(
                        kind: .fileChanged, path: path,
                        detail: changeDetail(old, new)))
            }
        }
        for (relative, new) in post where pre[relative] == nil {
            entries.append(
                DiffEntry(
                    kind: .fileAdded, path: HostPathResolver.join(base, relative),
                    detail: "added \(new.kind)"))
        }
        return entries
    }

    private static func changeDetail(_ old: TreeEntry, _ new: TreeEntry) -> String {
        if old.kind != new.kind {
            return "kind \(old.kind) → \(new.kind)"
        }
        if old.kind == "symlink" {
            return "symlink target \(old.detail ?? "?") → \(new.detail ?? "?")"
        }
        return "content changed"
    }

    // MARK: - summary

    /// The human-readable rendering. An empty diff is explicit
    /// (VAL-REPAIR-033): one line stating nothing changed, so UIs never
    /// have to guess whether the diff ran.
    static func summary(for entries: [DiffEntry]) -> [String] {
        if entries.isEmpty {
            return [
                "No changes: every placement, ledger file, and content hash "
                    + "is exactly as it was before the batch."
            ]
        }
        return entries.map(humanLine)
    }

    private static func humanLine(_ entry: DiffEntry) -> String {
        switch entry.kind {
        case .placementAdded:
            return "Added placement \(entry.path) (\(entry.detail))"
        case .placementRemoved:
            return "Removed placement \(entry.path) (\(entry.detail))"
        case .placementChanged:
            return "Changed placement \(entry.path): \(entry.detail)"
        case .fileAdded:
            return "Added \(entry.path) (\(entry.detail))"
        case .fileRemoved:
            return "Removed \(entry.path) (\(entry.detail))"
        case .fileChanged:
            return "Changed \(entry.path): \(entry.detail)"
        case .lockEntryAdded, .lockEntryRemoved, .lockEntryChanged:
            return "\(entry.detail) [\(entry.path)]"
        }
    }
}
