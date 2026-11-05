import Foundation
import Testing

@testable import SukiruCore

/// The built executable's deployment contract (issue #82): the preview plans
/// exactly one link and writes nothing, the confirmed run creates it under a
/// snapshot, danger consent stays separate from --yes, and rollback removes
/// the link and the folder the batch created.
@Suite("sukiru-cli skills link")
struct HostLinkCLIIntegrationTests {
    private static func home() throws -> TempTree {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))
        try home.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(".gemini/antigravity-cli/state.json", contents: "{}")
        return home
    }

    private static func stderr(_ result: CLIRunner.Result) -> String {
        String(bytes: result.stderr, encoding: .utf8) ?? ""
    }

    @Test("Dry-run renders one link command and writes nothing")
    func dryRunWritesNothing() throws {
        let home = try Self.home()
        let link = home.path + "/.gemini/config/skills/tool"
        let result = try CLIRunner.run(
            ["skills", "link", "tool", "--host", "antigravity-cli", "--dry-run"],
            environment: CLIRunner.fixtureEnvironment(home: home.path))
        #expect(result.exitCode == 0, "stderr: \(Self.stderr(result))")
        let batch = try #require(try result.jsonObject())
        let commands = try #require(batch["commands"] as? [[String: Any]])
        #expect(
            commands.compactMap { $0["argv"] as? [String] } == [
                ["sukiru-fileop", "link", link, home.path + "/.agents/skills/tool"]
            ])
        #expect(DefaultFileSystemProbe().entryKind(atPath: link) == nil)
    }

    @Test("--yes without danger consent creates nothing")
    func dangerConsentIsSeparate() throws {
        let home = try Self.home()
        let link = home.path + "/.gemini/config/skills/tool"
        let result = try CLIRunner.run(
            ["skills", "link", "tool", "--host", "antigravity-cli", "--yes"],
            environment: CLIRunner.fixtureEnvironment(home: home.path))
        #expect(result.exitCode != 0)
        #expect(DefaultFileSystemProbe().entryKind(atPath: link) == nil)
    }

    @Test("The confirmed link is snapshot-protected and rollback removes it")
    func executeAndRollback() throws {
        let home = try Self.home()
        let environment = CLIRunner.fixtureEnvironment(home: home.path)
        let link = home.path + "/.gemini/config/skills/tool"
        let store = home.path + "/.agents/skills/tool"
        let run = try CLIRunner.run(
            ["skills", "link", "tool", "--host", "antigravity-cli", "--yes", "--confirm-dangerous"],
            environment: environment)
        #expect(run.exitCode == 0, "stderr: \(Self.stderr(run))")
        #expect(DefaultFileSystemProbe().entryKind(atPath: link) == .symlink(target: store))

        let snapshots = try CLIRunner.run(["snapshots"], environment: environment)
        let records =
            try JSONSerialization.jsonObject(with: snapshots.stdout) as? [[String: Any]]
        let batchID = try #require(records?.first?["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--batch", batchID, "--yes"], environment: environment)
        #expect(rollback.exitCode == 0, "stderr: \(Self.stderr(rollback))")
        #expect(DefaultFileSystemProbe().entryKind(atPath: link) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.gemini/config/skills"))
    }
}
