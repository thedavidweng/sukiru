import Foundation
import Testing

@testable import SukiruCore

/// The finding severity mapping swept over the whole checked-in fixture
/// corpus: every finding on every fixture carries the severity the mapping
/// assigns its rule (cross-host-duplicate disambiguated by subtype evidence).
@Suite("HealthAnalyzer severity sweep")
struct HealthAnalyzerSeverityTests {
    // MARK: - Severity sweep

    @Test("Every finding on every dirty fixture matches the severity mapping")
    func severitiesMatchMapping() throws {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: FixturePaths.root, includingPropertiesForKeys: [.isDirectoryKey])
        var scanned = 0
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let notePath = entry.appendingPathComponent("EXPECTATION.md").path
            guard fileManager.fileExists(atPath: notePath) else { continue }
            let home = entry.appendingPathComponent(".home", isDirectory: true)
            let proj = entry.appendingPathComponent("proj", isDirectory: true)
            var isDir: ObjCBool = false
            let split =
                fileManager.fileExists(atPath: home.path, isDirectory: &isDir)
                && isDir.boolValue
                && fileManager.fileExists(atPath: proj.path, isDirectory: &isDir)
                && isDir.boolValue
            let report: ScanReport
            if split {
                report = try OwnershipBuilders.scanSplitFixture(entry.lastPathComponent)
            } else {
                report = try OwnershipBuilders.scan(fixture: entry.lastPathComponent)
            }
            scanned += 1
            for finding in report.findings {
                let name = finding.skillName ?? "-"
                let message =
                    "\(entry.lastPathComponent): \(finding.ruleID)/\(name) "
                    + "is \(finding.severity), expected \(Self.expectedSeverity(for: finding))"
                #expect(finding.severity == Self.expectedSeverity(for: finding), "\(message)")
            }
        }
        #expect(scanned >= 30)
    }

    /// The expected severity for a finding: the fixed rule table, with
    /// cross-host-duplicate disambiguated by its subtype evidence.
    private static func expectedSeverity(for finding: Finding) -> Severity {
        switch finding.ruleID {
        case "broken-symlink", "vercel-lock-drift", "double-booked", "lock-without-files",
            "canonical-host-divergence", "dangerous-removal-surface":
            return .action
        case "ambiguous-name", "symlink-authenticity", "lock-version-unsupported",
            "leftover-host-dir", "host-name-collision":
            return .warning
        case "files-without-lock":
            return .info
        case "cross-host-duplicate":
            let subtype = finding.evidence.first { $0.kind == "subtype" }?.detail
            return subtype == "alias" ? .info : .warning
        default:
            Issue.record("unmapped ruleID \(finding.ruleID)")
            return .info
        }
    }
}
