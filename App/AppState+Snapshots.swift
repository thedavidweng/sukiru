import Foundation
import SukiruCore

/// Snapshots-surface state: the on-disk batch history (execution records +
/// rollback events) that backs the Snapshots view.
///
/// The history is PERSISTED state written by the batch executors
/// (`CLIExecutor` / `Rollback`), read fresh from disk on launch, after every
/// app-initiated mutation, and on the surface's explicit Reload — it
/// must survive relaunches. The app keeps zero ledger or
/// finding state of its own; these records are the execution transcript,
/// not a ledger.
@MainActor
extension AppState {
    /// One row of the Snapshots history: a batch execution or a rollback
    /// event, interleaved by time so batch 1 → rollback → batch 2 reads as
    /// three distinct, correctly ordered entries.
    enum HistoryRow: Equatable, Identifiable {
        case batch(ExecutionRecord)
        case rollback(RollbackRecord)

        var id: String {
            switch self {
            case .batch(let record): return "batch-" + record.batchID
            case .rollback(let record): return "rollback-" + record.batchID
            }
        }

        var batchID: String {
            switch self {
            case .batch(let record): return record.batchID
            case .rollback(let record): return record.batchID
            }
        }

        /// Sort timestamp (ISO-8601 strings order lexicographically).
        var timestamp: String {
            switch self {
            case .batch(let record): return record.startedAt
            case .rollback(let record): return record.rolledBackAt
            }
        }

        /// Ties (same timestamp) order a batch before its own rollback.
        var kindOrder: Int {
            switch self {
            case .batch: return 0
            case .rollback: return 1
            }
        }
    }

    /// Shows a batch's snapshot folder in Finder, or its execution record
    /// when retention pruning already removed the snapshot.
    func revealHistory(batchID: String) {
        let row = historyRows.first { $0.id == "batch-" + batchID }
        guard let row, case .batch(let record) = row else { return }
        let home = Self.makeEnvironment(roots: projectRoots).home
        let snapshot = HostPathResolver.join(
            home, "Library/Application Support/Sukiru/snapshots/" + record.snapshotID)
        let exists = FileManager.default.fileExists(atPath: snapshot)
        revealInFinder([exists ? snapshot : record.recordDirectory])
    }

    /// Deletes batches' snapshots and records. The skills on disk stay as
    /// they are; the batches just can no longer be rolled back.
    func deleteHistory(batchIDs: Set<String>) {
        guard !batchMutationInFlight, !batchIDs.isEmpty else { return }
        batchMutationInFlight = true
        rollbackError = nil
        let environment = Self.makeEnvironment(roots: projectRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            let history = ExecutionHistory(environment: environment)
            for batchID in batchIDs.sorted() {
                do {
                    try history.delete(batchID: batchID)
                } catch {
                    failure = UserFacingError.message(for: error)
                }
            }
            await MainActor.run { [failure] in
                guard let self else { return }
                self.batchMutationInFlight = false
                self.rollbackError = failure
                self.loadHistory()
            }
        }
    }

    /// Reloads the batch history from the on-disk execution records.
    func loadHistory() {
        let environment = Self.makeEnvironment(roots: projectRoots)
        let root = HostPathResolver.join(
            environment.home, "Library/Application Support/Sukiru/executions")
        Task.detached(priority: .utility) { [weak self] in
            let rows = Self.readHistoryRows(executionsRoot: root)
            await MainActor.run {
                guard let self else { return }
                self.historyRows = rows
                let selectionIsStale = self.selectedHistoryID.map { selected in
                    !rows.contains(where: { $0.id == selected })
                }
                if selectionIsStale == true {
                    self.selectedHistoryID = nil
                }
            }
        }
    }

    /// Reads `executions/<batchID>/record.json` (+ `rollback.json` when a
    /// rollback happened) into time-ordered rows. Unreadable entries are
    /// skipped, never fatal (malformed data is data).
    nonisolated static func readHistoryRows(executionsRoot: String) -> [HistoryRow] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: executionsRoot)) ?? []
        let decoder = JSONDecoder()
        var rows: [HistoryRow] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let directory = HostPathResolver.join(executionsRoot, name)
            let recordPath = HostPathResolver.join(directory, "record.json")
            guard let data = fileManager.contents(atPath: recordPath),
                let record = try? decoder.decode(ExecutionRecord.self, from: data)
            else { continue }
            rows.append(.batch(record))
            let rollbackPath = HostPathResolver.join(directory, "rollback.json")
            let rollbackData = fileManager.contents(atPath: rollbackPath)
            let rollback = rollbackData.flatMap {
                try? decoder.decode(RollbackRecord.self, from: $0)
            }
            if let rollback {
                rows.append(.rollback(rollback))
            }
        }
        return rows.sorted {
            ($0.timestamp, $0.kindOrder) < ($1.timestamp, $1.kindOrder)
        }
    }
}
