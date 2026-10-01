import Foundation

/// How a reaped subprocess terminated.
enum SubprocessTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// The result of one subprocess run.
struct SubprocessOutcome: Equatable, Sendable {
    /// Nil only in the pathological "stopped but never reaped" case.
    let termination: SubprocessTermination?
    let timedOut: Bool
    let duration: TimeInterval
}

/// The child could not be spawned at all (posix_spawn itself failed).
enum SubprocessError: Error, Equatable, Sendable {
    case spawnFailed(code: Int32, executable: String)
}

/// Everything needed to spawn one subprocess (kept as a value so `run`
/// stays small).
struct SubprocessInvocation: Sendable {
    let argv: [String]
    let executablePath: String
    let environment: [String: String]
    let workingDirectory: String?
    let stdoutPath: String
    let stderrPath: String
}

/// posix_spawn-based subprocess runner for Command Batch execution.
///
/// Why not `Foundation.Process`: batch children get their OWN process group
/// (`POSIX_SPAWN_SETPGROUP`) so a timeout can SIGTERM, then SIGKILL, the whole
/// group — `Process` cannot create process groups, and killing only the
/// direct child would orphan grandchildren (no orphan process may survive a
/// timeout). stdin is `/dev/null` (no TTY) and stdout/stderr are
/// FILES from the first byte, never pipes — the `npx skills --json` pipe
/// truncation cliff at 65 536 bytes cannot be hit.
enum Subprocess {
    /// Runs `invocation`, reaping the child within `timeout` seconds; on
    /// timeout the child's process group is SIGTERMed, then SIGKILLed after
    /// a 2 s grace period.
    static func run(
        _ invocation: SubprocessInvocation, timeout: TimeInterval
    ) throws -> SubprocessOutcome {
        let pid = try spawn(invocation)
        let start = Date()
        let reaped = DispatchSemaphore(value: 0)
        let statusBox = WaitStatusBox()
        // A dedicated thread, not a global queue: on a busy machine the
        // width-limited global queue can delay the reap past `timeout`, so a
        // finished child would be reported (and killed) as timed out.
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            statusBox.status = status
            reaped.signal()
        }
        var timedOut = false
        if reaped.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(-pid, SIGTERM)
            if reaped.wait(timeout: .now() + 2) == .timedOut {
                kill(-pid, SIGKILL)
                _ = reaped.wait(timeout: .now() + 5)
            }
        }
        let duration = Date().timeIntervalSince(start)
        return SubprocessOutcome(
            termination: termination(of: statusBox.status),
            timedOut: timedOut,
            duration: duration)
    }

    /// Decodes a waitpid status word into a termination kind.
    private static func termination(of status: Int32) -> SubprocessTermination? {
        let signalBits = status & 0x7f
        if signalBits == 0 {
            return .exited((status >> 8) & 0xff)
        }
        if signalBits != 0x7f {
            return .signaled(signalBits)
        }
        return nil  // stopped, never terminated — not expected here
    }

    /// Spawns the child with stdin `/dev/null`, stdout/stderr redirected to
    /// files, and its own process group.
    private static func spawn(_ invocation: SubprocessInvocation) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, 1, invocation.stdoutPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(
            &actions, 2, invocation.stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if let workingDirectory = invocation.workingDirectory {
            // Deployment target is macOS 14: `_np` (10.15+) is the available
            // spelling; the unprefixed replacement requires macOS 26.
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attributes, flags)

        var cArgv: [UnsafeMutablePointer<CChar>?] = invocation.argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] =
            invocation.environment.map { strdup("\($0)=\($1)") } + [nil]
        defer {
            for pointer in cArgv { free(pointer) }
            for pointer in cEnv { free(pointer) }
        }

        var pid = pid_t()
        let status = posix_spawn(
            &pid, invocation.executablePath, &actions, &attributes, &cArgv, &cEnv)
        guard status == 0 else {
            throw SubprocessError.spawnFailed(
                code: status, executable: invocation.executablePath)
        }
        return pid
    }
}

/// Hands the wait status from the reaper thread back to the caller; written
/// exactly once by the reaper before it signals the semaphore.
private final class WaitStatusBox: @unchecked Sendable {
    var status: Int32 = 0
}
