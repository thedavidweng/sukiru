import Foundation
import Testing

@testable import SukiruCore

/// Real pnpm runs are opt-in; every child receives an explicit sandbox environment.
enum PnpmRealSupport {
    static let enabled = ProcessInfo.processInfo.environment["SUKIRU_PNPM_E2E"] == "1"
    static let version = "12.11.0"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(
        _ executable: String, _ arguments: [String], cwd: String,
        environment: [String: String], timeout: TimeInterval = 90
    ) throws -> CLIRunner.Result {
        let scratch = URL(fileURLWithPath: environment["TMPDIR"] ?? cwd)
            .appendingPathComponent("process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut { process.terminate() }
        process.waitUntilExit()
        guard !timedOut else {
            throw Failure(
                description: "Timed out running \(executable) \(arguments.joined(separator: " "))")
        }
        return CLIRunner.Result(
            exitCode: process.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL), stderr: try Data(contentsOf: stderrURL))
    }

    static func requireSuccess(
        _ result: CLIRunner.Result, command: String
    ) throws {
        guard result.exitCode == 0 else {
            let stdout = try text(result.stdout)
            let stderr = try text(result.stderr)
            throw Failure(
                description: "\(command) exited \(result.exitCode)\n" + stdout + stderr)
        }
    }

    static func text(_ data: Data) throws -> String {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw Failure(description: "Invalid UTF-8 in pnpm test data or process output")
        }
        return text
    }

    static func resolvePnpm(tree: TempTree, environment: [String: String]) throws -> String {
        let requested = ProcessInfo.processInfo.environment["SUKIRU_PNPM_BINARY"]
        var binary = requested
        let lookupPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        var lookupEnvironment = environment
        lookupEnvironment["PATH"] = lookupPath
        func lookup(_ name: String) throws -> String? {
            let result = try run(
                "/usr/bin/which", [name], cwd: tree.path, environment: lookupEnvironment)
            guard result.exitCode == 0 else { return nil }
            return try text(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parentEnvironment = ProcessInfo.processInfo.environment
        let miseData =
            parentEnvironment["MISE_DATA_DIR"]
            ?? ((parentEnvironment["XDG_DATA_HOME"] ?? NSHomeDirectory() + "/.local/share")
                + "/mise")
        let pinned = miseData + "/installs/pnpm/" + version + "/pnpm"
        if binary == nil, FileManager.default.isExecutableFile(atPath: pinned) {
            binary = pinned
        }
        if binary == nil { binary = try lookup("pnpm") }
        guard let binary, binary.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: binary)
        else {
            throw Failure(
                description: "SUKIRU_PNPM_E2E=1 requires pnpm \(version). Install that version "
                    + "in mise or set SUKIRU_PNPM_BINARY to its absolute executable path.")
        }
        let result = try run(binary, ["--version"], cwd: tree.path, environment: environment)
        try requireSuccess(result, command: "pnpm --version")
        let actual = try text(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == version else {
            throw Failure(
                description: "SUKIRU_PNPM_E2E requires exactly pnpm \(version); "
                    + "\(binary) reported \(actual). Set SUKIRU_PNPM_BINARY to the pinned executable."
            )
        }
        return binary
    }
}
