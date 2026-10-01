import Foundation

/// Launch-time capability detection.
///
/// gh has two states only: `available` (present AND ≥ 2.90.0 AND
/// `gh skill --help` exits 0) or `unavailable` — `present` / `version` /
/// `meetsMinimum` record WHY. npx skills is reported as resolvable with its
/// version when `npx --offline skills --version` succeeds; the probe never
/// downloads or updates the CLI (see `SkillsCLI`). Detection results
/// never feed ScanReport; only `sukiru-cli capabilities` and the app's
/// capability panel consume them.
public struct CapabilityDetector: Sendable {
    /// The minimum gh version whose `gh skill` surface Sukiru drives.
    public static let minimumGHVersion = "2.90.0"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// Detection against the live machine (PATH probes, real subprocesses).
    public init(environment: SukiruEnvironment) {
        self.init(runner: SystemCommandRunner(environment: environment))
    }

    /// Runs both probes and assembles the report.
    public func detect() -> CapabilityReport {
        CapabilityReport(
            schemaVersion: CapabilityReport.currentSchemaVersion,
            github: detectGitHub(),
            npx: detectNpx()
        )
    }

    private func detectGitHub() -> CapabilityReport.GitHubCapability {
        typealias Reason = GitHubUnavailableReason
        guard let outcome = runner.run("gh", ["--version"]), outcome.exitCode == 0,
            let version = Self.parseVersion(from: outcome.stdout)
        else {
            return CapabilityReport.GitHubCapability(
                available: false, present: false, version: nil, meetsMinimum: false,
                reason: .absent)
        }
        guard Self.version(version, isAtLeast: Self.minimumGHVersion) else {
            // Below the `gh skill` floor: no probe — the subcommand may not
            // exist and both cases count as unavailable either way.
            return CapabilityReport.GitHubCapability(
                available: false, present: true, version: version, meetsMinimum: false,
                reason: .tooOld)
        }
        let probeSucceeded = runner.run("gh", ["skill", "--help"])?.exitCode == 0
        return CapabilityReport.GitHubCapability(
            available: probeSucceeded,
            present: true,
            version: version,
            meetsMinimum: true,
            reason: probeSucceeded ? nil : Reason.probeFailed
        )
    }

    private func detectNpx() -> CapabilityReport.NpxCapability {
        guard let outcome = runner.run("npx", SkillsCLI.probeArguments) else {
            return CapabilityReport.NpxCapability(
                resolvable: false, skillsVersion: nil, reason: .absent)
        }
        guard outcome.exitCode == 0,
            let version = Self.firstLine(of: outcome.stdout), !version.isEmpty
        else {
            return CapabilityReport.NpxCapability(
                resolvable: false, skillsVersion: nil, reason: .notDownloaded)
        }
        return CapabilityReport.NpxCapability(
            resolvable: true, skillsVersion: version, reason: nil)
    }

    /// The first `major.minor[.patch]` token on the first line of output
    /// (`gh version 2.100.0 (2026-01-15)` → `2.100.0`).
    static func parseVersion(from output: String) -> String? {
        guard let line = output.split(separator: "\n").first else { return nil }
        guard let match = line.firstMatch(of: #/\d+\.\d+(?:\.\d+)?/#) else { return nil }
        return String(match.output)
    }

    /// The whitespace-trimmed first line, or nil for empty output.
    static func firstLine(of output: String) -> String? {
        output.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Numeric component-wise version comparison; missing components read as
    /// 0, so `2.90` meets `2.90.0`.
    static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}
