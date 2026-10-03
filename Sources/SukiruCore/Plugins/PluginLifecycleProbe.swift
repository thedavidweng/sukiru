import Foundation

/// Only explicit lifecycle previews invoke these version/help probes.
public struct PluginLifecycleProbe: Sendable {
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) { self.environment = environment }

    public func version(host: PluginHost) throws -> String {
        let output = try output(host: host, arguments: ["--version"])
        guard
            let version = output.split(whereSeparator: { $0.isWhitespace }).first(where: {
                let value = $0.hasPrefix("v") ? $0.dropFirst() : $0[...]
                return value.split(separator: ".").count == 3 && value.first?.isNumber == true
            })
        else { throw PluginLifecycleError(message: "Unrecognized host version: " + output) }
        return version.hasPrefix("v") ? String(version.dropFirst()) : String(version)
    }

    func help(host: PluginHost, arguments: [String], requiredFlags: [String]) throws {
        let help = try output(host: host, arguments: arguments + ["--help"])
        guard requiredFlags.allSatisfy(help.contains) else {
            throw PluginLifecycleError(
                message: "Installed host help does not expose required operation flags")
        }
    }

    private func output(host: PluginHost, arguments: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        var variables = ProcessInfo.processInfo.environment
        if environment.homeIsOverridden {
            for key in SukiruEnvironment.externalEnvKeys { variables[key] = nil }
            for key in variables.keys where key.lowercased().hasPrefix("npm_config_") {
                variables[key] = nil
            }
            variables["TMPDIR"] = environment.home
        }
        variables["HOME"] = environment.home
        let invocation = SubprocessInvocation(
            argv: ["/usr/bin/env", host.rawValue] + arguments,
            executablePath: "/usr/bin/env", environment: variables, workingDirectory: nil,
            stdoutPath: stdout.path, stderrPath: stderr.path)
        let result = try Subprocess.run(invocation, timeout: 10)
        if result.timedOut {
            throw PluginLifecycleError(message: "Host version/help probe timed out")
        }
        guard result.termination == .exited(0) else {
            throw PluginLifecycleError(message: "Host version/help unavailable: " + host.rawValue)
        }
        return try String(contentsOf: stdout, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
}
