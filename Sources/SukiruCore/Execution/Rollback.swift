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
    case conflicts(RollbackPreview)

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
        case .conflicts:
            return
                "files changed after execution; choose --restore <path> where canRestore is true, "
                + "or --preserve <path> for each conflict"
        case .alreadyRolledBack(let id):
            return "batch '\(id)' has already been rolled back; rollback is a "
                + "one-time transition"
        }
    }
}

/// The persisted outcome of a one-click rollback
/// (`executions/<batchID>/rollback.json`). Every restored/deleted/failed
/// item is itemized as restored, deleted, preserved, or unrestorable-with-reason.
/// There is no "compensated-via-CLI" category in
/// v1.
public struct RollbackRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let batchID: String
    public let snapshotID: String
    /// ISO-8601 fractional-second rollback timestamp.
    public let rolledBackAt: String
    /// Always `rolledBack`.
    public let batchStatus: BatchStatus
    /// Itemized outcome, sorted by path (SnapshotStore.restore).
    public let items: [RestoreItem]
    /// Recovery preserved unknown paths because no complete post-state exists.
    public let fileEvidenceFailure: String?

    public init(
        schemaVersion: Int = RollbackRecord.currentSchemaVersion,
        batchID: String,
        snapshotID: String,
        rolledBackAt: String,
        batchStatus: BatchStatus = .rolledBack,
        items: [RestoreItem], fileEvidenceFailure: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.snapshotID = snapshotID
        self.rolledBackAt = rolledBackAt
        self.batchStatus = batchStatus
        self.items = items
        self.fileEvidenceFailure = fileEvidenceFailure
    }

    /// Deterministic JSON encoding (sorted keys).
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}

/// Snapshot rollback compares current files against execution's recorded
/// post-state before changing anything. Conflicts require explicit choices;
/// unrelated later additions remain intact. Official CLIs are never used
/// as compensating commands.
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
    public func rollback(
        batchID: String, choices: [String: RollbackChoice] = [:]
    ) throws -> RollbackRecord {
        try perform(batchID: batchID, choices: choices, previewOnly: false).record!
    }

    public func preview(batchID: String) throws -> RollbackPreview {
        try perform(batchID: batchID, choices: [:], previewOnly: true).preview
    }

    private func perform(
        batchID: String, choices: [String: RollbackChoice], previewOnly: Bool
    ) throws -> (preview: RollbackPreview, record: RollbackRecord?) {
        let appSupport = HostPathResolver.join(
            environment.home, "Library/Application Support/Sukiru")
        let recordDirectory = HostPathResolver.join(appSupport, "executions/" + batchID)
        let recordPath = HostPathResolver.join(recordDirectory, "record.json")
        let record = try loadRecord(batchID: batchID, path: recordPath)
        let rollbackPath = HostPathResolver.join(recordDirectory, "rollback.json")
        let hasRollbackRecord = FileManager.default.fileExists(atPath: rollbackPath)
        if record.batchStatus == .rolledBack || hasRollbackRecord {
            throw RollbackError.alreadyRolledBack(batchID)
        }

        // Serialize with executions: a batch mid-flight is never rolled
        // back.
        let lock = ExecutionLock(path: HostPathResolver.join(appSupport, "execution.lock"))
        try lock.acquire()
        defer { lock.release() }

        let store = SnapshotStore(environment: environment)
        let manifest = try store.load(id: record.snapshotID)
        let snapshotDirectory = HostPathResolver.join(store.snapshotsRoot(), record.snapshotID)
        let before = try RollbackFiles.load(from: snapshotDirectory, name: "before.json")
        let incomplete = record.fileEvidenceFailure != nil
        let after =
            incomplete
            ? before : try RollbackFiles.load(from: snapshotDirectory, name: "after.json")
        let current = incomplete ? before : try RollbackFiles.capture(roots: after.roots)
        let conflicts =
            try incomplete
            ? before.recoveryConflicts(manifest: manifest, snapshotDirectory: snapshotDirectory)
            : after.conflicts(with: current).map { conflict in
                RollbackConflict(
                    path: conflict.path, kind: conflict.kind,
                    canRestore: before.entries[conflict.path] != nil
                        || after.entries[conflict.path] != nil)
            }
        let preview = RollbackPreview(
            batchID: batchID, conflicts: conflicts, fileEvidenceFailure: record.fileEvidenceFailure)
        if previewOnly { return (preview, nil) }
        try validateChoices(choices, preview: preview)
        let items = try before.restore(
            manifest: manifest, snapshotDirectory: snapshotDirectory,
            after: after, current: current, choices: choices, evidenceIncomplete: incomplete)
        let result = RollbackRecord(
            batchID: record.batchID,
            snapshotID: record.snapshotID,
            rolledBackAt: CLIExecutor.timestamp(dateProvider()),
            items: items, fileEvidenceFailure: record.fileEvidenceFailure)
        try result.jsonData().write(
            to: URL(fileURLWithPath: rollbackPath), options: .atomic)
        try markRolledBack(record, recordPath: recordPath)
        return (preview, result)
    }

    private func validateChoices(
        _ choices: [String: RollbackChoice], preview: RollbackPreview
    ) throws {
        if preview.conflicts.contains(where: {
            choices[$0.path] == nil || (!$0.canRestore && choices[$0.path] == .restore)
        }) {
            throw RollbackError.conflicts(preview)
        }
    }

    private func loadRecord(batchID: String, path: String) throws -> ExecutionRecord {
        do {
            try SnapshotStore.validateSnapshotID(batchID)
        } catch {
            throw RollbackError.invalidBatchID(batchID)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw RollbackError.unknownBatch(batchID)
        }
        guard let record = try? JSONDecoder().decode(ExecutionRecord.self, from: data) else {
            throw RollbackError.recordUnreadable(batchID)
        }
        return record
    }

    /// Flips the persisted batch transcript to its terminal `rolledBack`
    /// state (succeeded/failed → rolledBack).
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
            affectedWorkspaceIDs: record.affectedWorkspaceIDs,
            fileEvidenceFailure: record.fileEvidenceFailure, scanFailure: record.scanFailure,
            unrestorableEffects: record.unrestorableEffects)
        try updated.jsonData().write(
            to: URL(fileURLWithPath: recordPath), options: .atomic)
    }
}
