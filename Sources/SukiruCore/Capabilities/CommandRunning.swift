import Foundation

/// The result of a finished subprocess invocation.
public struct ProcessOutcome: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an external executable by name (searched on PATH).
///
/// Injectable so capability detection is testable with stub outcomes and so
/// validation can point the CLI at PATH shims. ONLY the capabilities surface
/// uses this seam — `ScanEngine` never spawns subprocesses (architecture D2).
public protocol CommandRunning: Sendable {
    /// Runs `executable` with `arguments`, returning nil when the executable
    /// cannot be located on PATH or spawned. A non-zero exit code is still a
    /// returned outcome (the CLI exists but failed).
    func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome?
}

/// Runs real subprocesses against the live process environment.
///
/// Per the mission CLI rules the child environment carries
/// `CI=1 SKILLS_TELEMETRY=0`, and `HOME` is the Sukiru-resolved home (i.e.
/// `SUKIRU_HOME` when overridden) so probes stay hermetic under validation.
/// Probe outputs are tiny (`--version`, `--help`), far below the 65 536-byte
/// pipe-truncation cliff that forces seam-B CLI output into files.
public struct SystemCommandRunner: CommandRunning {
    private let environment: SukiruEnvironment
    private let timeout: TimeInterval

    public init(environment: SukiruEnvironment, timeout: TimeInterval = 30) {
        self.environment = environment
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
        guard let url = locate(executable) else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["CI"] = "1"
        childEnvironment["SKILLS_TELEMETRY"] = "0"
        if !environment.home.isEmpty {
            childEnvironment["HOME"] = environment.home
        }
        process.environment = childEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(bytes: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(bytes: stderrData, encoding: .utf8) ?? ""
        return ProcessOutcome(
            exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Resolves an executable name against the process PATH (absolute paths
    /// pass through). Returns nil when the file is absent or not executable.
    private func locate(_ executable: String) -> URL? {
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable)
                ? URL(fileURLWithPath: executable) : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/" + executable
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
