import Foundation
import Testing

@testable import SukiruCore

/// Capability detection with an injectable command
/// runner — no real subprocesses in unit tests. gh is `available` iff present
/// AND ≥ 2.90.0 AND `gh skill --help` exits 0; npx skills is `resolvable`
/// with its version when `npx -y skills@latest --version` succeeds.
@Suite("Capability detection")
struct CapabilityDetectorTests {
    /// Answers subprocess invocations from a fixed table keyed by
    /// `"<executable> <arg> <arg>…"`; nil means "cannot be spawned" (absent).
    private struct StubRunner: CommandRunning {
        let outcomes: [String: ProcessOutcome]

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            outcomes[([executable] + arguments).joined(separator: " ")]
        }
    }

    private func outcome(_ exitCode: Int32, _ stdout: String = "") -> ProcessOutcome {
        ProcessOutcome(exitCode: exitCode, stdout: stdout, stderr: "")
    }

    private func detect(_ outcomes: [String: ProcessOutcome]) -> CapabilityReport {
        CapabilityDetector(runner: StubRunner(outcomes: outcomes)).detect()
    }

    @Test("gh present, ≥ 2.90.0, probe OK → available with version")
    func ghAvailable() {
        var outcomes = [String: ProcessOutcome]()
        outcomes["gh --version"] = outcome(0, "gh version 2.100.0 (2026-01-15)\n")
        outcomes["gh skill --help"] = outcome(0, "Manage skills\n")
        let report = detect(outcomes)
        #expect(report.github.available)
        #expect(report.github.present)
        #expect(report.github.meetsMinimum)
        #expect(report.github.version == "2.100.0")
        #expect(report.github.reason == nil)
    }

    @Test("gh absent → unavailable, not present, no version, reason absent")
    func ghAbsent() {
        let report = detect([:])
        #expect(!report.github.available)
        #expect(!report.github.present)
        #expect(report.github.version == nil)
        #expect(!report.github.meetsMinimum)
        #expect(report.github.reason == .absent)
    }

    @Test("gh too old → present but not available, not minimum, probe skipped")
    func ghTooOld() {
        // No "gh skill --help" entry: the detector must not even probe a
        // below-minimum gh (nil would still fail the probe, masking the test's
        // intent if the probe were consulted).
        let report = detect([
            "gh --version": outcome(0, "gh version 2.80.0 (2025-01-01)\n")
        ])
        #expect(!report.github.available)
        #expect(report.github.present)
        #expect(report.github.version == "2.80.0")
        #expect(!report.github.meetsMinimum)
        #expect(report.github.reason == .tooOld)
    }

    @Test("gh new enough but skill probe fails → unavailable with probe-failed reason")
    func ghProbeFails() {
        var outcomes = [String: ProcessOutcome]()
        outcomes["gh --version"] = outcome(0, "gh version 2.100.0\n")
        outcomes["gh skill --help"] = outcome(1, "unknown command")
        let report = detect(outcomes)
        #expect(!report.github.available)
        #expect(report.github.present)
        #expect(report.github.meetsMinimum)
        #expect(report.github.reason == .probeFailed)
    }

    @Test("gh probe that cannot be spawned at all → probe-failed reason")
    func ghProbeUnspawnable() {
        // `gh --version` answers but `gh skill --help` cannot even be spawned
        // (nil outcome): still present+minimum, but unavailable probe-failed.
        let report = detect([
            "gh --version": outcome(0, "gh version 2.100.0\n")
        ])
        #expect(!report.github.available)
        #expect(report.github.present)
        #expect(report.github.meetsMinimum)
        #expect(report.github.reason == .probeFailed)
    }

    @Test("gh --version unparsable → treated as absent")
    func ghUnparsable() {
        let report = detect([
            "gh --version": outcome(0, "totally unexpected output\n")
        ])
        #expect(!report.github.available)
        #expect(!report.github.present)
        #expect(report.github.reason == .absent)
    }

    @Test("gh --version non-zero exit → treated as absent")
    func ghVersionFails() {
        let report = detect([
            "gh --version": outcome(1, "")
        ])
        #expect(!report.github.available)
        #expect(!report.github.present)
        #expect(report.github.reason == .absent)
    }

    @Test("npx skills resolvable → resolvable with trimmed version")
    func npxResolvable() {
        let report = detect([
            "npx -y skills@latest --version": outcome(0, "1.5.26\n")
        ])
        #expect(report.npx.resolvable)
        #expect(report.npx.skillsVersion == "1.5.26")
    }

    @Test("npx absent → unresolvable, no version, still a valid report")
    func npxAbsent() {
        let report = detect([:])
        #expect(!report.npx.resolvable)
        #expect(report.npx.skillsVersion == nil)
        #expect(report.schemaVersion == CapabilityReport.currentSchemaVersion)
    }

    @Test("npx fails or prints nothing → unresolvable")
    func npxFailureModes() {
        let failing = detect([
            "npx -y skills@latest --version": outcome(1, "npm error")
        ])
        #expect(!failing.npx.resolvable)

        let empty = detect([
            "npx -y skills@latest --version": outcome(0, "  \n")
        ])
        #expect(!empty.npx.resolvable)
    }

    @Test("Version parsing: first semver token of the first line")
    func versionParsing() {
        let released = CapabilityDetector.parseVersion(from: "gh version 2.100.0 (2026-01-15)")
        #expect(released == "2.100.0")
        #expect(CapabilityDetector.parseVersion(from: "2.90.0") == "2.90.0")
        #expect(CapabilityDetector.parseVersion(from: "gh version 2.90\n") == "2.90")
        #expect(CapabilityDetector.parseVersion(from: "no version here") == nil)
        #expect(CapabilityDetector.parseVersion(from: "") == nil)
    }

    @Test("Minimum comparison is numeric per component, missing = 0")
    func versionComparison() {
        #expect(CapabilityDetector.version("2.90.0", isAtLeast: "2.90.0"))
        #expect(CapabilityDetector.version("2.100.0", isAtLeast: "2.90.0"))
        #expect(CapabilityDetector.version("10.0.0", isAtLeast: "2.90.0"))
        #expect(CapabilityDetector.version("2.90", isAtLeast: "2.90.0"))
        #expect(!CapabilityDetector.version("2.9.9", isAtLeast: "2.90.0"))
        #expect(!CapabilityDetector.version("1.99.0", isAtLeast: "2.90.0"))
    }
}
