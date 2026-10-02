import Foundation
import Testing

@testable import SukiruCore

/// Deleting a batch from history removes its record and its snapshot, and
/// leaves the skills on disk alone.
@Suite("Execution history deletion", .serialized)
struct ExecutionHistoryTests {
    private typealias Support = SnapshotTestSupport
    private typealias Roll = RollbackTestSupport

    @Test("Delete removes the record and the snapshot")
    func deleteRemovesRecordAndSnapshot() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let result = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: tree.report, environment: environment)
        let store = SnapshotStore(environment: environment)
        #expect(store.list().map(\.id) == [result.record.snapshotID])

        try ExecutionHistory(environment: environment).delete(batchID: "batch-1")

        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: result.record.recordDirectory))
        #expect(throws: RollbackError.unknownBatch("batch-1")) {
            try Rollback(environment: environment).rollback(batchID: "batch-1")
        }
    }

    @Test("Delete refuses unknown and unsafe ids")
    func deleteRefusesBadIDs() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let history = ExecutionHistory(environment: environment)
        #expect(throws: RollbackError.unknownBatch("missing")) {
            try history.delete(batchID: "missing")
        }
        #expect(throws: RollbackError.invalidBatchID("../x")) {
            try history.delete(batchID: "../x")
        }
    }
}
