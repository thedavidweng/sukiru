import CryptoKit
import Foundation

/// Snapshot storage for the Command Batch safety model (architecture §4.1,
/// D9): pre-execution capture of both ledger files byte-exact, a placement
/// manifest, and full recursive payload copies of every skill dir the batch
/// may touch (any ownership); path-traversal-safe load; retention pruning.
///
/// Snapshots live under
/// `<home>/Library/Application Support/Sukiru/snapshots/<id>/` — with
/// `SUKIRU_HOME` supplying `<home>` in sandboxes — never directly under
/// `$TMPDIR`. Capture stages into a sibling `.staging-*` directory and
/// renames it into place, so no listing ever observes a partial snapshot
/// (VAL-REPAIR-026); `manifest.json` itself is written atomically.
///
/// Restore lives in SnapshotRestore.swift (extension, same module).
public struct SnapshotStore: Sendable {
    /// Retention: at most this many snapshots survive pruning (D9 default).
    public static let defaultRetentionLimit = 10

    let environment: SukiruEnvironment
    let retentionLimit: Int
    let idProvider: @Sendable () -> String
    let dateProvider: @Sendable () -> Date

    public init(
        environment: SukiruEnvironment,
        retentionLimit: Int = SnapshotStore.defaultRetentionLimit,
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.retentionLimit = retentionLimit
        self.idProvider = idProvider
        self.dateProvider = dateProvider
    }

    /// The snapshots root: `<home>/Library/Application Support/Sukiru/snapshots`.
    public func snapshotsRoot() -> String {
        HostPathResolver.join(environment.home, "Library/Application Support/Sukiru/snapshots")
    }

    // MARK: - capture

    /// Captures the pre-execution state for a batch, commits the snapshot
    /// atomically, then applies retention pruning.
    ///
    /// Throws — committing nothing visible — when any ledger or payload
    /// cannot be captured: a batch must never execute without a complete
    /// snapshot (VAL-REPAIR-023's "snapshot before first command" is only
    /// meaningful when capture is all-or-nothing).
    @discardableResult
    public func capture(batch: CommandBatch, report: ScanReport) throws -> SnapshotManifest {
        let id = idProvider()
        try Self.validateSnapshotID(id)
        let finalDir = HostPathResolver.join(snapshotsRoot(), id)
        guard !FileManager.default.fileExists(atPath: finalDir) else {
            throw SnapshotError.captureFailed("snapshot '\(id)' already exists")
        }
        let staging = HostPathResolver.join(snapshotsRoot(), ".staging-\(UUID().uuidString)")
        let plan = SnapshotPlan(batch: batch, report: report, environment: environment)
        do {
            try FileManager.default.createDirectory(
                atPath: staging, withIntermediateDirectories: true)
            let ledgers = try captureLedgers(plan: plan, staging: staging)
            let payloads = try capturePayloads(plan: plan, staging: staging)
            let manifest = SnapshotManifest(
                schemaVersion: SnapshotManifest.currentSchemaVersion,
                id: id,
                batchID: batch.id,
                createdAt: ISO8601DateFormatter().string(from: dateProvider()),
                ledgers: ledgers,
                placements: plan.placements,
                payloads: payloads,
                watchedDirectories: plan.watchedDirectories,
                preExistingDirectories: plan.preExistingDirectories)
            try writeManifest(manifest, to: staging)
            try FileManager.default.moveItem(atPath: staging, toPath: finalDir)
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }
        try prune()
        return try load(id: id)
    }

    private func captureLedgers(plan: SnapshotPlan, staging: String) throws -> [LedgerSnapshot] {
        var records: [LedgerSnapshot] = []
        for (index, path) in plan.ledgerPaths.enumerated() {
            guard let data = FileManager.default.contents(atPath: path) else {
                if FileManager.default.fileExists(atPath: path) {
                    throw SnapshotError.captureFailed("ledger at \(path) is not a readable file")
                }
                records.append(
                    LedgerSnapshot(path: path, existed: false, storedFile: nil, sha256: nil))
                continue
            }
            let stored = "ledgers/\(index)"
            let ledgersDir = HostPathResolver.join(staging, "ledgers")
            try FileManager.default.createDirectory(
                atPath: ledgersDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: HostPathResolver.join(staging, stored)))
            records.append(
                LedgerSnapshot(
                    path: path, existed: true, storedFile: stored, sha256: Self.sha256Hex(data)))
        }
        return records
    }

    private func capturePayloads(plan: SnapshotPlan, staging: String) throws -> [PayloadSnapshot] {
        var records: [PayloadSnapshot] = []
        for (index, source) in plan.payloadSources.enumerated() {
            let stored = "payloads/\(index)"
            let destination = HostPathResolver.join(staging, stored)
            do {
                try PayloadTree.copyDirectory(from: source, to: destination)
            } catch {
                throw SnapshotError.captureFailed("could not copy payload \(source): \(error)")
            }
            let digest = try PayloadTree.digest(root: destination)
            records.append(PayloadSnapshot(path: source, storedDir: stored, digest: digest))
        }
        return records
    }

    private func writeManifest(_ manifest: SnapshotManifest, to directory: String) throws {
        let data = try deterministicJSONData(manifest)
        let destination = URL(fileURLWithPath: HostPathResolver.join(directory, "manifest.json"))
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - load / list / prune

    /// Loads a snapshot manifest, rejecting path-traversal attempts in both
    /// the snapshot id and every stored relative path.
    public func load(id: String) throws -> SnapshotManifest {
        try Self.validateSnapshotID(id)
        let dir = HostPathResolver.join(snapshotsRoot(), id)
        let path = HostPathResolver.join(dir, "manifest.json")
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SnapshotError.snapshotNotFound(id)
        }
        let decoded = try? JSONDecoder().decode(SnapshotManifest.self, from: data)
        guard let manifest = decoded, manifest.id == id else {
            throw SnapshotError.manifestUnreadable(id)
        }
        let stored = manifest.ledgers.compactMap(\.storedFile) + manifest.payloads.map(\.storedDir)
        for entry in stored {
            try Self.validateStoredPath(entry, snapshotID: id)
        }
        return manifest
    }

    /// All committed snapshots, oldest first. Staging dirs and dotfiles are
    /// never snapshots; an entry with an unparseable manifest is skipped
    /// rather than failing the listing.
    public func list() -> [SnapshotSummary] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: snapshotsRoot())) ?? []
        var summaries: [SnapshotSummary] = []
        for name in entries.sorted() where !name.hasPrefix(".") {
            if let manifest = try? load(id: name) {
                summaries.append(
                    SnapshotSummary(
                        id: manifest.id, batchID: manifest.batchID, createdAt: manifest.createdAt))
            }
        }
        return summaries.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Deletes the oldest snapshots beyond the retention limit (default 10).
    public func prune() throws {
        let all = list()
        guard all.count > retentionLimit else {
            return
        }
        for victim in all.prefix(all.count - retentionLimit) {
            try FileManager.default.removeItem(
                atPath: HostPathResolver.join(snapshotsRoot(), victim.id))
        }
    }

    // MARK: - path safety

    /// A snapshot id must be a single safe path component.
    static func validateSnapshotID(_ id: String) throws {
        let unsafe =
            id.isEmpty || id == "." || id == ".." || id.contains("/") || id.contains("\\")
        if unsafe {
            throw SnapshotError.invalidSnapshotID(id)
        }
    }

    /// A stored path must be relative and stay inside the snapshot
    /// directory: no leading slash, no backslashes, no `.`/`..` components.
    static func validateStoredPath(_ stored: String, snapshotID: String) throws {
        let components = stored.split(separator: "/").map(String.init)
        let unsafe =
            stored.isEmpty || stored.hasPrefix("/") || stored.contains("\\")
            || components.contains("..") || components.contains(".")
        if unsafe {
            throw SnapshotError.unsafeManifestEntry("\(snapshotID): \(stored)")
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deepest paths first (children before parents, architecture §4.1
    /// Rollback), ties broken by ascending path for determinism.
    static func descendingDepth(_ paths: [String]) -> [String] {
        paths.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth > rhsDepth
            }
            return lhs < rhs
        }
    }
}
