import Foundation
import Testing

@testable import SukiruCore

/// Snapshot capture: storage location, byte-exact ledgers, placement
/// manifest, full payload copies of every touched skill dir regardless of
/// ownership (VAL-REPAIR-024/025/050, architecture §4.1 SnapshotStore + D9).
@Suite("SnapshotStore capture")
struct SnapshotStoreCaptureTests {
    private typealias Support = SnapshotTestSupport

    @Test("Snapshots live under <home>/Library/Application Support/Sukiru/snapshots")
    func storageRoot() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let suffix = "/Library/Application Support/Sukiru/snapshots"
        #expect(store.snapshotsRoot() == tree.home.path + suffix)
    }

    @Test("Capture stores byte-exact copies of both ledger files")
    func ledgerCopiesByteExact() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: Support.userAndProjectRefs(project: tree.project))
        let manifest = try store.capture(batch: batch, report: tree.report)
        let dir = store.snapshotsRoot() + "/" + manifest.id
        let byPath = Dictionary(uniqueKeysWithValues: manifest.ledgers.map { ($0.path, $0) })
        let global = try #require(byPath[tree.home.path + "/.agents/.skill-lock.json"])
        #expect(global.existed)
        let project = try #require(byPath[tree.project.path + "/skills-lock.json"])
        #expect(project.existed)
        // Untouched probe candidates are recorded as absent so rollback can
        // delete a lock the batch creates there.
        let agents = try #require(byPath[tree.project.path + "/.agents/.skill-lock.json"])
        #expect(!agents.existed)
        #expect(!agents.existed && agents.storedFile == nil)
        for ledger in [global, project] {
            let stored = try #require(ledger.storedFile)
            let copy = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + stored))
            let original = try Data(contentsOf: URL(fileURLWithPath: ledger.path))
            #expect(copy == original)
            #expect(ledger.sha256 == Support.sha256Hex(original))
        }
        #expect(manifest.batchID == batch.id)
        // The committed manifest round-trips through the traversal-safe load.
        let loaded = try store.load(id: manifest.id)
        #expect(loaded == manifest)
    }

    @Test("Placement manifest matches the pre-run scan for the affected roots")
    func placementManifestMatchesScan() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: Support.userAndProjectRefs(project: tree.project))
        let manifest = try store.capture(batch: batch, report: tree.report)
        let expected = tree.report.skills.flatMap(\.placements).map {
            "\($0.path)|\($0.kind.rawValue)|\($0.linkTarget ?? "-")|\($0.contentHash ?? "-")"
        }.sorted()
        let actual = manifest.placements.map {
            "\($0.path)|\($0.kind.rawValue)|\($0.linkTarget ?? "-")|\($0.hash ?? "-")"
        }
        // Manifest entries are sorted by path; scan values carry through.
        #expect(actual == expected)
        let alias = tree.home.path + "/.claude/skills/orphan"
        let aliasEntry = manifest.placements.first { $0.path == alias }
        #expect(aliasEntry?.kind == .symlink)
        #expect(aliasEntry?.linkTarget == "../../.agents/skills/orphan")
    }

    @Test("Payload copies are full recursive copies of every touched skill dir, any ownership")
    func payloadCopiesFullRecursive() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: Support.userAndProjectRefs(project: tree.project))
        let manifest = try store.capture(batch: batch, report: tree.report)
        var sources = [tree.home.path + "/.agents/skills/orphan"]
        sources.append(tree.project.path + "/.claude/skills/tool")
        #expect(manifest.payloads.map(\.path).sorted() == sources.sorted())
        for payload in manifest.payloads {
            let stored = store.snapshotsRoot() + "/" + manifest.id + "/" + payload.storedDir
            let before = try TreeChecksum.manifest(root: payload.path)
            let copy = try TreeChecksum.manifest(root: stored)
            #expect(copy == before)
            let digest = try PayloadTree.digest(root: stored)
            #expect(payload.digest == digest)
        }
    }

    @Test("Skills the batch does not touch appear in the manifest but get no payload copy")
    func untouchedSkillManifestOnly() throws {
        let tree = try Support.makeTree()
        try tree.home.file(
            ".agents/skills/stray/SKILL.md", contents: OwnershipBuilders.skillMD("stray"))
        let report = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let store = Support.makeStore(home: tree.home.path)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: report)
        let stray = tree.home.path + "/.agents/skills/stray"
        #expect(manifest.placements.contains { $0.path == stray })
        #expect(!manifest.payloads.contains { $0.path == stray })
        let orphan = tree.home.path + "/.agents/skills/orphan"
        #expect(manifest.payloads.map(\.path) == [orphan])
        // A user-scope-only batch records no project lock candidates.
        #expect(!manifest.ledgers.contains { $0.path.hasPrefix(tree.project.path) })
        // The global lock is always captured (VAL-REPAIR-024).
        let globalLock = tree.home.path + "/.agents/.skill-lock.json"
        #expect(manifest.ledgers.contains { $0.path == globalLock })
    }

    @Test("Identical inputs produce byte-identical manifest.json")
    func deterministicManifestBytes() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: Support.userAndProjectRefs(project: tree.project))
        let first = try store.capture(batch: batch, report: tree.report)
        let path = store.snapshotsRoot() + "/" + first.id + "/manifest.json"
        let firstBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.removeItem(atPath: store.snapshotsRoot() + "/" + first.id)
        let second = try store.capture(batch: batch, report: tree.report)
        let secondBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(second.id == first.id)
        #expect(secondBytes == firstBytes)
    }

    @Test("Capturing over an existing snapshot id is refused")
    func duplicateIDRefused() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let batch = Support.batch(refs: [])
        _ = try store.capture(batch: batch, report: tree.report)
        #expect(throws: SnapshotError.self) {
            try store.capture(batch: batch, report: tree.report)
        }
    }
}

/// Retention pruning: at most 10 snapshots survive, oldest pruned first, and
/// every surviving manifest is complete and parseable at every inspection
/// point (VAL-REPAIR-026).
@Suite("SnapshotStore retention")
struct SnapshotStoreRetentionTests {
    private typealias Support = SnapshotTestSupport

    @Test("Retention keeps the newest 10; surviving manifests always parse")
    func retentionPrunesOldest() throws {
        let tree = try Support.makeTree()
        let ids = (1...11).map { String(format: "snap-%02d", $0) }
        let store = Support.makeStore(home: tree.home.path, ids: ids, dates: Support.dates(11))
        for index in 1...11 {
            let batch = Support.batch(id: "batch-\(index)", refs: [])
            _ = try store.capture(batch: batch, report: tree.report)
            for summary in store.list() {
                let manifest = try? store.load(id: summary.id)
                #expect(manifest?.id == summary.id)
            }
        }
        let survivors = store.list()
        #expect(survivors.count == 10)
        #expect(!survivors.contains { $0.id == "snap-01" })
        #expect(survivors.map(\.id) == Array(ids.dropFirst()))
    }

    @Test("list() returns snapshots oldest-first with batch correlation")
    func listOrderingAndBatchCorrelation() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(
            home: tree.home.path, ids: ["snap-1", "snap-2"], dates: Support.dates(2))
        _ = try store.capture(batch: Support.batch(id: "batch-a", refs: []), report: tree.report)
        _ = try store.capture(batch: Support.batch(id: "batch-b", refs: []), report: tree.report)
        let summaries = store.list()
        #expect(summaries.map(\.id) == ["snap-1", "snap-2"])
        #expect(summaries.map(\.batchID) == ["batch-a", "batch-b"])
    }
}

/// Path-traversal-safe load (VAL-REPAIR-024 store integrity): hostile ids
/// and hostile stored paths inside a manifest are rejected, never resolved.
@Suite("SnapshotStore load safety")
struct SnapshotStoreLoadSafetyTests {
    private typealias Support = SnapshotTestSupport

    @Test("Traversal-shaped snapshot ids are rejected")
    func traversalIDsRejected() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        for id in ["..", "../x", "a/b", "", "a\\b"] {
            #expect(throws: SnapshotError.invalidSnapshotID(id)) {
                try store.load(id: id)
            }
        }
        #expect(throws: SnapshotError.snapshotNotFound("missing")) {
            try store.load(id: "missing")
        }
    }

    @Test("A manifest whose stored paths escape the snapshot dir is rejected")
    func traversalStoredPathsRejected() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let payload = PayloadSnapshot(path: "/x", storedDir: "../../escape", digest: "d")
        try plantManifest(store: store, id: "evil-payload", payloads: [payload])
        #expect(throws: SnapshotError.self) {
            try store.load(id: "evil-payload")
        }
        let ledger = LedgerSnapshot(
            path: "/x", existed: true, storedFile: "/etc/passwd", sha256: "d")
        try plantManifest(store: store, id: "evil-ledger", ledgers: [ledger])
        let error = try #require(loadError(store: store, id: "evil-ledger"))
        guard case .unsafeManifestEntry = error else {
            Testing.Issue.record("expected unsafeManifestEntry, got \(error)")
            return
        }
    }

    @Test("A manifest whose id does not match its directory is unreadable")
    func mismatchedIDRejected() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        try plantManifest(store: store, id: "dir-name", manifestID: "other-id")
        #expect(throws: SnapshotError.manifestUnreadable("dir-name")) {
            try store.load(id: "dir-name")
        }
    }

    /// Writes a hand-built manifest.json into a snapshot dir, bypassing
    /// capture so hostile content can be planted.
    private func plantManifest(
        store: SnapshotStore,
        id: String,
        manifestID: String? = nil,
        ledgers: [LedgerSnapshot] = [],
        payloads: [PayloadSnapshot] = []
    ) throws {
        let manifest = SnapshotManifest(
            schemaVersion: SnapshotManifest.currentSchemaVersion,
            id: manifestID ?? id,
            batchID: "batch-evil",
            createdAt: "2026-09-16T00:00:00Z",
            ledgers: ledgers,
            placements: [],
            payloads: payloads,
            watchedDirectories: [])
        let dir = store.snapshotsRoot() + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: dir + "/manifest.json"))
    }

    private func loadError(store: SnapshotStore, id: String) -> SnapshotError? {
        do {
            _ = try store.load(id: id)
            return nil
        } catch let error as SnapshotError {
            return error
        } catch {
            return nil
        }
    }
}
