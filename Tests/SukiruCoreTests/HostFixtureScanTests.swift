import Foundation
import Testing

@testable import SukiruCore

/// End-to-end tri-state checks: the real scan engine over the checked-in
/// scan-area fixtures (VAL-SCAN-012/013/014).
@Suite("Host tri-state against checked-in fixtures")
struct HostFixtureScanTests {
    /// `Fixtures/` at the repository root, located relative to this source file.
    static let fixturesDir: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SukiruCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Fixtures", isDirectory: true)

    private func scan(fixture name: String) throws -> ScanReport {
        let home = Self.fixturesDir.appendingPathComponent(name, isDirectory: true).path
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home])
        )
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }

    private func workspace(_ report: ScanReport, _ id: String) -> Workspace? {
        report.workspaces.first { $0.id == id }
    }

    @Test("leftover-spray: leftover flagged but scanned, detected installed, absent omitted")
    func leftoverSpray() throws {
        let report = try scan(fixture: "leftover-spray")

        let qoder = try #require(workspace(report, "host:qoder"))
        #expect(!qoder.installed, "spray residue must be flagged installed=false")
        #expect(qoder.kind == .user)
        #expect(qoder.root.hasSuffix("/.qoder/skills"))

        let claude = try #require(workspace(report, "host:claude-code"))
        #expect(claude.installed, "a real config file marks the host installed")
        #expect(claude.root.hasSuffix("/.claude/skills"))

        // The absent host is omitted entirely.
        #expect(workspace(report, "host:cursor") == nil)
        #expect(!report.workspaces.contains { $0.id.contains("cursor") })
    }

    @Test("leftover-dsstore: .DS_Store/.localized never flip a leftover into installed")
    func leftoverDSStore() throws {
        let report = try scan(fixture: "leftover-dsstore")
        let qoder = try #require(workspace(report, "host:qoder"))
        #expect(!qoder.installed)
    }

    @Test("empty-marker: empty-marker hosts are absent despite unrelated $HOME content")
    func emptyMarker() throws {
        let report = try scan(fixture: "empty-marker")
        #expect(workspace(report, "host:claude-code") == nil)
        #expect(workspace(report, "host:mistral-vibe") == nil)
        // codex additionally probes the absolute /etc/codex; where a system
        // codex install exists that probe legitimately detects the host.
        if !FileManager.default.fileExists(atPath: "/etc/codex") {
            #expect(workspace(report, "host:codex") == nil)
        }
        // Only the canonical user workspace remains on this machine.
        if !FileManager.default.fileExists(atPath: "/etc/codex") {
            #expect(report.workspaces.map(\.id) == ["user"])
        }
    }
}
