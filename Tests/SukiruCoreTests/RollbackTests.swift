import Foundation
import Testing

@testable import SukiruCore

/// Shared builders for the rollback engine suites: sandboxed execution of a
/// direct file-operation batch (no external CLIs needed) against the
/// SnapshotTestSupport tree.
enum RollbackTestSupport {
    /// The environment the executor, rollback, and scans all share.
    static func environment(home: String, project: String) -> SukiruEnvironment {
        SukiruEnvironment(
            reader: DictionaryEnvironmentReader(
                ["SUKIRU_HOME": home, "SUKIRU_ROOTS": project]))
    }

    /// The ownerless-cleanup direct file operation (the only non-CLI
    /// command class, always danger-flagged).
    static func deleteCommand(path: String) -> BatchCommand {
        BatchCommand(
            argv: ["sukiru-fileop", "delete-directory", path],
            displayString: "sukiru-fileop delete-directory \(path)",
            owningCLI: .file,
            intent: "Delete the ownerless skill directory.",
            dangerFlags: [.directFileOperation, .ownerlessCleanup],
            warning: "Direct file operation on an ownerless skill.")
    }

    /// A reviewed batch deleting the given ownerless skill directory.
    static func cleanupBatch(
        id: String = "batch-1", refs: [FindingRef], path: String
    ) -> CommandBatch {
        CommandBatch(
            id: id,
            createdAt: "2026-09-16T00:00:00Z",
            findingRefs: refs,
            decisions: [],
            commands: [deleteCommand(path: path)],
            snapshotID: nil,
            status: .reviewed)
    }

    /// Executes a batch through the real executor (snapshot + diff included).
    static func execute(
        _ batch: CommandBatch, report: ScanReport, environment: SukiruEnvironment
    ) throws -> ExecutionResult {
        try CLIExecutor(environment: environment).execute(batch: batch, report: report)
    }

    /// The persisted record.json of an executed batch, decoded.
    static func persistedRecord(
        batchID: String, environment: SukiruEnvironment
    ) throws -> ExecutionRecord {
        let path = HostPathResolver.join(
            environment.home,
            "Library/Application Support/Sukiru/executions/\(batchID)/record.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ExecutionRecord.self, from: data)
    }
}

/// One-click rollback:
/// restores ledgers byte-exact, restores payloads, deletes batch-added
/// paths (including placements a rescan finds beyond the watched dirs),
/// works for succeeded AND failed batches, and itemizes every outcome
/// honestly. No compensating CLI commands anywhere.
/// Serialized because these tests execute batches through
/// the real CLIExecutor, whose reaper starves under parallel scheduling.
@Suite("Rollback engine", .serialized)
struct RollbackEngineTests {
    private typealias Support = SnapshotTestSupport
    private typealias Roll = RollbackTestSupport

    @Test("Execution attaches the post-run diff to the batch record")
    func executorAttachesDiff() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let result = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: tree.report, environment: environment)
        #expect(result.batch.status == .succeeded)
        #expect(result.batch.snapshotID == result.record.snapshotID)
        let diff = result.record.diff
        #expect(
            diff.entries.contains { $0.kind == .placementRemoved && $0.path == orphan })
        #expect(!diff.isEmpty)
        // The persisted record carries the diff and the affected-scope
        // coordinates a later rollback needs for its rescan.
        let persisted = try Roll.persistedRecord(batchID: "batch-1", environment: environment)
        #expect(persisted.diff == diff)
        #expect(persisted.affectedWorkspaceIDs == ["user"])
        #expect(persisted.affectedScope == .user)
        #expect(persisted.affectedRoots == [])
    }

    @Test("Rollback of a succeeded batch restores byte-identical pre-batch state")
    func rollbackSucceededBatch() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let before = try TreeChecksum.manifest(root: orphan)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let result = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: tree.report, environment: environment)
        #expect(!FileManager.default.fileExists(atPath: orphan))

        let record = try Rollback(environment: environment).rollback(batchID: "batch-1")

        #expect(record.batchStatus == .rolledBack)
        #expect(record.snapshotID == result.record.snapshotID)
        let orphanItem = try #require(record.items.first { $0.path == orphan })
        #expect(orphanItem.category == .restoredFromSnapshot)
        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
        #expect(try TreeChecksum.manifest(root: orphan) == before)
        // A post-rollback rescan byte-matches the original pre-batch scan:
        // same placements, same ownership, same findings.
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        #expect(try post.jsonData() == tree.report.jsonData())
        // The batch transcript flips to rolledBack and the rollback record
        // is persisted next to it.
        let persisted = try Roll.persistedRecord(batchID: "batch-1", environment: environment)
        #expect(persisted.batchStatus == .rolledBack)
        let rollbackFile = HostPathResolver.join(
            persisted.recordDirectory, "rollback.json")
        let rollbackData = try Data(contentsOf: URL(fileURLWithPath: rollbackFile))
        let decoded = try JSONDecoder().decode(RollbackRecord.self, from: rollbackData)
        #expect(decoded == record)
    }

    @Test("Rollback of a FAILED batch undoes the commands that did run")
    func rollbackFailedBatch() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        // Command 2 can never run: its executable does not exist.
        let ghost = BatchCommand(
            argv: ["sukiru-definitely-missing-cli", "update", "orphan"],
            displayString: "sukiru-definitely-missing-cli update orphan",
            owningCLI: .vercel,
            intent: "Stand-in for a CLI update that cannot start.",
            dangerFlags: [],
            warning: nil)
        let batch = CommandBatch(
            id: "batch-1",
            createdAt: "2026-09-16T00:00:00Z",
            findingRefs: refs,
            decisions: [],
            commands: [Roll.deleteCommand(path: orphan), ghost],
            snapshotID: nil,
            status: .reviewed)
        let result = try Roll.execute(batch, report: tree.report, environment: environment)
        #expect(result.record.batchStatus == .failed)
        #expect(result.record.commands[0].status == .succeeded)
        #expect(result.record.commands[1].failureKind == .executableMissing)
        #expect(!FileManager.default.fileExists(atPath: orphan))

        let record = try Rollback(environment: environment).rollback(batchID: "batch-1")

        #expect(record.batchStatus == .rolledBack)
        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        #expect(try post.jsonData() == tree.report.jsonData())
    }

    @Test("Rollback deletes placements sprayed into a previously-empty host dir")
    func rollbackDeletesSprayedPlacements() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        _ = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: tree.report, environment: environment)
        // Simulate an npx symlink-spray into a fresh host layout: .qoder
        // did not exist pre-batch, so the manifest's watched-dir sweep
        // cannot see this placement — only the rollback-time rescan can.
        try tree.home.file(
            ".qoder/skills/sprayed/SKILL.md", contents: OwnershipBuilders.skillMD("sprayed"))
        let sprayed = tree.home.path + "/.qoder/skills/sprayed"

        let record = try Rollback(environment: environment).rollback(batchID: "batch-1")

        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: sprayed))
        let item = try #require(record.items.first { $0.path == sprayed })
        #expect(item.category == .deletedBatchAdded)
        // The spray-created container dirs go too: the sandbox returns to
        // the pre-batch state byte-for-byte.
        #expect(!fileManager.fileExists(atPath: tree.home.path + "/.qoder"))
        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        #expect(try post.jsonData() == tree.report.jsonData())
    }

    @Test("Rollback preserves a pre-existing EMPTY host skills dir after a spray")
    func rollbackPreservesPreExistingEmptyHostDir() throws {
        let tree = try Support.makeTree()
        // A host skills dir that EXISTS pre-batch but holds zero placements
        // (empty ~/.qoder/skills): the pre-batch scan enumerates it as a
        // leftover workspace, so the snapshot records it as pre-existing
        // and the empty-ancestor pruning must not eat it.
        let emptyHost = try tree.home.dir(".qoder/skills")
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let preBatch = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        _ = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: preBatch, environment: environment)
        // The spray lands in the pre-existing empty host dir.
        try tree.home.file(
            ".qoder/skills/sprayed/SKILL.md", contents: OwnershipBuilders.skillMD("sprayed"))
        let sprayed = tree.home.path + "/.qoder/skills/sprayed"

        let record = try Rollback(environment: environment).rollback(batchID: "batch-1")

        let fileManager = FileManager.default
        let sprayedItem = try #require(record.items.first { $0.path == sprayed })
        #expect(sprayedItem.category == .deletedBatchAdded)
        #expect(!fileManager.fileExists(atPath: sprayed))
        // The pre-existing containers survive and are NOT itemized as
        // deleted-batch-added (byte-equality).
        let qoder = tree.home.path + "/.qoder"
        #expect(fileManager.fileExists(atPath: emptyHost))
        #expect(fileManager.fileExists(atPath: qoder))
        #expect(!record.items.contains { $0.path == emptyHost || $0.path == qoder })
        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
        // A post-rollback rescan byte-matches the pre-batch scan, empty
        // host dir included.
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        #expect(try post.jsonData() == preBatch.jsonData())
    }

    @Test("An unrestorable payload is itemized honestly, never silently dropped")
    func unrestorableItemReported() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let result = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: tree.report, environment: environment)
        // The constructible unrestorable fixture: make a
        // snapshot payload file unreadable between snapshot and rollback.
        let store = SnapshotStore(environment: environment)
        let manifest = try store.load(id: result.record.snapshotID)
        let payload = try #require(manifest.payloads.first { $0.path == orphan })
        let storedFile = HostPathResolver.join(
            store.snapshotsRoot(), manifest.id + "/" + payload.storedDir + "/SKILL.md")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: storedFile)

        let record = try Rollback(environment: environment).rollback(batchID: "batch-1")

        let item = try #require(record.items.first { $0.path == orphan })
        #expect(item.category == .unrestorableWithReason)
        #expect(item.reason != nil)
        // Every item uses exactly the three-category vocabulary.
        let categories: Set<RestoreItem.Category> = [
            .restoredFromSnapshot, .deletedBatchAdded, .unrestorableWithReason
        ]
        #expect(record.items.allSatisfy { categories.contains($0.category) })
        // Independent items still restore.
        let alias = tree.home.path + "/.claude/skills/orphan"
        #expect(record.items.first { $0.path == alias }?.category == .restoredFromSnapshot)
        // The persisted record tells the same honest story.
        let rollbackFile = HostPathResolver.join(
            result.record.recordDirectory, "rollback.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: rollbackFile))
        let decoded = try JSONDecoder().decode(RollbackRecord.self, from: data)
        #expect(decoded.items == record.items)
    }

    @Test("A second rollback of the same batch is refused")
    func doubleRollbackRefused() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        _ = try Roll.execute(
            Roll.cleanupBatch(refs: refs, path: orphan),
            report: tree.report, environment: environment)
        _ = try Rollback(environment: environment).rollback(batchID: "batch-1")
        do {
            _ = try Rollback(environment: environment).rollback(batchID: "batch-1")
            Issue.record("expected a refusal")
        } catch let error as RollbackError {
            #expect(error == .alreadyRolledBack("batch-1"))
        }
    }

    @Test("Rollback of an unknown batch is refused without touching disk")
    func unknownBatchRefused() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        do {
            _ = try Rollback(environment: environment).rollback(batchID: "no-such-batch")
            Issue.record("expected a refusal")
        } catch let error as RollbackError {
            #expect(error == .unknownBatch("no-such-batch"))
        }
    }

    @Test("Path-traversal batch ids are refused")
    func traversalBatchIDRefused() throws {
        let tree = try Support.makeTree()
        let environment = Roll.environment(home: tree.home.path, project: tree.project.path)
        do {
            _ = try Rollback(environment: environment).rollback(batchID: "../..")
            Issue.record("expected a refusal")
        } catch let error as RollbackError {
            #expect(error == .invalidBatchID("../.."))
        }
    }
}
