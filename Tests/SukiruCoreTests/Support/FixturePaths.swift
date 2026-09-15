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
}
