import Foundation

/// Rollback refusals — raised BEFORE anything is restored.
public enum RollbackError: Error, Equatable, Sendable {
    /// The batch id is not a single safe path component.
    case invalidBatchID(String)
    /// No execution record exists for this batch id.
    case unknownBatch(String)
    /// The execution record exists but does not decode.
    case recordUnreadable(String)
    /// The batch was already rolled back; rollback is a one-time transition.
    case alreadyRolledBack(String)

    /// Human-readable refusal.
    public var message: String {
        switch self {
        case .invalidBatchID(let id):
            return "invalid batch id '\(id)'"
        case .unknownBatch(let id):
            return "no execution record for batch '\(id)'; rollback needs a "
                + "completed batch execution (succeeded or failed)"
        case .recordUnreadable(let id):
            return "the execution record for batch '\(id)' is unreadable; "
                + "refusing to guess at its snapshot"
        case .alreadyRolledBack(let id):
            return "batch '\(id)' has already been rolled back; rollback is a "
                + "one-time transition"
        }
    }
}

/// The persisted outcome of a one-click rollback
/// (`executions/<batchID>/rollback.json`). Every restored/deleted/failed
/// item is itemized in exactly the three-category vocabulary of
/// VAL-REPAIR-036 — there is no "compensated-via-CLI" category in v1 (D9).
public struct RollbackRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let batchID: String
    public let snapshotID: String
    /// ISO-8601 fractional-second rollback timestamp.
    public let rolledBackAt: String
    /// Always `rolledBack` (architecture §7).
    public let batchStatus: BatchStatus
    /// Itemized outcome, sorted by path (SnapshotStore.restore).
    public let items: [RestoreItem]

    public init(
        schemaVersion: Int = RollbackRecord.currentSchemaVersion,
        batchID: String,
        snapshotID: String,
        rolledBackAt: String,
        batchStatus: BatchStatus = .rolledBack,
        items: [RestoreItem]
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.snapshotID = snapshotID
        self.rolledBackAt = rolledBackAt
        self.batchStatus = batchStatus
        self.items = items
    }

    /// Deterministic JSON encoding (sorted keys).
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}

/// One-click rollback (architecture §4.1 + D9): restore the ledgers
/// byte-exact, restore the payload trees, and delete whatever the batch
/// added. Compensating CLI commands are NOT used in v1.
///
/// Rollback works for `succeeded` AND `failed` batches (VAL-REPAIR-035). It
/// reruns the affected-scope rescan first so placements the batch sprayed
/// into previously-empty host directories — invisible to the snapshot's
/// watched-directory sweep — are found and deleted too (the Differ's
/// post-run rescan vs the manifest's placement set).
public struct Rollback: Sendable {
    private let environment: SukiruEnvironment
    private let dateProvider: @Sendable () -> Date

    public init(
        environment: SukiruEnvironment,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.dateProvider = dateProvider
    }

    /// Rolls a batch back to its pre-execution state.
    ///
    /// - Throws: `RollbackError` for refusals (unknown/already-rolled-back/
    ///   unsafe id), `ExecutionError.busy` while another execution holds the
    ///   lock, or `SnapshotError` when the snapshot itself is unreadable.
    @discardableResult
    public func rollback(batchID: String) throws -> RollbackRecord {
        do {
            try SnapshotStore.validateSnapshotID(batchID)
        } catch {
            throw RollbackError.invalidBatchID(batchID)
        }
        let appSupport = HostPathResolver.join(
            environment.home, "Library/Application Support/Sukiru")
        let recordDirectory = HostPathResolver.join(appSupport, "executions/" + batchID)
        let recordPath = HostPathResolver.join(recordDirectory, "record.json")
        guard let data = FileManager.default.contents(atPath: recordPath) else {
            throw RollbackError.unknownBatch(batchID)
        }
        guard let record = try? JSONDecoder().decode(ExecutionRecord.self, from: data) else {
            throw RollbackError.recordUnreadable(batchID)
        }
        let rollbackPath = HostPathResolver.join(recordDirectory, "rollback.json")
        let hasRollbackRecord = FileManager.default.fileExists(atPath: rollbackPath)
        if record.batchStatus == .rolledBack || hasRollbackRecord {
            throw RollbackError.alreadyRolledBack(batchID)
        }

        // Serialize with executions: a batch mid-flight is never rolled
        // back (VAL-REPAIR-055).
        let lock = ExecutionLock(path: HostPathResolver.join(appSupport, "execution.lock"))
        try lock.acquire()
        defer { lock.release() }

        let store = SnapshotStore(environment: environment)
        let manifest = try store.load(id: record.snapshotID)
        let extraAdded = try batchAddedPaths(record: record, manifest: manifest)
        let restore = try store.restore(
            id: record.snapshotID, extraAddedPaths: extraAdded)
        let result = RollbackRecord(
            batchID: record.batchID,
            snapshotID: record.snapshotID,
            rolledBackAt: CLIExecutor.timestamp(dateProvider()),
            items: restore.items)
        try result.jsonData().write(
            to: URL(fileURLWithPath: rollbackPath), options: .atomic)
        try markRolledBack(record, recordPath: recordPath)
        return result
    }

    /// Placements the post-state has that the pre-batch manifest does not —
    /// the sprayed-symlink gap: a batch can create placements in host skills
    /// dirs that had ZERO placements pre-batch, which the snapshot's
    /// watched-directory sweep cannot see. Computed from a fresh rescan of
    /// the batch's affected scope, never trusted from a stored diff.
    private func batchAddedPaths(
        record: ExecutionRecord, manifest: SnapshotManifest
    ) throws -> [String] {
        let affected = AffectedScope(workspaceIDs: record.affectedWorkspaceIDs)
        let post = try ScanEngine(environment: environment).scan(affected.scanRequest)
        let current = Differ.placementPaths(
            in: post, touched: Set(record.affectedWorkspaceIDs))
        let known = Set(manifest.placements.map(\.path))
        return current.subtracting(known).sorted()
    }

    /// Flips the persisted batch transcript to its terminal `rolledBack`
    /// state (succeeded/failed → rolledBack, architecture §7).
    private func markRolledBack(_ record: ExecutionRecord, recordPath: String) throws {
        let updated = ExecutionRecord(
            schemaVersion: record.schemaVersion,
            batchID: record.batchID,
            snapshotID: record.snapshotID,
            batchStatus: .rolledBack,
            commandTimeoutSeconds: record.commandTimeoutSeconds,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            recordDirectory: record.recordDirectory,
            commands: record.commands,
            diff: record.diff,
            affectedRoots: record.affectedRoots,
            affectedScope: record.affectedScope,
            affectedWorkspaceIDs: record.affectedWorkspaceIDs)
        try updated.jsonData().write(
            to: URL(fileURLWithPath: recordPath), options: .atomic)
    }
}
