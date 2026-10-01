import Foundation
import Testing

@testable import SukiruCore

/// The CLIExecutor safety invariants, exercised against POSIX shims on an
/// injected PATH. Shims never touch the network or a real CLI, so
/// no `SUKIRU_E2E` gate is needed; every test uses its own TempTree and an
/// explicit `pathOverride`, keeping the suite parallel-safe.
/// Serialized because the suite is subprocess-heavy.
@Suite("CLI executor", .serialized)
struct CLIExecutorTests {
    private typealias Support = ExecutorTestSupport

    // MARK: - Execution requires prior review

    @Test("A proposed batch is refused: no snapshot, no subprocess, no writes")
    func unreviewedBatchRefused() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let log = tree.path + "/shim.log"
        try tree.executable("bin/npx", contents: "#!/bin/sh\necho npx >> \"\(log)\"\n")
        let before = try TreeChecksum.manifest(root: tree.path)
        let command = Support.command(
            ["npx", "skills", "update", "demo", "-g", "-y"], cli: .vercel)
        let batch = Support.batch(commands: [command], status: .proposed)
        let executor = Support.makeExecutor(home: tree.path, shimPath: bin)
        do {
            _ = try executor.execute(batch: batch, report: Support.userReport(home: tree.path))
            Issue.record("expected ExecutionError.notReviewed")
        } catch let error as ExecutionError {
            #expect(error == .notReviewed(current: .proposed))
            #expect(error.message.contains("review"))
        }
        #expect(!FileManager.default.fileExists(atPath: tree.path + "/Library"))
        #expect(!FileManager.default.fileExists(atPath: log))
        let after = try TreeChecksum.manifest(root: tree.path)
        #expect(before == after, "a refused execution must leave the sandbox byte-identical")
    }

    // MARK: - Snapshot before the first command, always

    @Test("Snapshot + ledger checksums are committed even when command 1 fails immediately")
    func snapshotCommittedBeforeFailingFirstCommand() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")  // no gh inside: the first command cannot spawn
        let lockPath = try tree.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["x"]))
        let beforeLock = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        let command = Support.command(
            ["gh", "skill", "update", "demo", "--dir", "/tmp/nowhere"], cli: .github)
        let batch = Support.batch(commands: [command])
        let report = Support.userReport(home: tree.path)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(batch: batch, report: report)
        #expect(result.batch.status == .failed)
        #expect(result.record.batchStatus == .failed)
        let first = try #require(result.record.commands.only)
        #expect(first.status == .failed)
        #expect(first.failureKind == .executableMissing)
        #expect(first.diagnostics?.contains("gh") == true)
        #expect(first.exitCode == nil)
        let snapshotID = try #require(result.batch.snapshotID)
        #expect(result.record.snapshotID == snapshotID)
        let store = SnapshotStore(environment: Support.environment(home: tree.path))
        let manifest = try store.load(id: snapshotID)
        #expect(manifest.ledgers.contains { $0.path == lockPath && $0.existed })
        let afterLock = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        #expect(beforeLock == afterLock, "zero executed commands ⇒ ledgers byte-identical")
    }

    // MARK: - Strict serialization

    @Test("Two commands run one at a time, in batch order, with non-overlapping intervals")
    func commandsExecuteSerialized() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let log = tree.path + "/order.log"
        try tree.executable("bin/npx", contents: Support.orderLogShim(logPath: log))
        let demoA = Support.command(
            ["npx", "skills", "update", "demo-a", "-g", "-y"], cli: .vercel)
        let demoB = Support.command(
            ["npx", "skills", "update", "demo-b", "-g", "-y"], cli: .vercel)
        let batch = Support.batch(commands: [demoA, demoB])
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(batch: batch, report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .succeeded)
        let lines = try String(contentsOfFile: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines == ["start-demo-a", "end-demo-a", "start-demo-b", "end-demo-b"])
        let records = result.record.commands
        let firstEnd = try #require(records[0].endedAt)
        let secondStart = try #require(records[1].startedAt)
        #expect(firstEnd <= secondStart, "ISO-8601 fractional timestamps sort chronologically")
    }

    @Test("A live cross-process execution lock refuses a second batch")
    func concurrentBatchRefusedWhileLockHeld() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let lockDir = try tree.dir("Library/Application Support/Sukiru/execution.lock")
        let pid = ProcessInfo.processInfo.processIdentifier
        try tree.file("Library/Application Support/Sukiru/execution.lock/pid", contents: "\(pid)")
        let command = Support.command(
            ["npx", "skills", "update", "demo", "-g", "-y"], cli: .vercel)
        let executor = Support.makeExecutor(home: tree.path, shimPath: bin)
        do {
            _ = try executor.execute(
                batch: Support.batch(commands: [command]),
                report: Support.userReport(home: tree.path))
            Issue.record("expected ExecutionError.busy")
        } catch let error as ExecutionError {
            guard case .busy(let lockPath) = error else {
                Issue.record("expected .busy, got \(error)")
                return
            }
            #expect(lockPath == lockDir)
        }
        let snapshots = tree.path + "/Library/Application Support/Sukiru/snapshots"
        #expect(!FileManager.default.fileExists(atPath: snapshots))
    }

    @Test("A lock left by a dead process is broken and execution proceeds")
    func staleLockIsBroken() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let log = tree.path + "/order.log"
        try tree.executable("bin/npx", contents: Support.orderLogShim(logPath: log))
        let dead = try Support.deadPID()
        try tree.dir("Library/Application Support/Sukiru/execution.lock")
        try tree.file(
            "Library/Application Support/Sukiru/execution.lock/pid", contents: "\(dead)")
        let command = Support.command(
            ["npx", "skills", "update", "demo", "-g", "-y"], cli: .vercel)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: [command]),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .succeeded)
    }

    // MARK: - Per-command record fields

    @Test("A successful command records exit code, duration, and complete captured files")
    func successPreservesOutputsAndTiming() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        try tree.executable("bin/npx", contents: Support.echoShim)
        let command = Support.command(
            ["npx", "skills", "update", "demo", "-g", "-y"], cli: .vercel)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: [command]),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .succeeded)
        #expect(result.batch.snapshotID != nil)
        let record = try #require(result.record.commands.only)
        #expect(record.status == .succeeded)
        #expect(record.exitCode == 0)
        #expect(record.durationSeconds != nil)
        #expect(record.startedAt != nil && record.endedAt != nil)
        #expect(record.argv == command.argv, "recorded argv byte-equals the batch argv")
        let stdoutFile = try #require(record.stdoutFile)
        let stderrFile = try #require(record.stderrFile)
        #expect(stdoutFile.hasPrefix(result.record.recordDirectory))
        let stdout = try String(contentsOfFile: stdoutFile, encoding: .utf8)
        let stderr = try String(contentsOfFile: stderrFile, encoding: .utf8)
        #expect(stdout == "std-out-marker-demo\n")
        #expect(stderr == "std-err-marker-demo\n")
        let recordJSON = result.record.recordDirectory + "/record.json"
        #expect(FileManager.default.fileExists(atPath: recordJSON))
    }

    // MARK: - The 65 536-byte pipe-truncation trap

    @Test("Output beyond 65 536 bytes is captured completely (files, never pipes)")
    func outputBeyondPipeLimitIsCapturedCompletely() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        try tree.executable("bin/npx", contents: Support.bigOutputShim)
        let command = Support.command(["npx", "skills", "list", "-g", "-y"], cli: .vercel)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: [command]),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .succeeded)
        let record = try #require(result.record.commands.only)
        let stdoutFile = try #require(record.stdoutFile)
        let data = try Data(contentsOf: URL(fileURLWithPath: stdoutFile))
        #expect(data.count > 65_536, "captured stdout must exceed the pipe-truncation cliff")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasPrefix("sukiru-big-output-line-0\n"))
        #expect(text.hasSuffix("SUKIRU-END-MARKER\n"), "the tail must not be cut mid-token")
    }

    // MARK: - Environment contract + GH_TOKEN scoping

    @Test("Subprocess env: CI=1, SKILLS_TELEMETRY=0, HOME=sandbox, no TTY, cwd honored")
    func subprocessEnvironmentContract() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let workdir = try tree.dir("proj")
        let dump = tree.path + "/env.dump"
        try tree.executable("bin/npx", contents: Support.envDumpShim(dumpPath: dump))
        let command = Support.command(
            ["npx", "skills", "update", "demo", "-p", "-y"], cli: .vercel,
            workingDirectory: workdir)
        let executor = Support.makeExecutor(
            home: tree.path, shimPath: bin, token: "secret-token-123")
        let result = try executor.execute(
            batch: Support.batch(commands: [command]),
            report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .succeeded)
        let env = try Support.parseDump(dump)
        #expect(env["HOME"] == tree.path)
        #expect(env["CI"] == "1")
        #expect(env["SKILLS_TELEMETRY"] == "0")
        #expect(env["STDIN_TTY"] == "no")
        #expect(env["STDOUT_TTY"] == "no")
        // pwd -P is physical: temp dirs resolve /var → /private/var.
        let resolvedWorkdir = DefaultFileSystemProbe().resolvedPath(atPath: workdir)
        #expect(env["PWD"] == resolvedWorkdir)
        #expect(env["GH_TOKEN"] == "absent", "vercel commands never receive GH_TOKEN")
    }

    @Test("GH_TOKEN reaches only gh commands and is never persisted to disk")
    func ghTokenScopingAndPersistence() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let npxDump = tree.path + "/npx.dump"
        let ghDump = tree.path + "/gh.dump"
        try tree.executable("bin/npx", contents: Support.envDumpShim(dumpPath: npxDump))
        try tree.executable("bin/gh", contents: Support.envDumpShim(dumpPath: ghDump))
        let remove = Support.command(["npx", "skills", "remove", "demo", "-y"], cli: .vercel)
        let installArgv = ["gh", "skill", "install", "acme/x", "skills/demo", "--dir", tree.path]
        let install = Support.command(installArgv, cli: .github)
        let commands = [remove, install]
        let token = "changeme"
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin, token: token)
            .execute(
                batch: Support.batch(commands: commands),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .succeeded)
        let npxEnv = try Support.parseDump(npxDump)
        let ghEnv = try Support.parseDump(ghDump)
        #expect(npxEnv["GH_TOKEN"] == "absent")
        #expect(ghEnv["GH_TOKEN"] == "present")
        let leaked = Support.treeContains(tree.path, needle: token)
        #expect(!leaked, "the token value must never be persisted anywhere in the sandbox")
    }

    // MARK: - Executed argv byte-equals the reviewed batch

    @Test("Every executed record argv byte-equals the batch's reviewed argv")
    func executedArgvMatchesBatchExactly() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        try tree.executable("bin/npx", contents: Support.echoShim)
        try tree.executable("bin/gh", contents: Support.echoShim)
        let remove = Support.command(["npx", "skills", "remove", "demo", "-g", "-y"], cli: .vercel)
        let installArgv = ["gh", "skill", "install", "acme/x", "skills/demo", "--dir", tree.path]
        let install = Support.command(installArgv, cli: .github)
        let commands = [remove, install]
        let batch = Support.batch(commands: commands)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(batch: batch, report: Support.userReport(home: tree.path))
        #expect(result.record.commands.map(\.argv) == commands.map(\.argv))
        #expect(result.record.commands.map(\.displayString) == commands.map(\.displayString))
    }
}
