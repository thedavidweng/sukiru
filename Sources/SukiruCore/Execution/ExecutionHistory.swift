import Foundation

/// Deletes a batch from history: its execution record (with any rollback
/// record) and the snapshot it was wrapped in. A deleted batch can no longer
/// be rolled back; the skills on disk are untouched.
public struct ExecutionHistory: Sendable {
    private let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) {
        self.environment = environment
    }

    /// Removes the batch's snapshot and record. An unreadable record still
    /// deletes, so a corrupt entry can always be cleared.
    ///
    /// - Throws: `RollbackError.invalidBatchID` / `.unknownBatch`, or
    ///   `ExecutionError.busy` while an execution or rollback holds the lock.
    public func delete(batchID: String) throws {
        do {
            try SnapshotStore.validateSnapshotID(batchID)
        } catch {
            throw RollbackError.invalidBatchID(batchID)
        }
        let appSupport = HostPathResolver.join(
            environment.home, "Library/Application Support/Sukiru")
        let recordDirectory = HostPathResolver.join(appSupport, "executions/" + batchID)
        guard FileManager.default.fileExists(atPath: recordDirectory) else {
            throw RollbackError.unknownBatch(batchID)
        }
        let lock = ExecutionLock(path: HostPathResolver.join(appSupport, "execution.lock"))
        try lock.acquire()
        defer { lock.release() }

        let recordPath = HostPathResolver.join(recordDirectory, "record.json")
        let record = FileManager.default.contents(atPath: recordPath).flatMap {
            try? JSONDecoder().decode(ExecutionRecord.self, from: $0)
        }
        if let snapshotID = record?.snapshotID {
            try deleteSnapshot(id: snapshotID)
        }
        try FileManager.default.removeItem(atPath: recordDirectory)
    }

    /// Retention pruning may already have removed the snapshot.
    private func deleteSnapshot(id: String) throws {
        try SnapshotStore.validateSnapshotID(id)
        let store = SnapshotStore(environment: environment)
        let snapshot = HostPathResolver.join(store.snapshotsRoot(), id)
        if FileManager.default.fileExists(atPath: snapshot) {
            try FileManager.default.removeItem(atPath: snapshot)
        }
    }
}
