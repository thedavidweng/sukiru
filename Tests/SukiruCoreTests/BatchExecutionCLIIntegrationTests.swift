import Foundation
import Testing

@testable import SukiruCore

/// Helpers for the `sukiru-cli batch --execute` contract suites: fixture
/// copies (checked-in trees are NEVER mutated), shim installation, and the
/// decisions-file plumbing.
enum BatchExecutionSupport {
    /// Copies a fixture tree into a fresh TempTree, skipping heavy generator
    /// pollution caches (`.local`, `.npm`, `Library`) that carry no scan
    /// semantics. Returns the copy root path.
    static func copyFixture(_ name: String, into tree: TempTree) throws -> String {
        let source = FixturePaths.tree(name)
        let destination = tree.path + "/" + name
        let skip: Set<String> = [".local", ".npm", "Library"]
        let entries = try FileManager.default.contentsOfDirectory(atPath: source)
        try FileManager.default.createDirectory(
            atPath: destination, withIntermediateDirectories: true)
        for entry in entries where !skip.contains(entry) {
            try FileManager.default.copyItem(
                atPath: source + "/" + entry, toPath: destination + "/" + entry)
        }
        return destination
    }

    /// Scans a copy and returns the parsed report object.
    static func scanObject(home: String, roots: [String]) throws -> [String: Any] {
        let environment = CLIRunner.fixtureEnvironment(home: home, roots: roots)
        let result = try CLIRunner.run(["scan", "--format", "json"], environment: environment)
        #expect(result.exitCode == 0, "stderr: \(stderrText(result))")
        return try #require(try result.jsonObject())
    }

    /// Writes a decisions file OUTSIDE the fixture copy (it is an input,
    /// never an output of the CLI).
    static func writeDecisions(_ decisions: [String: Any], into tree: TempTree) throws -> String {
        let path = tree.path + "/decisions.json"
        let data = try JSONSerialization.data(withJSONObject: decisions, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Runs `sukiru-cli batch --decisions …` against a fixture copy.
    static func runBatch(
        home: String,
        roots: [String],
        decisionsPath: String,
        arguments: [String],
        path: String = "/usr/bin:/bin",
        extraEnv: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> CLIRunner.Result {
        let environment = CLIRunner.fixtureEnvironment(
            home: home, roots: roots, path: path, extra: extraEnv)
        return try CLIRunner.run(
            ["batch", "--decisions", decisionsPath] + arguments,
            environment: environment, timeout: timeout)
    }

    static func stderrText(_ result: CLIRunner.Result) -> String {
        String(bytes: result.stderr, encoding: .utf8) ?? ""
    }

    /// The per-command records of an execution-record JSON object.
    static func commands(of record: [String: Any]) throws -> [[String: Any]] {
        try #require(record["commands"] as? [[String: Any]])
    }
}

/// `sukiru-cli batch --execute` end-to-end: review gating, snapshot-first,
/// serialized shim execution, failure states, timeout, lock contention,
/// GH_TOKEN scoping, and dry-run/executed argv equality (VAL-REPAIR-007,
/// 023, 027…031, 038…041, 053, 054, 058).
/// Seam-B execution suite: serialized per house rule (spawns the CLI, which
/// spawns shim CLIs).
@Suite("sukiru-cli batch execution", .serialized)
struct BatchExecutionCLIIntegrationTests {
    private typealias Support = BatchExecutionSupport

    // MARK: - VAL-REPAIR-007: no execution without explicit review

    @Test("--execute without --reviewed refuses: exit 1, no snapshot, byte-identical sandbox")
    func executeRequiresReview() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "files-without-lock", skill: "orphan")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "cleanup"]], into: tree)
        let before = try TreeChecksum.manifest(root: copy)
        let result = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions, arguments: ["--execute"])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("review"))
        #expect(result.stdout.isEmpty)
        let appSupport = copy + "/Library/Application Support/Sukiru"
        #expect(!FileManager.default.fileExists(atPath: appSupport))
        let after = try TreeChecksum.manifest(root: copy)
        #expect(before == after, "a refused execution must write nothing")
    }

    // MARK: - VAL-REPAIR-023/029/038/058: ownerless fileop end-to-end

    @Test("Cleanup batch: executes, snapshots first, argv matches dry-run, canary untouched")
    func cleanupExecutionEndToEnd() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let canary = copy + "/canary-outside-workspaces.txt"
        try "do-not-touch".write(toFile: canary, atomically: true, encoding: .utf8)
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "files-without-lock", skill: "orphan")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "cleanup"]], into: tree)

        let dryRun = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions, arguments: ["--dry-run"])
        #expect(dryRun.exitCode == 0, "stderr: \(Support.stderrText(dryRun))")
        let dryBatch = try #require(try dryRun.jsonObject())
        let dryArgv = try #require(
            (dryBatch["commands"] as? [[String: Any]])?.first?["argv"] as? [String])

        let result = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "succeeded")
        let snapshotID = try #require(record["snapshotID"] as? String)
        let manifest =
            copy + "/Library/Application Support/Sukiru/snapshots/"
            + snapshotID + "/manifest.json"
        #expect(FileManager.default.fileExists(atPath: manifest))
        let commands = try Support.commands(of: record)
        let first = try #require(commands.only)
        #expect(first["status"] as? String == "succeeded")
        #expect(first["exitCode"] as? Int == 0)
        #expect(first["argv"] as? [String] == dryArgv, "VAL-REPAIR-058: argv equality")
        #expect(first["stdoutFile"] is String)
        #expect(first["stderrFile"] is String)
        #expect(first["durationSeconds"] is Double)
        #expect(!FileManager.default.fileExists(atPath: copy + "/.agents/skills/orphan"))
        let canaryBytes = try String(contentsOfFile: canary, encoding: .utf8)
        #expect(canaryBytes == "do-not-touch")
    }

    // MARK: - VAL-REPAIR-029/031/053: shimmed npx through the real CLI

    @Test("CM-1 update batch: shimmed npx runs once, in the project cwd, with contracted env")
    func shimmedUpdateExecution() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("CM-1", into: tree)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let bin = try tree.dir("bin")
        let transcript = tree.path + "/transcript.log"
        let dump = tree.path + "/env.dump"
        let shim = """
            #!/bin/sh
            echo "npx $@" >> "\(transcript)"
            \(ExecutorTestSupport.envDumpShim(dumpPath: dump).dropFirst(10))
            """
        try tree.executable("bin/npx", contents: shim)
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
        let lines = try String(contentsOfFile: transcript, encoding: .utf8)
        #expect(lines == "npx skills update stale-docs-cleanup -p -y\n")
        let env = try ExecutorTestSupport.parseDump(dump)
        #expect(env["HOME"] == inputs.home)
        let root = try #require(inputs.roots.only)
        let resolvedRoot = DefaultFileSystemProbe().resolvedPath(atPath: root)
        #expect(env["PWD"] == resolvedRoot, "project-scope npx runs in the project root")
        #expect(env["CI"] == "1")
        #expect(env["SKILLS_TELEMETRY"] == "0")
        #expect(env["GH_TOKEN"] == "absent")
        #expect(env["STDIN_TTY"] == "no")
        let commands = try Support.commands(of: record)
        let first = try #require(commands.only)
        let stdoutFile = try #require(first["stdoutFile"] as? String)
        let stdout = try String(contentsOfFile: stdoutFile, encoding: .utf8)
        #expect(stdout.contains("env-dump-ok"), "captured stdout file is non-empty")
    }

    // MARK: - VAL-REPAIR-028/041: first command fails, second never runs

    @Test("keep-github batch: npx remove exits 3 → batch failed, gh install never runs")
    func failingFirstCommandStopsBatch() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-DOUBLE-BOOKED", into: tree)
        let lockPath = copy + "/.agents/.skill-lock.json"
        let beforeLock = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        let bin = try tree.dir("bin")
        let marker = tree.path + "/gh-ran"
        let npx = """
            #!/bin/sh
            echo "remove-failed-marker" >&2
            exit 3
            """
        let ghShim = """
            #!/bin/sh
            touch "\(marker)"
            """
        try tree.executable("bin/npx", contents: npx)
        try tree.executable("bin/gh", contents: ghShim)
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "double-booked", skill: "double-tool")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "arbitrate", "choice": "keep-github"]], into: tree)
        let result = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"], path: bin + ":/usr/bin:/bin")
        #expect(result.exitCode == 1)
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "failed")
        let commands = try Support.commands(of: record)
        #expect(commands.count == 2)
        #expect(commands[0]["status"] as? String == "failed")
        #expect(commands[0]["exitCode"] as? Int == 3)
        #expect(commands[0]["failureKind"] as? String == "non-zero-exit")
        #expect(commands[1]["status"] as? String == "not-run")
        #expect(!FileManager.default.fileExists(atPath: marker))
        let stderrFile = try #require(commands[0]["stderrFile"] as? String)
        let stderr = try String(contentsOfFile: stderrFile, encoding: .utf8)
        #expect(stderr.contains("remove-failed-marker"))
        let snapshotID = try #require(record["snapshotID"] as? String)
        let snapshots = copy + "/Library/Application Support/Sukiru/snapshots"
        #expect(FileManager.default.fileExists(atPath: snapshots + "/" + snapshotID))
        let afterLock = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        #expect(beforeLock == afterLock)
    }

    // MARK: - VAL-REPAIR-040: timeout through the CLI flag

    @Test("--command-timeout stops a sleeping shim and reports timed-out")
    func timeoutViaCLI() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("CM-1", into: tree)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let bin = try tree.dir("bin")
        try tree.executable(
            "bin/npx", contents: ExecutorTestSupport.sleepShim(pidPath: tree.path + "/pid"))
        let scan = try Support.scanObject(home: inputs.home, roots: inputs.roots)
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "update"]], into: tree)
        let result = try Support.runBatch(
            home: copy, roots: inputs.roots, decisionsPath: decisions,
            arguments: ["--execute", "--reviewed", "--command-timeout", "1"],
            path: bin + ":/usr/bin:/bin")
        #expect(result.exitCode == 1)
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "failed")
        let commands = try Support.commands(of: record)
        let first = try #require(commands.only)
        #expect(first["status"] as? String == "timed-out")
        #expect(first["failureKind"] as? String == "timeout")
        let duration = try #require(first["durationSeconds"] as? Double)
        #expect(duration < 30, "duration \(duration)s should be near the 1s timeout")
    }

    // MARK: - VAL-REPAIR-027: a second batch is refused while one holds the lock

    @Test("A held execution lock refuses another batch with a clear message")
    func concurrentBatchRefused() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let lockDir = copy + "/Library/Application Support/Sukiru/execution.lock"
        try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: lockDir + "/pid", atomically: true, encoding: .utf8)
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "files-without-lock", skill: "orphan")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "cleanup"]], into: tree)
        let result = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("another batch execution"))
        #expect(result.stdout.isEmpty)
        let orphan = copy + "/.agents/skills/orphan"
        #expect(FileManager.default.fileExists(atPath: orphan))
    }

    // MARK: - VAL-REPAIR-054: GH_TOKEN scoped to gh network commands at CLI level

    @Test("GH_TOKEN reaches only the gh command; nothing persists the token value")
    func ghTokenScopingAtCLILevel() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-DOUBLE-BOOKED", into: tree)
        let bin = try tree.dir("bin")
        let npxDump = tree.path + "/npx.dump"
        let ghDump = tree.path + "/gh.dump"
        try tree.executable(
            "bin/npx", contents: ExecutorTestSupport.envDumpShim(dumpPath: npxDump))
        try tree.executable(
            "bin/gh", contents: ExecutorTestSupport.envDumpShim(dumpPath: ghDump))
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "double-booked", skill: "double-tool")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "arbitrate", "choice": "keep-github"]], into: tree)
        let token = "changeme"
        let result = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions,
            arguments: ["--execute", "--reviewed"], path: bin + ":/usr/bin:/bin",
            extraEnv: ["GH_TOKEN": token])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let npxEnv = try ExecutorTestSupport.parseDump(npxDump)
        let ghEnv = try ExecutorTestSupport.parseDump(ghDump)
        #expect(npxEnv["GH_TOKEN"] == "absent")
        #expect(ghEnv["GH_TOKEN"] == "present")
        #expect(ghEnv["HOME"] == copy)
        #expect(!ExecutorTestSupport.treeContains(copy, needle: token))
        #expect(!ExecutorTestSupport.treeContains(tree.path, needle: token))
    }

    // MARK: - usage errors

    @Test("--reviewed without --execute and --dry-run with --execute are usage errors")
    func invalidFlagCombinations() throws {
        let tree = try TempTree()
        let copy = try Support.copyFixture("FIX-FILES-NO-LOCK", into: tree)
        let scan = try Support.scanObject(home: copy, roots: [])
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "files-without-lock", skill: "orphan")
        let decisions = try Support.writeDecisions(
            [findingID: ["action": "cleanup"]], into: tree)
        let reviewedOnly = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions, arguments: ["--reviewed"])
        #expect(reviewedOnly.exitCode == 1)
        #expect(Support.stderrText(reviewedOnly).contains("--execute"))
        let both = try Support.runBatch(
            home: copy, roots: [], decisionsPath: decisions,
            arguments: ["--dry-run", "--execute"])
        #expect(both.exitCode == 1)
        #expect(Support.stderrText(both).contains("mutually exclusive"))
    }
}
