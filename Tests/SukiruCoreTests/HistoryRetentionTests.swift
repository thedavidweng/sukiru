import Foundation
import Testing

@testable import SukiruCore

/// A temporary home holding fabricated history: execution records and the
/// snapshots they point at, with controllable ages and sizes.
private struct HistoryFixture {
    let now: Date
    let home: TempTree

    init(now: Date = Date(timeIntervalSince1970: 1_760_000_000)) throws {
        home = try TempTree()
        self.now = now
    }

    var environment: SukiruEnvironment {
        SukiruEnvironment(reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home.path]))
    }

    var retention: HistoryRetention {
        let fixed = now
        return HistoryRetention(environment: environment, now: { fixed })
    }

    var appSupport: String { home.path + "/Library/Application Support/Sukiru" }

    func recordExists(_ batch: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(appSupport)/executions/\(batch)")
    }

    func snapshotExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(appSupport)/snapshots/\(id)")
    }

    /// A batch whose record started `daysAgo` days before `now` (plus `offset`
    /// seconds), with a snapshot carrying `kilobytes` of payload.
    func addBatch(
        _ id: String, daysAgo: Double = 0, offset: Double = 0, kilobytes: Int = 1,
        withSnapshot: Bool = true
    ) throws {
        let started = now.addingTimeInterval(-daysAgo * 86_400 + offset)
        let formatter = ISO8601DateFormatter()
        let directory = "\(appSupport)/executions/\(id)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let record = ExecutionRecord(
            batchID: id, snapshotID: "snap-\(id)", batchStatus: .succeeded,
            commandTimeoutSeconds: 1, startedAt: formatter.string(from: started),
            endedAt: formatter.string(from: started), durationSeconds: 0,
            recordDirectory: directory, commands: [],
            diff: BatchDiff(entries: [], summary: []), affectedRoots: [], affectedScope: .all,
            affectedWorkspaceIDs: [])
        try record.jsonData().write(to: URL(fileURLWithPath: directory + "/record.json"))
        if withSnapshot {
            try addSnapshotFiles("snap-\(id)", kilobytes: kilobytes)
        }
    }

    /// A snapshot directory without a manifest, dated by its modification time.
    func addOrphanSnapshot(_ id: String, daysAgo: Double = 0, kilobytes: Int = 1) throws {
        try addSnapshotFiles(id, kilobytes: kilobytes)
        let modified = now.addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: "\(appSupport)/snapshots/\(id)")
    }

    private func addSnapshotFiles(_ id: String, kilobytes: Int) throws {
        let directory = "\(appSupport)/snapshots/\(id)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try Data(count: kilobytes * 1024).write(
            to: URL(fileURLWithPath: directory + "/payload.bin"))
    }
}

@Suite("History retention", .serialized)
struct HistoryRetentionTests {
    @Test("Count limit drops the oldest batches, record and snapshot together")
    func countLimit() throws {
        let fixture = try HistoryFixture()
        for index in 1...5 {
            try fixture.addBatch("b\(index)", offset: Double(index))
        }
        let result = try fixture.retention.prune(policy: RetentionPolicy(maxBatches: 3))
        #expect(Set(result.removedBatches) == ["b1", "b2"])
        #expect(result.remainingBatches == 3)
        for gone in ["b1", "b2"] {
            #expect(!fixture.recordExists(gone) && !fixture.snapshotExists("snap-\(gone)"))
        }
        for kept in ["b3", "b4", "b5"] {
            #expect(fixture.recordExists(kept) && fixture.snapshotExists("snap-\(kept)"))
        }
    }

    @Test("Age limit drops batches older than the configured days")
    func ageLimit() throws {
        let fixture = try HistoryFixture()
        try fixture.addBatch("old", daysAgo: 45)
        try fixture.addBatch("edge", daysAgo: 29)
        try fixture.addBatch("new", daysAgo: 1)
        let result = try fixture.retention.prune(policy: RetentionPolicy(maxAgeDays: 30))
        #expect(result.removedBatches == ["old"])
        #expect(!fixture.recordExists("old") && !fixture.snapshotExists("snap-old"))
        #expect(fixture.recordExists("edge") && fixture.recordExists("new"))
    }

    @Test("Size limit removes the oldest first")
    func sizeLimit() throws {
        let fixture = try HistoryFixture()
        for index in 1...3 {
            try fixture.addBatch("b\(index)", offset: Double(index), kilobytes: 600)
        }
        let result = try fixture.retention.prune(policy: RetentionPolicy(maxSizeMegabytes: 1))
        #expect(Set(result.removedBatches) == ["b1", "b2"])
        #expect(fixture.recordExists("b3") && fixture.snapshotExists("snap-b3"))
        #expect(result.remainingBytes <= 1_048_576)
        #expect(fixture.retention.usage().batches == 1)
    }

    @Test("The newest batch survives every limit")
    func newestAlwaysKept() throws {
        let fixture = try HistoryFixture()
        try fixture.addBatch("ancient", daysAgo: 400, kilobytes: 2048)
        let result = try fixture.retention.prune(
            policy: RetentionPolicy(maxBatches: 1, maxAgeDays: 1, maxSizeMegabytes: 1))
        #expect(result.removedBatches.isEmpty)
        #expect(fixture.recordExists("ancient") && fixture.snapshotExists("snap-ancient"))
    }

    @Test("Orphan snapshots and records without snapshots count as batches")
    func orphans() throws {
        let fixture = try HistoryFixture()
        try fixture.addOrphanSnapshot("orphan-old", daysAgo: 60)
        try fixture.addBatch("no-snapshot", daysAgo: 50, withSnapshot: false)
        try fixture.addBatch("current", daysAgo: 0)
        let result = try fixture.retention.prune(policy: RetentionPolicy(maxAgeDays: 30))
        #expect(Set(result.removedBatches) == ["orphan-old", "no-snapshot"])
        #expect(!fixture.snapshotExists("orphan-old") && !fixture.recordExists("no-snapshot"))
        #expect(fixture.recordExists("current") && fixture.snapshotExists("snap-current"))
    }

    @Test("Staging directories and files outside history are never touched")
    func pathSafety() throws {
        let fixture = try HistoryFixture()
        try fixture.addBatch("current")
        let staging = fixture.appSupport + "/snapshots/.staging-x"
        try FileManager.default.createDirectory(
            atPath: staging, withIntermediateDirectories: true)
        let outside = try fixture.home.file("outside.txt", contents: "keep")
        _ = try fixture.retention.prune(policy: RetentionPolicy(maxBatches: 1))
        #expect(FileManager.default.fileExists(atPath: staging))
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test("Clear removes all history, including the newest batch")
    func clearAll() throws {
        let fixture = try HistoryFixture()
        try fixture.addBatch("a", offset: 1)
        try fixture.addBatch("b", offset: 2)
        try fixture.addOrphanSnapshot("orphan")
        let result = try fixture.retention.clear()
        #expect(Set(result.removedBatches) == ["a", "b", "orphan"])
        #expect(result.remainingBatches == 0)
        #expect(fixture.retention.usage() == HistoryUsage(batches: 0, bytes: 0))
    }

    @Test("Pruning refuses while another process holds the execution lock")
    func busyLock() throws {
        let fixture = try HistoryFixture()
        try fixture.addBatch("a", offset: 1)
        try fixture.addBatch("b", offset: 2)
        let lock = ExecutionLock(path: fixture.appSupport + "/execution.lock")
        try lock.acquire()
        defer { lock.release() }
        #expect(throws: ExecutionError.self) {
            try fixture.retention.prune(policy: RetentionPolicy(maxBatches: 1))
        }
        #expect(throws: ExecutionError.self) { try fixture.retention.clear() }
        #expect(fixture.recordExists("a"))
    }
}

@Suite("Retention settings")
struct RetentionSettingsTests {
    private func store(_ home: TempTree) -> SukiruSettingsStore {
        SukiruSettingsStore(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home.path])))
    }

    @Test("Missing settings file yields the defaults")
    func missingFile() throws {
        let policy = store(try TempTree()).retentionPolicy()
        #expect(policy == RetentionPolicy(maxBatches: 20, maxAgeDays: 30, maxSizeMegabytes: 1024))
    }

    @Test("A saved policy round-trips through settings.json")
    func roundTrip() throws {
        let home = try TempTree()
        let saved = RetentionPolicy(maxBatches: 5, maxAgeDays: 7, maxSizeMegabytes: 64)
        try store(home).save(saved)
        #expect(store(home).retentionPolicy() == saved)
        let path = home.path + "/Library/Application Support/Sukiru/settings.json"
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Corrupt settings fall back to the defaults; bad fields fall back individually")
    func corruptFile() throws {
        let home = try TempTree()
        try home.file("Library/Application Support/Sukiru/settings.json", contents: "{not json")
        #expect(store(home).retentionPolicy() == .default)
        try home.file(
            "Library/Application Support/Sukiru/settings.json",
            contents: #"{"retention":{"maxBatches":"many","maxAgeDays":3}}"#)
        let policy = store(home).retentionPolicy()
        #expect(policy.maxBatches == 20 && policy.maxAgeDays == 3)
        #expect(policy.maxSizeMegabytes == 1024)
    }

    @Test("Prune applies the stored policy")
    func storedPolicyApplies() throws {
        let fixture = try HistoryFixture()
        for index in 1...3 {
            try fixture.addBatch("b\(index)", offset: Double(index))
        }
        try SukiruSettingsStore(environment: fixture.environment)
            .save(RetentionPolicy(maxBatches: 1))
        let result = try fixture.retention.prune()
        #expect(result.remainingBatches == 1)
        #expect(fixture.recordExists("b3"))
    }
}

@Suite("sukiru history CLI", .serialized)
struct HistoryCLIIntegrationTests {
    @Test("history prune and clear report JSON and honour settings.json")
    func pruneAndClear() throws {
        let fixture = try HistoryFixture(now: Date())
        for index in 1...3 {
            try fixture.addBatch("b\(index)", daysAgo: 1, offset: Double(index))
        }
        try SukiruSettingsStore(environment: fixture.environment)
            .save(RetentionPolicy(maxBatches: 2))
        let env = CLIRunner.fixtureEnvironment(home: fixture.home.path)

        let pruned = try CLIRunner.run(["history", "prune"], environment: env)
        #expect(pruned.exitCode == 0)
        let prunedJSON = try #require(try pruned.jsonObject())
        #expect(prunedJSON["removedBatches"] as? [String] == ["b1"])
        #expect(prunedJSON["remainingBatches"] as? Int == 2)
        #expect(!fixture.recordExists("b1") && fixture.recordExists("b2"))

        let refused = try CLIRunner.run(["history", "clear"], environment: env)
        #expect(refused.exitCode != 0)
        #expect(fixture.recordExists("b3"))

        let cleared = try CLIRunner.run(["history", "clear", "--yes"], environment: env)
        #expect(cleared.exitCode == 0)
        let clearedJSON = try #require(try cleared.jsonObject())
        #expect(Set(clearedJSON["removedBatches"] as? [String] ?? []) == ["b2", "b3"])
        #expect(fixture.retention.usage().batches == 0)
    }
}
