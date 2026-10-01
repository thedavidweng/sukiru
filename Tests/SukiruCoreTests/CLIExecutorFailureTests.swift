import Foundation
import Testing

@testable import SukiruCore

/// The CLIExecutor terminal-state guarantees: stop-on-first-failure,
/// timeout, missing CLI, and the workspace-root boundary for the
/// ownerless-cleanup fileop exception.
/// Serialized because the suite is subprocess-heavy.
@Suite("CLI executor failure states", .serialized)
struct CLIExecutorFailureTests {
    private typealias Support = ExecutorTestSupport

    // MARK: - Stop-on-first-failure with per-command status

    @Test("First-command failure stops the batch; command 2 never starts")
    func stopOnFirstFailure() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let shim = Support.failOnShim(treePath: tree.path, failName: "bad")
        try tree.executable("bin/npx", contents: shim)
        let bad = Support.command(["npx", "skills", "update", "bad", "-g", "-y"], cli: .vercel)
        let good = Support.command(["npx", "skills", "update", "good", "-g", "-y"], cli: .vercel)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: [bad, good]),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .failed)
        #expect(result.batch.status == .failed)
        let records = result.record.commands
        #expect(records.count == 2)
        #expect(records[0].status == .failed)
        #expect(records[0].exitCode == 3)
        #expect(records[0].failureKind == .nonZeroExit)
        #expect(records[1].status == .notRun)
        #expect(records[1].exitCode == nil)
        #expect(records[1].startedAt == nil)
        #expect(FileManager.default.fileExists(atPath: tree.path + "/ran-bad"))
        #expect(!FileManager.default.fileExists(atPath: tree.path + "/ran-good"))
        let stderrFile = try #require(records[0].stderrFile)
        let stderr = try String(contentsOfFile: stderrFile, encoding: .utf8)
        #expect(stderr.contains("boom-stderr-marker"))
        #expect(records[0].diagnostics?.contains("boom-stderr-marker") == true)
    }

    // MARK: - Timeout

    @Test("A command past the timeout is terminated and stops the batch; no orphan survives")
    func timeoutTerminatesAndStopsBatch() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let pidPath = tree.path + "/sleeper.pid"
        try tree.executable("bin/npx", contents: Support.sleepShim(pidPath: pidPath))
        let slow = Support.command(["npx", "skills", "update", "slow", "-g", "-y"], cli: .vercel)
        let later = Support.command(["npx", "skills", "update", "later", "-g", "-y"], cli: .vercel)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin, timeout: 1)
            .execute(
                batch: Support.batch(commands: [slow, later]),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .failed)
        let records = result.record.commands
        #expect(records[0].status == .timedOut)
        #expect(records[0].failureKind == .timeout)
        let duration = try #require(records[0].durationSeconds)
        #expect(duration < 10, "duration \(duration)s should be near the 1s timeout")
        #expect(records[1].status == .notRun)
        let pidText = try String(contentsOfFile: pidPath, encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "the timed-out process must not survive")
    }

    // MARK: - CLI missing mid-flow

    @Test("A missing npx is a clear failed state naming the tool, with the snapshot intact")
    func missingNpxIsAClearFailedState() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")  // empty PATH prefix: no npx anywhere
        let command = Support.command(
            ["npx", "skills", "update", "demo", "-g", "-y"], cli: .vercel)
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: [command]),
                report: Support.userReport(home: tree.path))
        #expect(result.record.batchStatus == .failed)
        let record = try #require(result.record.commands.only)
        #expect(record.status == .failed)
        #expect(record.failureKind == .executableMissing)
        #expect(record.diagnostics?.contains("npx") == true)
        #expect(result.batch.snapshotID != nil, "snapshot exists so rollback can be offered")
    }

    // MARK: - Workspace-root boundary

    @Test("Ownerless fileop cleanup deletes inside workspace roots; canaries outside survive")
    func fileopCleanupStaysInsideWorkspaceRoots() throws {
        let home = try TempTree()
        let orphan = try home.dir(".agents/skills/orphan")
        try home.file(
            ".agents/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))
        try home.file(".agents/skills/orphan/notes.md", contents: "payload")
        let canary = try home.file("Documents/canary.txt", contents: "do-not-touch")
        let report = try OwnershipBuilders.scan(home: home)
        let ref = SnapshotTestSupport.ref("f-orphan", skill: "orphan", workspace: "user")
        let command = BatchCommand(
            argv: ["sukiru-fileop", "delete-directory", orphan],
            displayString: "delete directory " + orphan,
            owningCLI: .file,
            intent: "Clean up ownerless skill 'orphan'.",
            dangerFlags: [.directFileOperation, .ownerlessCleanup],
            warning: "direct deletion")
        let result = try Support.makeExecutor(home: home.path, shimPath: home.path)
            .execute(batch: Support.batch(commands: [command], refs: [ref]), report: report)
        #expect(result.record.batchStatus == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: orphan))
        let canaryBytes = try Data(contentsOf: URL(fileURLWithPath: canary))
        #expect(String(data: canaryBytes, encoding: .utf8) == "do-not-touch")
        let store = SnapshotStore(environment: Support.environment(home: home.path))
        let manifest = try store.load(id: try #require(result.batch.snapshotID))
        #expect(manifest.payloads.contains { $0.path == orphan })
    }

    @Test("A fileop outside every touched workspace root is refused before anything runs")
    func outOfBoundsFileopIsRefused() throws {
        let home = try TempTree()
        let orphan = try home.dir(".agents/skills/orphan")
        try home.file(
            ".agents/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))
        let outside = try home.dir("Documents/precious")
        try home.file("Documents/precious/data.txt", contents: "keep-me")
        let report = try OwnershipBuilders.scan(home: home)
        let ref = SnapshotTestSupport.ref("f-orphan", skill: "orphan", workspace: "user")
        let command = BatchCommand(
            argv: ["sukiru-fileop", "delete-directory", outside],
            displayString: "delete directory " + outside,
            owningCLI: .file,
            intent: "malicious or buggy command",
            dangerFlags: [.directFileOperation, .ownerlessCleanup],
            warning: "direct deletion")
        let result = try Support.makeExecutor(home: home.path, shimPath: home.path)
            .execute(batch: Support.batch(commands: [command], refs: [ref]), report: report)
        #expect(result.record.batchStatus == .failed)
        let record = try #require(result.record.commands.only)
        #expect(record.status == .failed)
        #expect(record.failureKind == .outOfBounds)
        #expect(record.diagnostics?.contains("outside") == true)
        #expect(FileManager.default.fileExists(atPath: outside + "/data.txt"))
        #expect(FileManager.default.fileExists(atPath: orphan))
    }
}
