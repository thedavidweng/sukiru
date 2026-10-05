import Foundation
import Testing

@testable import SukiruCore

/// The live-output seam: callers learn each command and its output files
/// before the command runs.
@Suite("CLI executor progress", .serialized)
struct CLIExecutorProgressTests {
    private typealias Support = ExecutorTestSupport

    @Test("Each command is announced before it runs, with its output files")
    func commandStartAnnounced() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        try tree.executable("bin/npx", contents: Support.echoShim)
        let commands = ["demo-a", "demo-b"].map {
            Support.command(["npx", "skills", "update", $0, "-g", "-y"], cli: .vercel)
        }
        let starts = StartLog()
        let result = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: commands),
                report: Support.userReport(home: tree.path),
                onCommandStart: { starts.append($0) })
        #expect(starts.values.map(\.index) == [0, 1])
        #expect(starts.values.map(\.displayString) == commands.map(\.displayString))
        #expect(starts.values.map(\.stdoutFile) == result.record.commands.map(\.stdoutFile))
        #expect(starts.values.map(\.stderrFile) == result.record.commands.map(\.stderrFile))
    }

    @Test("A command that never runs is not announced")
    func haltedCommandNotAnnounced() throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        try tree.executable(
            "bin/npx", contents: Support.failOnShim(treePath: tree.path, failName: "demo-a"))
        let commands = ["demo-a", "demo-b"].map {
            Support.command(["npx", "skills", "update", $0, "-g", "-y"], cli: .vercel)
        }
        let starts = StartLog()
        _ = try Support.makeExecutor(home: tree.path, shimPath: bin)
            .execute(
                batch: Support.batch(commands: commands),
                report: Support.userReport(home: tree.path),
                onCommandStart: { starts.append($0) })
        #expect(starts.values.map(\.index) == [0])
    }
}

/// Collects `onCommandStart` events from the executing thread.
private final class StartLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [CommandStart] = []

    func append(_ start: CommandStart) {
        lock.withLock { collected.append(start) }
    }

    var values: [CommandStart] { lock.withLock { collected } }
}
