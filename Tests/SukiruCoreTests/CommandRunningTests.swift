import Foundation
import Testing

@testable import SukiruCore

/// `SystemCommandRunner` against the REAL filesystem (the one seam allowed
/// to spawn subprocesses, architecture D2). Capability detection itself is
/// tested with stubs in `CapabilityDetectorTests`; these tests exercise the
/// runner mechanics.
@Suite("System command runner")
struct CommandRunningTests {
    private func runner(timeout: TimeInterval = 30) -> SystemCommandRunner {
        SystemCommandRunner(
            environment: SukiruEnvironment(reader: DictionaryEnvironmentReader([:])),
            timeout: timeout)
    }

    @Test("A probe emitting more than the ~64KB pipe buffer cannot deadlock")
    func largeOutputDoesNotDeadlock() throws {
        // Pipes must be drained CONCURRENTLY with process execution: a child
        // that fills the pipe buffer blocks on write while a parent waiting
        // for termination first would deadlock until the timeout (silent nil).
        let tree = try TempTree()
        let payload = String(repeating: "sukiru-probe-payload\n", count: 20_000)  // ~420 KB
        let file = try tree.file("big.txt", contents: payload)

        // Short timeout: a drain-after-exit implementation deadlocks into it.
        let outcome = try #require(
            runner(timeout: 10).run("/bin/cat", [file]),
            "nil outcome means the run deadlocked into the timeout")
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == payload)
    }

    @Test("An absent executable is a nil outcome, not a crash")
    func absentExecutable() {
        let outcome = runner().run("sukiru-definitely-not-a-real-tool", ["--version"])
        #expect(outcome == nil)
    }
}
