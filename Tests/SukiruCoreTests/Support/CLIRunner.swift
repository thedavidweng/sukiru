import Foundation

/// Locates and runs the built `sukiru-cli` executable for end-to-end CLI
/// contract tests.
///
/// `swift test` builds every target of the package, so the executable sits
/// next to the test bundle in `<repo>/.build/debug/`. `SUKIRU_CLI_BINARY`
/// overrides the location when the build directory is non-standard.
enum CLIRunner {
    struct Result {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data

        /// stdout parsed as a JSON object (nil when empty or not an object).
        func jsonObject() throws -> [String: Any]? {
            guard !stdout.isEmpty else { return nil }
            return try JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        }
    }

    /// Absolute path of the built executable, or nil when it has not been
    /// built (tests then fail with a clear "build first" error).
    static var binaryPath: String? {
        let fileManager = FileManager.default
        let override = ProcessInfo.processInfo.environment["SUKIRU_CLI_BINARY"]
        if let override, fileManager.isExecutableFile(atPath: override) {
            return override
        }
        let repoRoot = FixturePaths.root.deletingLastPathComponent()
        var candidates = [repoRoot.appendingPathComponent(".build/debug/sukiru-cli").path]
        candidates.append(
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("sukiru-cli").path
        )
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// A fully explicit child environment: base PATH, SUKIRU_HOME, and
    /// SUKIRU_ROOTS when there are project roots. Nothing else is inherited.
    static func fixtureEnvironment(
        home: String,
        roots: [String] = [],
        path: String = "/usr/bin:/bin",
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = ["PATH": path, "SUKIRU_HOME": home]
        if !roots.isEmpty {
            env["SUKIRU_ROOTS"] = roots.joined(separator: ":")
        }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Runs `scan --format json` against a named fixture with extra CLI
    /// arguments and environment entries.
    static func scanFixture(
        _ fixture: String,
        arguments: [String] = [],
        extraEnv: [String: String] = [:]
    ) throws -> Result {
        let inputs = FixturePaths.homeAndRoots(fixture)
        return try run(
            ["scan", "--format", "json"] + arguments,
            environment: fixtureEnvironment(home: inputs.home, roots: inputs.roots, extra: extraEnv)
        )
    }

    /// Runs the CLI with an EXPLICIT environment (nothing inherited from the
    /// test process), stdout/stderr redirected to files per the house CLI
    /// rule. Returns after process exit or `timeout` (then terminates).
    static func run(
        _ arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 60
    ) throws -> Result {
        guard let binary = binaryPath else {
            throw NSError(
                domain: "CLIRunner",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "sukiru-cli binary not found; run `swift build` first "
                        + "(or set SUKIRU_CLI_BINARY)"
                ]
            )
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
        }
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return Result(
            exitCode: process.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL)
        )
    }
}
