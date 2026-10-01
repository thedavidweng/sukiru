import Foundation
import Testing

@testable import SukiruCore

/// Snapshot restore: byte-identical payload and ledger restoration,
/// children-before-parents ordering, manifest-diff deletion of batch-added
/// paths, and honest unrestorable reporting.
@Suite("SnapshotStore restore")
struct SnapshotStoreRestoreTests {
    private typealias Support = SnapshotTestSupport

    @Test("Restore reproduces the pre-batch tree byte-identically, symlinks included")
    func restoreNestedTree() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let before = try TreeChecksum.manifest(root: orphan)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        // Simulate the ownerless cleanup: the skill dir is deleted and the
        // `.claude` alias link dangles.
        let alias = tree.home.path + "/.claude/skills/orphan"
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: orphan)
        let record = try store.restore(id: manifest.id)
        let after = try TreeChecksum.manifest(root: orphan)
        #expect(after == before)
        let kind = DefaultFileSystemProbe().entryKind(atPath: alias)
        #expect(kind == .symlink(target: "../../.agents/skills/orphan"))
        let orphanItem = record.items.first { $0.path == orphan }
        #expect(orphanItem?.category == .restoredFromSnapshot)
        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
        #expect(record.snapshotID == manifest.id)
    }

    @Test("Restore deletes batch-added paths per the manifest diff")
    func restoreDeletesBatchAdded() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: Support.userAndProjectRefs(project: tree.project))
        let manifest = try store.capture(batch: batch, report: tree.report)
        // Batch-added junk: a file and a nested dir inside watched skills
        // dirs, plus a lock file at a probe candidate absent pre-batch.
        let junkFile = try tree.home.file(".claude/skills/junk.txt", contents: "junk")
        _ = try tree.home.dir(".claude/skills/junk-skill/nested")
        let junkDir = tree.home.path + "/.claude/skills/junk-skill"
        let createdLock = try tree.project.file(".skill-lock.json", contents: "{}")
        let record = try store.restore(id: manifest.id)
        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: junkFile))
        #expect(!fileManager.fileExists(atPath: junkDir))
        #expect(!fileManager.fileExists(atPath: createdLock))
        let deleted = record.items.filter { $0.category == .deletedBatchAdded }.map(\.path)
        #expect(deleted.contains(junkFile))
        #expect(deleted.contains(junkDir))
        #expect(deleted.contains(createdLock))
        // Pre-existing content is untouched by the sweep.
        let orphanSkill = tree.home.path + "/.agents/skills/orphan/SKILL.md"
        #expect(fileManager.fileExists(atPath: orphanSkill))
        #expect(fileManager.fileExists(atPath: tree.project.path + "/skills-lock.json"))
        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
    }

    @Test("Restore rewrites ledger files byte-exactly")
    func restoreLedgersByteExact() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: Support.userAndProjectRefs(project: tree.project))
        let manifest = try store.capture(batch: batch, report: tree.report)
        let global = tree.home.path + "/.agents/.skill-lock.json"
        let project = tree.project.path + "/skills-lock.json"
        let originalGlobal = try Data(contentsOf: URL(fileURLWithPath: global))
        let originalProject = try Data(contentsOf: URL(fileURLWithPath: project))
        try Data("corrupted-global".utf8).write(to: URL(fileURLWithPath: global))
        try Data("corrupted-project".utf8).write(to: URL(fileURLWithPath: project))
        let record = try store.restore(id: manifest.id)
        let restoredGlobal = try Data(contentsOf: URL(fileURLWithPath: global))
        let restoredProject = try Data(contentsOf: URL(fileURLWithPath: project))
        #expect(restoredGlobal == originalGlobal)
        #expect(restoredProject == originalProject)
        let restored = record.items.filter { $0.category == .restoredFromSnapshot }.map(\.path)
        #expect(restored.contains(global))
        #expect(restored.contains(project))
    }

    @Test("A symlink placement replaced by a real directory is restored as a symlink")
    func restoreSymlinkKind() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        let alias = tree.home.path + "/.claude/skills/orphan"
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: alias)
        try fileManager.createDirectory(atPath: alias, withIntermediateDirectories: true)
        try Data("impostor".utf8).write(to: URL(fileURLWithPath: alias + "/SKILL.md"))
        let record = try store.restore(id: manifest.id)
        let kind = DefaultFileSystemProbe().entryKind(atPath: alias)
        #expect(kind == .symlink(target: "../../.agents/skills/orphan"))
        let item = record.items.first { $0.path == alias }
        #expect(item?.category == .restoredFromSnapshot)
    }

    @Test("A payload made unreadable between snapshot and restore is reported unrestorable")
    func restoreReportsUnrestorable() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let orphan = tree.home.path + "/.agents/skills/orphan"
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        // Sabotage the STORED payload: the constructible unrestorable fixture.
        let payload = try #require(manifest.payloads.first { $0.path == orphan })
        let snapshotDir = store.snapshotsRoot() + "/" + manifest.id
        let storedFile = snapshotDir + "/" + payload.storedDir + "/SKILL.md"
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storedFile)
        // No chmod-back needed: unlink needs only parent-dir write permission.
        try fileManager.removeItem(atPath: orphan)
        let record = try store.restore(id: manifest.id)
        let item = try #require(record.items.first { $0.path == orphan })
        #expect(item.category == .unrestorableWithReason)
        #expect(item.reason != nil)
        // Independent items still restore.
        let alias = tree.home.path + "/.claude/skills/orphan"
        let aliasItem = record.items.first { $0.path == alias }
        #expect(aliasItem?.category == .restoredFromSnapshot)
    }

    @Test("A non-payload placement that vanished during the batch is reported, not dropped")
    func vanishedUntouchedPlacementReported() throws {
        let tree = try Support.makeTree()
        try tree.home.file(
            ".agents/skills/stray/SKILL.md", contents: OwnershipBuilders.skillMD("stray"))
        let report = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let store = Support.makeStore(home: tree.home.path)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: report)
        let stray = tree.home.path + "/.agents/skills/stray"
        try FileManager.default.removeItem(atPath: stray)
        let record = try store.restore(id: manifest.id)
        let item = try #require(record.items.first { $0.path == stray })
        #expect(item.category == .unrestorableWithReason)
        #expect(item.reason != nil)
    }

    @Test("Deletions and restores order children before parents")
    func childrenBeforeParentsOrdering() {
        let ordered = SnapshotStore.descendingDepth(["/a", "/a/b", "/a/b/c", "/x"])
        #expect(ordered == ["/a/b/c", "/a/b", "/a", "/x"])
    }
}

/// End-to-end check over the committed corpus: a real scan + real
/// batch build feeding capture.
@Suite("SnapshotStore corpus integration")
struct SnapshotStoreIntegrationTests {
    private typealias Support = SnapshotTestSupport

    @Test("CM-1 update batch: manifest matches the scan, payloads checksum-equal")
    func cm1UpdateCapture() throws {
        // Copy the fixture into a sandbox: capture writes the snapshot store
        // under the fixture's .home, which must not mutate the check-in.
        let sandbox = try TempTree()
        let copy = sandbox.path + "/CM-1"
        try FileManager.default.copyItem(atPath: FixturePaths.tree("CM-1"), toPath: copy)
        let globalLock = copy + "/.home/.agents/.skill-lock.json"
        try FileManager.default.createDirectory(
            atPath: copy + "/.home/.agents", withIntermediateDirectories: true)
        let lockContents = OwnershipBuilders.globalLock([])
        try lockContents.write(toFile: globalLock, atomically: true, encoding: .utf8)
        var vars = ["SUKIRU_HOME": copy + "/.home"]
        vars["SUKIRU_ROOTS"] = copy + "/proj"
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        let report = try ScanEngine(environment: environment).scan(ScanRequest())
        let findingID = try BatchTestSupport.findingID(
            report, "cross-host-duplicate", "stale-docs-cleanup")
        let decisions = [BatchTestSupport.decide(findingID, .update)]
        let batch = try BatchTestSupport.build(report, decisions)
        let store = Support.makeStore(home: copy + "/.home")
        let manifest = try store.capture(batch: batch, report: report)
        // Both ledger files captured byte-exact.
        let byPath = Dictionary(uniqueKeysWithValues: manifest.ledgers.map { ($0.path, $0) })
        for lockPath in [globalLock, copy + "/proj/skills-lock.json"] {
            let ledger = try #require(byPath[lockPath])
            #expect(ledger.existed)
            let stored = try #require(ledger.storedFile)
            let dir = store.snapshotsRoot() + "/" + manifest.id
            let copyBytes = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + stored))
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: lockPath))
            #expect(copyBytes == originalBytes)
        }
        // Placement manifest == the scan's placements for the affected root.
        let expected = report.skills.flatMap(\.placements).map(\.path).sorted()
        #expect(manifest.placements.map(\.path) == expected)
        // Full payload copies of EVERY touched skill dir.
        var dirs = [copy + "/proj/.agents/skills/stale-docs-cleanup"]
        dirs.append(copy + "/proj/.claude/skills/stale-docs-cleanup")
        #expect(manifest.payloads.map(\.path).sorted() == dirs.sorted())
        for payload in manifest.payloads {
            let stored = store.snapshotsRoot() + "/" + manifest.id + "/" + payload.storedDir
            let source = try TreeChecksum.manifest(root: payload.path)
            let copyTree = try TreeChecksum.manifest(root: stored)
            #expect(copyTree == source)
        }
    }
}
