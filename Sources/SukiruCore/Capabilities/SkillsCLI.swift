import Foundation

/// How Sukiru reaches the Vercel `skills` CLI without ever downloading or
/// updating it behind the user's back.
///
/// Unattended npx (no TTY, `CI=1`) assumes `--yes`, so a bare
/// `npx skills@latest` would silently install whatever the registry calls
/// latest. Instead the launch probe runs `--offline` (answers only from what
/// this Mac already has), the update check is a plain registry read, and the
/// CLI is fetched only when the user asks: from Settings, or by confirming a
/// batch whose first `npx skills` command downloads it (`CLIExecutor` runs
/// prefer-offline, so a CLI already on this Mac is never replaced).
public enum SkillsCLI {
    /// The launch probe: never touches the network.
    static let probeArguments = ["--offline", "skills", "--version"]

    /// Downloads the CLI, or moves it to the registry's latest release.
    static let fetchArguments = ["--yes", "--prefer-online", "skills", "--version"]

    /// The registry's metadata for the release tagged `latest`.
    public static let latestReleaseURL = URL(string: "https://registry.npmjs.org/skills/latest")!

    /// Seconds a user-requested download may take (a cold fetch on a slow
    /// network is far beyond the probe timeout).
    static let fetchTimeout: TimeInterval = 300

    private struct Release: Decodable {
        let version: String
    }

    /// The version npm would install as latest. Reads metadata only.
    public static func latestVersion(transport: any MarketplaceTransport) async throws -> String {
        let data = try await transport.fetch(latestReleaseURL)
        do {
            return try JSONDecoder().decode(Release.self, from: data).version
        } catch {
            throw MarketplaceError.malformed(String(describing: error))
        }
    }

    /// True when `latest` is a newer release than `installed`.
    public static func isUpdate(_ latest: String, over installed: String) -> Bool {
        !CapabilityDetector.version(installed, isAtLeast: latest)
    }

    /// Runs the user-requested download or update. Returns nil on success,
    /// otherwise the tail of what npx printed.
    public static func fetch(environment: SukiruEnvironment) -> String? {
        fetch(runner: SystemCommandRunner(environment: environment, timeout: fetchTimeout))
    }

    static func fetch(runner: any CommandRunning) -> String? {
        guard let outcome = runner.run("npx", fetchArguments) else {
            return "npx could not be started or timed out."
        }
        guard outcome.exitCode != 0 else { return nil }
        let output = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
        return output.split(separator: "\n").suffix(3).joined(separator: "\n")
    }
}
