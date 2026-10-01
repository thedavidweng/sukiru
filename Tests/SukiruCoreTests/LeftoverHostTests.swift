import Foundation
import Testing

@testable import SukiruCore

/// `leftover-host-dir`: a folder of links a CLI sprayed for an agent that
/// is not installed is flagged, removed by its one-click fix, and restored
/// by rollback. Serialized because it executes through the real CLIExecutor.
@Suite("Leftover host folders", .serialized)
struct LeftoverHostTests {
    /// The shared store holds `alpha`; AdaL (not installed) has only a
    /// folder of links into it; Qoder (not installed) holds a real copy.
    private static func sprayedHome() throws -> TempTree {
        let home = try TempTree()
        try home.file(".agents/skills/alpha/SKILL.md", contents: OwnershipBuilders.skillMD("alpha"))
        try home.symlink(".adal/skills/alpha", to: "../../.agents/skills/alpha")
        try home.file(".adal/.DS_Store", contents: "")
        try home.file(".qoder/skills/beta/SKILL.md", contents: OwnershipBuilders.skillMD("beta"))
        return home
    }

    @Test("Only a leftover folder holding nothing but links is flagged")
    func detection() throws {
        let home = try Self.sprayedHome()
        let report = try OwnershipBuilders.scan(home: home)
        let leftovers = report.findings.filter { $0.ruleID == LeftoverHostRule.ruleID }
        let finding = try #require(leftovers.first)
        #expect(leftovers.count == 1)
        #expect(finding.workspaceID == "host:adal")
        #expect(finding.skillName == nil)
        #expect(ProblemKind.of(finding) == .leftoverHostDir)
        #expect(ProblemKind.oneClickFix(for: finding) == .cleanup)
        let evidence = Dictionary(
            uniqueKeysWithValues: finding.evidence.map { ($0.kind, $0.detail) })
        #expect(evidence["skillsDir"] == home.path + "/.adal/skills")
        #expect(evidence["linkCount"] == "1")
        #expect(evidence["hosts"] == "AdaL")
    }

    @Test("The fix removes the folder and its emptied parent; rollback restores both")
    func fixAndRollback() throws {
        let home = try Self.sprayedHome()
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home.path]))
        let report = try OwnershipBuilders.scan(home: home)
        let id = try #require(
            FindingID.assignments(for: report.findings)
                .first { $0.finding.ruleID == LeftoverHostRule.ruleID }?.id)
        let built = try #require(
            try BatchTestSupport.makeBuilder().build(
                report: report, decisions: [BatchTestSupport.decide(id, .cleanup)]))
        let skillsDir = home.path + "/.adal/skills"
        #expect(
            built.commands.map(\.argv)
                == [["sukiru-fileop", "remove-leftover-skills-dir", skillsDir]])
        #expect(built.commands[0].dangerFlags == [.directFileOperation])

        let result = try CLIExecutor(environment: environment).execute(
            batch: try built.transitioned(to: .reviewed), report: report)

        let fileManager = FileManager.default
        #expect(result.record.batchStatus == .succeeded)
        #expect(!fileManager.fileExists(atPath: home.path + "/.adal"))
        #expect(fileManager.fileExists(atPath: home.path + "/.agents/skills/alpha/SKILL.md"))
        #expect(fileManager.fileExists(atPath: home.path + "/.qoder/skills/beta/SKILL.md"))
        let after = try OwnershipBuilders.scan(home: home)
        #expect(!after.findings.contains { $0.ruleID == LeftoverHostRule.ruleID })

        let record = try Rollback(environment: environment).rollback(batchID: built.id)

        #expect(!record.items.contains { $0.category == .unrestorableWithReason })
        let restored = try OwnershipBuilders.scan(home: home)
        #expect(try restored.jsonData() == report.jsonData())
    }

    @Test("The removal refuses a folder that gained a real copy since the scan")
    func refusesRealContent() throws {
        let home = try Self.sprayedHome()
        try home.file(".adal/skills/local/SKILL.md", contents: OwnershipBuilders.skillMD("local"))
        let operation = FileOperation.removeLeftoverSkillsDir(home.path + "/.adal/skills")
        #expect(throws: FileOperationError.self) { try operation.perform() }
        #expect(FileManager.default.fileExists(atPath: home.path + "/.adal/skills/alpha"))
    }
}
