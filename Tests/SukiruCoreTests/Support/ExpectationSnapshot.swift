import Foundation

/// Committed per-fixture scan expectations for the seam-A corpus suite
/// (feature `seam-a-corpus-validation`). A snapshot is a fixture's normalized
/// `sukiru-cli scan --format json` stdout: every occurrence of the fixture's
/// absolute base path is replaced with `<FIXTURE>`, so the committed
/// expectation is machine-independent while everything else (hashes,
/// provenance, evidence) stays byte-exact.
///
/// Record or refresh snapshots with:
///   SUKIRU_UPDATE_SNAPSHOTS=1 swift test --filter CorpusExpectationTests
enum ExpectationSnapshot {
    /// `Fixtures/expectations/`, the committed snapshot directory.
    static let directory: URL =
        FixturePaths.root.appendingPathComponent("expectations", isDirectory: true)

    /// Whether the suite records snapshots instead of asserting them.
    static var recordMode: Bool {
        ProcessInfo.processInfo.environment["SUKIRU_UPDATE_SNAPSHOTS"] == "1"
    }

    /// The snapshot URL for a fixture name.
    static func url(for fixture: String) -> URL {
        directory.appendingPathComponent("\(fixture).scan.json")
    }

    /// Replaces the fixture's absolute base path (and its symlink-resolved
    /// form, which realpath-backed `canonicalPath` fields use) with the
    /// `<FIXTURE>` placeholder.
    static func normalize(_ text: String, fixtureBase: String) -> String {
        var normalized = text.replacingOccurrences(of: fixtureBase, with: "<FIXTURE>")
        let resolved = URL(fileURLWithPath: fixtureBase).resolvingSymlinksInPath().path
        if resolved != fixtureBase {
            normalized = normalized.replacingOccurrences(of: resolved, with: "<FIXTURE>")
        }
        return normalized
    }

    /// Writes a snapshot (record mode), creating the directory if needed.
    static func record(_ text: String, for fixture: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: url(for: fixture), atomically: true, encoding: .utf8)
    }

    /// Describes the first differing line between two texts, or nil when
    /// they are equal. Used to keep snapshot-mismatch failures readable.
    static func firstDivergence(_ actual: String, _ expected: String) -> String? {
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<max(actualLines.count, expectedLines.count) {
            let actualLine = index < actualLines.count ? String(actualLines[index]) : "<missing>"
            let expectedLine =
                index < expectedLines.count ? String(expectedLines[index]) : "<missing>"
            if actualLine != expectedLine {
                return "line \(index + 1): actual \(actualLine) != expected \(expectedLine)"
            }
        }
        return nil
    }
}
