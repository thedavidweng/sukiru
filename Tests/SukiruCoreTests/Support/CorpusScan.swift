import Foundation
import Testing

@testable import SukiruCore

/// Shared helpers for the corpus suites: decode a fixture's scan into
/// the typed `ScanReport` and query findings without JSONSerialization noise.
extension CLIRunner {
    /// Runs `scan --format json` against a fixture and decodes the
    /// report. A non-zero exit fails the test with the CLI's stderr.
    static func scanReport(
        _ fixture: String,
        arguments: [String] = [],
        extraEnv: [String: String] = [:]
    ) throws -> ScanReport {
        let result = try scanFixture(fixture, arguments: arguments, extraEnv: extraEnv)
        let stderr = String(bytes: result.stderr, encoding: .utf8) ?? ""
        try #require(
            result.exitCode == 0,
            "scan of \(fixture) exited \(result.exitCode); stderr: \(stderr)"
        )
        return try JSONDecoder().decode(ScanReport.self, from: result.stdout)
    }
}

extension ScanReport {
    /// Findings with the given rule ID, optionally narrowed to one skill.
    func findings(rule ruleID: String, skill: String? = nil) -> [Finding] {
        findings.filter { finding in
            finding.ruleID == ruleID && (skill == nil || finding.skillName == skill)
        }
    }

    /// The CM generator-hygiene guarantee: no user-scope `lock-without-files`
    /// finding. The pinned skills CLI wrote a global lock into each generator
    /// sandbox home with no user-scope placement; generate.sh now resets the
    /// sandbox home, so a CM scan must be free of that noise.
    var hasUserScopeLockNoise: Bool {
        findings.contains { $0.ruleID == "lock-without-files" && $0.workspaceID == "user" }
    }
}

extension Finding {
    /// All `detail` values of evidence entries with the given kind.
    func evidenceDetails(_ kind: String) -> [String] {
        evidence.filter { $0.kind == kind }.map(\.detail)
    }
}
