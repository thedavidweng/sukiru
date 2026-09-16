import Foundation
import Testing

@testable import SukiruCore

/// `sukiru-cli batch --execute` → post-run diff → `sukiru-cli rollback`
/// end-to-end (VAL-REPAIR-032…036): the diff is attached to the batch record
/// and lists precisely the real changes; an empty diff is explicit; rollback
/// restores the pre-batch state byte-identically for succeeded AND failed
/// batches; the rollback record itemizes every outcome in the three-category
/// vocabulary, including an honest unrestorable-with-reason.
/// Seam-B CLI suite: serialized per house rule (spawns the CLI, which may
/// spawn shim CLIs).
@Suite("sukiru-cli diff + rollback", .serialized)
struct RollbackCLIIntegrationTests {
    private typealias Support = BatchExecutionSupport

    /// TreeChecksum of a fixture copy, excluding the app-support subtree
    /// (snapshots + execution transcripts live there by design).
    static func sandboxChecksum(root: String) throws -> [String: String] {
        let manifest = try TreeChecksum.manifest(root: root)
        return manifest.filter { path, _ in
            path == "." || (!path.hasPrefix("Library") && !path.contains("/Library/"))
        }
    }

    /// Runs `sukiru-cli rollback --batch <id>` against a fixture copy.
    static func runRollback(
        home: String, roots: [String], batchID: String
    ) throws -> CLIRunner.Result {
        let environment = CLIRunner.fixtureEnvironment(home: home, roots: roots)
        return try CLIRunner.run(["rollback", "--batch", batchID], environment: environment)
    }

    /// The items array of a rollback record JSON object.
    static func items(of record: [String: Any]) throws -> [[String: Any]] {
        try #require(record["items"] as? [[String: Any]])
    }

    /// The entries array of a diff JSON object.
    static func entries(of diff: [String: Any]) throws -> [[String: Any]] {
        try #require(diff["entries"] as? [[String: Any]])
    }

    /// Executes the ownerless-cleanup batch on a FIX-FILES-NO-LOCK copy.
    /// Returns the record JSON and the batch id.
    static func executeCleanup(
        home: String, tree: TempTree
    ) throws -> (record: [String: Any], batchID: String) {
        let scan = try Support.scanObject(home: home, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "files-without-lock", skill: "orphan")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "cleanup"]], into: tree)
        let result = try Support.runBatch(
            home: home, roots: [], decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let record = try #require(try result.jsonObject())
        let batchID = try #require(record["batchID"] as? String)
        return (record, batchID)
    }

    // MARK: - VAL-REPAIR-032/034: diff content + byte-identical rollback

    @Test("Round-trip: cleanup diff lists the removal, rollback restores byte-exactly")
    func cleanupRoundTrip() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let preScan = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: copy, roots: []))
        #expect(preScan.exitCode == 0)
        let checksumBefore = try Self.sandboxChecksum(root: copy)

        let executed = try Self.executeCleanup(home: copy, tree: tree)
        #expect(executed.record["batchStatus"] as? String == "succeeded")
        let orphan = copy + "/.agents/skills/orphan"
        #expect(!FileManager.default.fileExists(atPath: orphan))
        // The diff is attached to the batch record and names the removal.
        let diff = try #require(executed.record["diff"] as? [String: Any])
        let entries = try Self.entries(of: diff)
        let removed = entries.filter {
            ($0["kind"] as? String) == "placement-removed"
        }
        #expect(removed.map { $0["path"] as? String } == [orphan])
        #expect((diff["summary"] as? [String])?.isEmpty == false)

        let rollback = try Self.runRollback(home: copy, roots: [], batchID: executed.batchID)
        #expect(rollback.exitCode == 0, "stderr: \(Support.stderrText(rollback))")
        let record = try #require(try rollback.jsonObject())
        #expect(record["batchStatus"] as? String == "rolledBack")
        let items = try Self.items(of: record)
        // swift-format requires the trailing comma swiftlint forbids in
        // multi-line collection literals — suppressed for this set only.
        // swiftlint:disable trailing_comma
        let vocabulary: Set<String> = [
            "restored-from-snapshot", "deleted-batch-added", "unrestorable-with-reason",
        ]
        // swiftlint:enable trailing_comma
        #expect(items.allSatisfy { vocabulary.contains($0["category"] as? String ?? "") })
        let orphanItem = try #require(items.first { ($0["path"] as? String) == orphan })
        #expect(orphanItem["category"] as? String == "restored-from-snapshot")

        // Post-rollback: the sandbox checksum AND the scan report match the
        // pre-batch state exactly (VAL-REPAIR-034).
        #expect(try Self.sandboxChecksum(root: copy) == checksumBefore)
        let postScan = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: copy, roots: []))
        #expect(postScan.exitCode == 0)
        #expect(postScan.stdout == preScan.stdout)
        // The persisted transcript shows the terminal rolledBack state.
        let executions = copy + "/Library/Application Support/Sukiru/executions/"
        let recordPath = executions + executed.batchID + "/record.json"
        let persistedData = try Data(contentsOf: URL(fileURLWithPath: recordPath))
        let persistedObject = try JSONSerialization.jsonObject(with: persistedData)
        let persisted = persistedObject as? [String: Any]
        #expect(persisted?["batchStatus"] as? String == "rolledBack")
    }

    // MARK: - VAL-REPAIR-033: an empty diff is present and explicit

    @Test("A batch whose commands change nothing yields an explicit empty diff")
    func emptyDiffIsPresent() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("CM-1", into: tree)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let bin = try tree.dir("bin")
        // A well-behaved no-op CLI: exit 0, changes nothing (the upstream
        // "All skills are up to date" shape).
        try tree.executable("bin/npx", contents: "#!/bin/sh\nexit 0\n")
        let scan = try Support.scanObject(home: inputs.home, roots: inputs.roots)
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "update"]], into: tree)
        let result = try Support.runBatch(
            home: inputs.home, roots: inputs.roots, decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"], path: bin + ":/usr/bin:/bin")
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "succeeded")
        let diff = try #require(record["diff"] as? [String: Any], "the diff is never omitted")
        #expect(try Self.entries(of: diff).isEmpty)
        let summary = try #require(diff["summary"] as? [String])
        #expect(summary.count == 1)
        #expect(summary[0].localizedCaseInsensitiveContains("no change"))
    }

    // MARK: - VAL-REPAIR-035: rollback of a failed batch

    @Test("A batch failed mid-way rolls back command 1's effects")
    func failedBatchRollsBack() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-DOUBLE-BOOKED", into: tree)
        let preScan = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: copy, roots: []))
        #expect(preScan.exitCode == 0)
        let checksumBefore = try Self.sandboxChecksum(root: copy)
        let bin = try Self.installSabotagedShims(into: tree)
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "double-booked", skill: "double-tool")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "arbitrate", "choice": "keep-github"]], into: tree)
        let executed = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"], path: bin + ":/usr/bin:/bin")
        #expect(executed.exitCode == 1)
        let record = try #require(try executed.jsonObject())
        #expect(record["batchStatus"] as? String == "failed")
        let commands = try Support.commands(of: record)
        #expect(commands[0]["status"] as? String == "succeeded")
        #expect(commands[1]["status"] as? String == "failed")
        let skillDir = copy + "/.agents/skills/double-tool"
        #expect(!FileManager.default.fileExists(atPath: skillDir))
        let batchID = try #require(record["batchID"] as? String)

        let rollback = try Self.runRollback(home: copy, roots: [], batchID: batchID)
        #expect(rollback.exitCode == 0, "stderr: \(Support.stderrText(rollback))")
        let rollbackRecord = try #require(try rollback.jsonObject())
        #expect(rollbackRecord["batchStatus"] as? String == "rolledBack")
        let items = try Self.items(of: rollbackRecord)
        #expect(!items.contains { ($0["category"] as? String) == "unrestorable-with-reason" })
        let restoredSkill = items.contains { item in
            (item["path"] as? String) == skillDir
                && (item["category"] as? String) == "restored-from-snapshot"
        }
        #expect(restoredSkill)
        // The lock is restored byte-exactly and the sandbox checksum matches.
        #expect(try Self.sandboxChecksum(root: copy) == checksumBefore)
        let postScan = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: copy, roots: []))
        #expect(postScan.stdout == preScan.stdout)
    }

    /// Shims for the failed-batch test: command 1 (npx remove) APPLIES its
    /// effects — deletes the skill and rewrites the lock — while command 2
    /// (gh install) is sabotaged to exit 3. Returns the bin directory.
    static func installSabotagedShims(into tree: TempTree) throws -> String {
        let bin = try tree.dir("bin")
        let npxShim = """
            #!/bin/sh
            rm -rf "$HOME/.agents/skills/double-tool"
            printf '{\\n  "version": 3,\\n  "skills": {}\\n}\\n' > "$HOME/.agents/.skill-lock.json"
            exit 0
            """
        let ghShim = """
            #!/bin/sh
            echo "sabotaged install" >&2
            exit 3
            """
        try tree.executable("bin/npx", contents: npxShim)
        try tree.executable("bin/gh", contents: ghShim)
        return bin
    }

    // MARK: - VAL-REPAIR-036: honest unrestorable reporting through the CLI

    @Test("A sabotaged snapshot payload surfaces as unrestorable-with-reason")
    func unrestorableFixture() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let executed = try Self.executeCleanup(home: copy, tree: tree)
        // Make the snapshot's stored payload unreadable between snapshot and
        // rollback (the contract's constructible unrestorable fixture).
        let snapshotID = try #require(executed.record["snapshotID"] as? String)
        let manifestPath =
            copy + "/Library/Application Support/Sukiru/snapshots/"
            + snapshotID + "/manifest.json"
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let payloads = try #require(manifest["payloads"] as? [[String: Any]])
        let storedDir = try #require(payloads.first?["storedDir"] as? String)
        let storedFile =
            copy + "/Library/Application Support/Sukiru/snapshots/"
            + snapshotID + "/" + storedDir + "/SKILL.md"
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: storedFile)

        let rollback = try Self.runRollback(home: copy, roots: [], batchID: executed.batchID)
        #expect(rollback.exitCode == 0, "stderr: \(Support.stderrText(rollback))")
        let record = try #require(try rollback.jsonObject())
        let items = try Self.items(of: record)
        let orphan = copy + "/.agents/skills/orphan"
        let item = try #require(items.first { ($0["path"] as? String) == orphan })
        #expect(item["category"] as? String == "unrestorable-with-reason")
        #expect((item["reason"] as? String)?.isEmpty == false)
        // Nothing claims the orphan was restored, and stderr surfaces it.
        let orphanClaimedRestored = items.contains { element in
            (element["path"] as? String) == orphan
                && (element["category"] as? String) == "restored-from-snapshot"
        }
        #expect(!orphanClaimedRestored)
        #expect(Support.stderrText(rollback).contains("unrestorable"))
    }

    // MARK: - rollback refusals

    @Test("Unknown and already-rolled-back batches are refused with exit 1")
    func rollbackRefusals() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let unknown = try Self.runRollback(home: copy, roots: [], batchID: "no-such-batch")
        #expect(unknown.exitCode == 1)
        #expect(Support.stderrText(unknown).contains("no-such-batch"))
        #expect(unknown.stdout.isEmpty)

        let executed = try Self.executeCleanup(home: copy, tree: tree)
        let first = try Self.runRollback(home: copy, roots: [], batchID: executed.batchID)
        #expect(first.exitCode == 0, "stderr: \(Support.stderrText(first))")
        let second = try Self.runRollback(home: copy, roots: [], batchID: executed.batchID)
        #expect(second.exitCode == 1)
        #expect(Support.stderrText(second).contains("already"))
        #expect(second.stdout.isEmpty)
    }
}
