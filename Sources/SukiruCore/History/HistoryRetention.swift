import Foundation

/// What a prune or clear removed and what is left.
public struct HistoryPruneResult: Codable, Equatable, Sendable {
    /// Batch IDs removed (the snapshot ID for a snapshot with no record).
    public let removedBatches: [String]
    public let reclaimedBytes: Int64
    public let remainingBatches: Int
    public let remainingBytes: Int64
}

/// How much history is on disk.
public struct HistoryUsage: Codable, Equatable, Sendable {
    public let batches: Int
    public let bytes: Int64

    public init(batches: Int, bytes: Int64) {
        self.batches = batches
        self.bytes = bytes
    }
}

/// Applies the retention policy to history. A batch is its execution record
/// plus its snapshot; they are removed together, so a pruned batch can no
/// longer be rolled back. Orphans (a snapshot with no record, or a record
/// with no snapshot) count as batches of their own.
///
/// Mutations take the cross-process `ExecutionLock` and throw
/// `ExecutionError.busy` while another process holds it.
public struct HistoryRetention: Sendable {
    private struct Batch {
        let id: String
        let date: Date
        let recordName: String?
        let snapshotID: String?
        let bytes: Int64
    }

    private let environment: SukiruEnvironment
    private let now: @Sendable () -> Date

    public init(environment: SukiruEnvironment, now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.now = now
    }

    private var appSupport: String {
        HostPathResolver.join(environment.home, "Library/Application Support/Sukiru")
    }

    private var executionsRoot: String { HostPathResolver.join(appSupport, "executions") }

    private var snapshotsRoot: String { SnapshotStore(environment: environment).snapshotsRoot() }

    /// Current batch count and storage used by snapshots and records.
    public func usage() -> HistoryUsage {
        let batches = collect()
        return HistoryUsage(batches: batches.count, bytes: batches.reduce(0) { $0 + $1.bytes })
    }

    /// Applies `policy` (default: the stored one), taking the execution lock.
    @discardableResult
    public func prune(policy: RetentionPolicy? = nil) throws -> HistoryPruneResult {
        let lock = ExecutionLock(path: HostPathResolver.join(appSupport, "execution.lock"))
        try lock.acquire()
        defer { lock.release() }
        return try pruneHoldingLock(policy: policy)
    }

    /// Prune for a caller that already holds the execution lock.
    @discardableResult
    func pruneHoldingLock(policy: RetentionPolicy? = nil) throws -> HistoryPruneResult {
        let policy = policy ?? SukiruSettingsStore(environment: environment).retentionPolicy()
        let newestFirst = collect()
        let cutoff = now().addingTimeInterval(-TimeInterval(policy.maxAgeDays) * 86_400)
        // The newest batch always stays, so the last change can be rolled back.
        var kept = Array(newestFirst.prefix(policy.maxBatches)).enumerated()
            .filter { $0.offset == 0 || $0.element.date >= cutoff }.map(\.element)
        var total = kept.reduce(Int64(0)) { $0 + $1.bytes }
        while total > policy.maxSizeBytes, kept.count > 1, let oldest = kept.popLast() {
            total -= oldest.bytes
        }
        let keptIDs = Set(kept.map(\.id))
        return try remove(newestFirst.filter { !keptIDs.contains($0.id) }, remaining: kept)
    }

    /// Removes all history, newest batch included.
    @discardableResult
    public func clear() throws -> HistoryPruneResult {
        let lock = ExecutionLock(path: HostPathResolver.join(appSupport, "execution.lock"))
        try lock.acquire()
        defer { lock.release() }
        return try remove(collect(), remaining: [])
    }

    // MARK: - collection

    /// Every batch, newest first.
    private func collect() -> [Batch] {
        let fileManager = FileManager.default
        var batches: [Batch] = []
        var claimedSnapshots = Set<String>()
        let recordNames = (try? fileManager.contentsOfDirectory(atPath: executionsRoot)) ?? []
        for name in recordNames.sorted() where Self.isBatchEntry(name) {
            let directory = HostPathResolver.join(executionsRoot, name)
            let record = fileManager.contents(
                atPath: HostPathResolver.join(directory, "record.json")
            ).flatMap { try? JSONDecoder().decode(ExecutionRecord.self, from: $0) }
            var snapshotID = record?.snapshotID
            if let id = snapshotID, Self.isBatchEntry(id), !claimedSnapshots.contains(id) {
                claimedSnapshots.insert(id)
            } else {
                snapshotID = nil
            }
            let snapshotBytes =
                snapshotID.map { Self.size(of: HostPathResolver.join(snapshotsRoot, $0)) } ?? 0
            let date = record.flatMap { Self.parse($0.startedAt) } ?? Self.modified(directory)
            batches.append(
                Batch(
                    id: name, date: date, recordName: name, snapshotID: snapshotID,
                    bytes: Self.size(of: directory) + snapshotBytes))
        }
        let store = SnapshotStore(environment: environment)
        let snapshotNames = (try? fileManager.contentsOfDirectory(atPath: snapshotsRoot)) ?? []
        for name in snapshotNames.sorted() where Self.isBatchEntry(name) {
            guard !claimedSnapshots.contains(name) else { continue }
            let path = HostPathResolver.join(snapshotsRoot, name)
            let date =
                (try? store.load(id: name)).flatMap { Self.parse($0.createdAt) }
                ?? Self.modified(path)
            batches.append(
                Batch(
                    id: name, date: date, recordName: nil, snapshotID: name,
                    bytes: Self.size(of: path)))
        }
        return batches.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Dotfiles and staging directories are never batches; names must be a
    /// single safe path component.
    private static func isBatchEntry(_ name: String) -> Bool {
        !name.hasPrefix(".") && (try? SnapshotStore.validateSnapshotID(name)) != nil
    }

    private func remove(_ victims: [Batch], remaining: [Batch]) throws -> HistoryPruneResult {
        let fileManager = FileManager.default
        var removed: [String] = []
        var reclaimed: Int64 = 0
        var firstError: Error?
        for batch in victims {
            do {
                if let id = batch.snapshotID {
                    let path = HostPathResolver.join(snapshotsRoot, id)
                    if fileManager.fileExists(atPath: path) {
                        try fileManager.removeItem(atPath: path)
                    }
                }
                if let name = batch.recordName {
                    try fileManager.removeItem(atPath: HostPathResolver.join(executionsRoot, name))
                }
                removed.append(batch.id)
                reclaimed += batch.bytes
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError, removed.isEmpty {
            throw firstError
        }
        let failed = victims.filter { !removed.contains($0.id) }
        return HistoryPruneResult(
            removedBatches: removed, reclaimedBytes: reclaimed,
            remainingBatches: remaining.count + failed.count,
            remainingBytes: (remaining + failed).reduce(0) { $0 + $1.bytes })
    }

    // MARK: - file helpers

    private static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func modified(_ path: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    }

    /// Allocated bytes of regular files under `path`; symlinks are not followed.
    private static func size(of path: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
