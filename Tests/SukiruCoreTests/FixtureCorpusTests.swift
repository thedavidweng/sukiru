import Foundation
import Testing

@testable import SukiruCore

/// Smoke test for the checked-in fixture corpus (feature `fixture-corpus`,
/// architecture D17).
///
/// It guarantees two things the rest of the seam-A milestone depends on:
/// every required hand-built tree is present with an expectation note, and the
/// read engine loads every fixture directory without throwing, producing a
/// schema-valid report. As the engine grows past the skeleton, this becomes a
/// real "every fixture parses" guard; today it already catches a missing tree,
/// a missing note, or a tree that trips the engine.
@Suite("Fixture corpus smoke test")
struct FixtureCorpusTests {
    /// `Fixtures/` at the repository root, located relative to this source file.
    static let fixturesDir: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SukiruCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// Hand-built trees that MUST be checked in (this feature's scope + D17).
    /// Newline-listed to stay within the line-length gate without multi-line
    /// collection-literal trailing-comma churn.
    static let requiredHandBuilt: [String] =
        """
        FIX-EMPTY
        FIX-CLEAN
        FIX-INTERNAL
        FIX-MALFORMED
        FIX-GARBAGE
        FIX-DANGER
        FIX-BIG
        FIX-DUPLICATES
        FIX-LOCK-NO-FILES
        FIX-FILES-NO-LOCK
        FIX-AMBIGUOUS
        alias-link-mode
        symlink-mode
        skillmd-invalid-a
        skillmd-invalid-b
        skillmd-invalid-c
        skillmd-invalid-d
        skillmd-invalid-e
        skillmd-invalid-f
        skillmd-early-close
        """
        .split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces)) }

    @Test("Every required hand-built fixture exists with an expectation note")
    func requiredFixturesPresent() {
        let fileManager = FileManager.default
        for name in Self.requiredHandBuilt {
            let dir = Self.fixturesDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: dir.path, isDirectory: &isDir)
            #expect(exists && isDir.boolValue, "missing fixture directory: \(name)")

            let note = dir.appendingPathComponent("EXPECTATION.md")
            #expect(
                fileManager.fileExists(atPath: note.path),
                "fixture \(name) is missing its EXPECTATION.md note"
            )
        }
    }

    @Test("Every fixture directory loads without throwing and yields a valid report")
    func everyFixtureLoads() throws {
        let fileManager = FileManager.default
        let entries =
            try fileManager.contentsOfDirectory(
                at: Self.fixturesDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )

        var scannedCount = 0
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let noteURL = entry.appendingPathComponent("EXPECTATION.md")
            guard fileManager.fileExists(atPath: noteURL.path) else { continue }
            scannedCount += 1

            // CLI-generated CM-* trees keep their sandbox home and project root
            // in `.home`/`proj` subdirs; hand-built trees ARE the fake home.
            let sandboxHome = entry.appendingPathComponent(".home", isDirectory: true)
            let projRoot = entry.appendingPathComponent("proj", isDirectory: true)
            let home: String
            var roots: [String] = []
            if isDirectory(sandboxHome), isDirectory(projRoot) {
                home = sandboxHome.path
                roots = [projRoot.path]
            } else {
                home = entry.path
            }

            let report = try scan(home: home, roots: roots)
            #expect(
                report.schemaVersion == ScanReport.currentSchemaVersion,
                "fixture \(entry.lastPathComponent) did not load a schema-valid report"
            )
        }

        #expect(
            scannedCount >= Self.requiredHandBuilt.count,
            "expected at least \(Self.requiredHandBuilt.count) fixtures, scanned \(scannedCount)"
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private func scan(home: String, roots: [String]) throws -> ScanReport {
        var vars = ["SUKIRU_HOME": home]
        if !roots.isEmpty {
            vars["SUKIRU_ROOTS"] = roots.joined(separator: ":")
        }
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        let engine = ScanEngine(environment: environment)
        return try engine.scan(ScanRequest())
    }
}
