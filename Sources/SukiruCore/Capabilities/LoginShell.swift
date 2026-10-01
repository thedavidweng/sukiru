import Foundation

/// Reads PATH from the user's login shell, the way a terminal session sees
/// it, so tools installed through version managers are found.
public enum LoginShell {
    /// Set for the shell Sukiru starts, so startup files can skip slow or
    /// interactive work.
    public static let resolvingVariable = "SUKIRU_RESOLVING_ENVIRONMENT"

    /// Seconds before a slow startup file is given up on.
    public static let timeout: TimeInterval = 10

    static let marker = "__SUKIRU_PATH__"

    /// The login shell's PATH, or nil when the shell fails, times out, or
    /// prints no usable PATH.
    public static func path(timeout: TimeInterval = timeout) -> String? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-shell-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: output)
        else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        // Interactive as well as login: nvm, fnm, and `mise activate` live in
        // interactive startup files (.zshrc, .bashrc, config.fish).
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        var environment = ProcessInfo.processInfo.environment
        environment[resolvingVariable] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // A file, not a pipe: a background job started by a startup file
        // could hold a pipe open forever.
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // Interactive shells ignore SIGTERM.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard process.terminationStatus == 0,
            let data = try? Data(contentsOf: output),
            let text = String(bytes: data, encoding: .utf8)
        else { return nil }
        return extractPath(from: text)
    }

    /// The PATH between the markers, ignoring anything startup files print.
    static func extractPath(from output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[parts.count - 2]
        return path.contains("/") ? path : nil
    }

    private static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}
