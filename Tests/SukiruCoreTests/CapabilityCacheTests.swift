import Foundation
import Testing

@testable import SukiruCore

/// Capability result caching (detection never blocks anything; results are
/// cached). The app queries capabilities repeatedly
/// (Settings panel, inline hints); the cache guarantees those queries never
/// re-probe subprocesses until explicitly refreshed.
@Suite("Capability caching")
struct CapabilityCacheTests {
    /// Counts every invocation and answers with one fixed, healthy
    /// environment: gh 2.100.0 with a working skill surface, skills 1.5.26.
    private final class CountingRunner: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var invocations: [String] = []

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            let key = ([executable] + arguments).joined(separator: " ")
            lock.lock()
            invocations.append(key)
            lock.unlock()
            switch (executable, arguments.first) {
            case ("gh", "--version"):
                return ProcessOutcome(exitCode: 0, stdout: "gh version 2.100.0\n", stderr: "")
            case ("gh", "skill"):
                return ProcessOutcome(exitCode: 0, stdout: "Work with agent skills\n", stderr: "")
            case ("npx", "--offline"):
                return ProcessOutcome(exitCode: 0, stdout: "1.5.26\n", stderr: "")
            default:
                return nil
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return invocations.count
        }
    }

    /// One healthy detection probes three commands: `gh --version`,
    /// `gh skill --help`, `npx --offline skills --version`.
    private let probesPerDetection = 3

    @Test("Repeated current() runs detection exactly once")
    func currentCaches() {
        let runner = CountingRunner()
        let cache = CapabilityCache(detector: CapabilityDetector(runner: runner))

        let first = cache.current()
        let second = cache.current()
        let third = cache.current()

        #expect(runner.count == probesPerDetection)
        #expect(first == second && second == third)
        #expect(first.github.available)
        #expect(first.npx.resolvable)
        #expect(first.npx.skillsVersion == "1.5.26")
    }

    @Test("refresh() re-probes and replaces the cached report")
    func refreshReprobes() {
        let runner = CountingRunner()
        let cache = CapabilityCache(detector: CapabilityDetector(runner: runner))

        _ = cache.current()
        #expect(runner.count == probesPerDetection)

        let refreshed = cache.refresh()
        #expect(runner.count == 2 * probesPerDetection)
        #expect(refreshed == cache.current())
        #expect(runner.count == 2 * probesPerDetection)
    }

    @Test("invalidate() forces the next current() to re-probe")
    func invalidateForcesReprobe() {
        let runner = CountingRunner()
        let cache = CapabilityCache(detector: CapabilityDetector(runner: runner))

        _ = cache.current()
        cache.invalidate()
        _ = cache.current()

        #expect(runner.count == 2 * probesPerDetection)
    }
}
