import Foundation

@testable import SukiruCore

/// Disambiguates the report model from `Testing.Issue`. This file does not
/// import Testing, so plain `Issue` is the SukiruCore model here.
typealias ScanIssue = Issue

/// Locates the checked-in `Fixtures/` corpus relative to this source file.
enum FixturePaths {
    /// `Fixtures/` at the repository root.
    static let root: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // SukiruCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// Absolute path of a named fixture tree.
    static func tree(_ name: String) -> String {
        root.appendingPathComponent(name, isDirectory: true).path
    }

    /// Resolves a fixture's scan inputs following the corpus convention
    /// (FixtureCorpusTests): a `.home` subdir becomes SUKIRU_HOME with the
    /// `proj`/`p1`/`p2` subdirs as project roots; otherwise the fixture tree
    /// itself is the fake home with no project roots.
    static func homeAndRoots(_ name: String) -> (home: String, roots: [String]) {
        homeAndRoots(atPath: tree(name))
    }

    /// Same convention as `homeAndRoots(_:)` for an arbitrary tree path
    /// (e.g. a copy of a fixture in a sandbox).
    static func homeAndRoots(atPath base: String) -> (home: String, roots: [String]) {
        let home = base + "/.home"
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: home) else {
            return (base, [])
        }
        let roots = ["proj", "p1", "p2"].map { base + "/" + $0 }.filter {
            fileManager.fileExists(atPath: $0)
        }
        return (home, roots)
    }
}
