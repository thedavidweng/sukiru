import Foundation
import Testing

@testable import SukiruCore

/// ADR 0009 repairs: removing a redundant link a host reports, and keeping
/// one of several different folders.
@Suite("Host name collision repairs")
struct HostNameCollisionRepairTests {
    private typealias Support = BatchTestSupport
    private static let rule = HostNameCollisionRule.ruleID

    private static func memberPaths(_ report: ScanReport, _ skill: String) throws -> [String] {
        let finding = try #require(
            report.findings.first { $0.ruleID == rule && $0.skillName == skill })
        return finding.evidence.filter { $0.kind == "memberPath" }.map(\.detail)
    }

    @Test("Cleanup deletes only the redundant Droid link, never the shared folder")
    func removeRedundantLink() throws {
        let home = try TempTree()
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".factory/skills/tool", to: "../../.agents/skills/tool")
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")

        let batch = try Support.build(report, [Support.decide(id, .cleanup)])
        let command = try #require(batch.commands.only)
        #expect(
            command.fileOperation.map { if case .deleteLink = $0 { true } else { false } } == true)
        #expect(command.argv.contains { $0.hasSuffix("/.factory/skills/tool") })
        #expect(!command.argv.contains { $0.hasSuffix("/.agents/skills/tool") })
    }

    @Test("Cleanup refuses a collision with no redundant link")
    func cleanupNeedsRedundantLink() throws {
        let home = try TempTree()
        try home.file(".cursor/skills/first/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(".cursor/skills/second/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")

        let problems = Support.problems(report, [Support.decide(id, .cleanup)])
        #expect(problems.contains { $0.contains("no redundant link") })
    }

    @Test("Keeping one ownerless folder deletes the other folder only")
    func keepOwnerlessFolder() throws {
        let home = try TempTree()
        try home.file(".cursor/skills/first/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".cursor/skills/second/SKILL.md",
            contents: OwnershipBuilders.skillMD("tool", variant: "Other."))
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")
        let kept = try #require(
            try Self.memberPaths(report, "tool").first { $0.hasSuffix("/first") })

        let batch = try Support.build(
            report, [Support.decide(id, .arbitrate, .keepEntry(path: kept))])
        let command = try #require(batch.commands.only)
        #expect(command.argv.contains { $0.hasSuffix("/.cursor/skills/second") })
        #expect(!command.argv.contains(kept))
        #expect(command.dangerFlags.contains(.ownerlessCleanup))
    }

    @Test("Keeping an entry spares links that reach the kept folder")
    func keepSparesAliases() throws {
        let home = try TempTree()
        try home.dir(".config/opencode")
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".claude/skills/tool", to: "../../.agents/skills/tool")
        try home.symlink(".config/opencode/skills/tool", to: home.path + "/.elsewhere/tool")
        try home.file(".elsewhere/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")
        let kept = try #require(
            try Self.memberPaths(report, "tool").first { $0.hasSuffix("/.agents/skills/tool") })

        let batch = try Support.build(
            report, [Support.decide(id, .arbitrate, .keepEntry(path: kept))])
        let command = try #require(batch.commands.only)
        #expect(command.argv.contains { $0.hasSuffix("/.config/opencode/skills/tool") })
    }

    @Test("Keeping refuses deleting a folder another agent links to")
    func keepRefusesDanglingLinks() throws {
        let home = try TempTree()
        try home.file(".cursor/skills/first/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".cursor/skills/second/SKILL.md",
            contents: OwnershipBuilders.skillMD("tool", variant: "Other."))
        try home.symlink(".claude/skills/tool", to: "../../.cursor/skills/second")
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")
        let kept = try #require(
            try Self.memberPaths(report, "tool").first { $0.hasSuffix("/first") })

        let problems = Support.problems(
            report, [Support.decide(id, .arbitrate, .keepEntry(path: kept))])
        #expect(problems.contains { $0.contains("dead link") })
    }

    @Test("Keeping refuses folders an agent manages")
    func keepRefusesAgentManaged() throws {
        let home = try TempTree()
        try home.file(".hermes/skills/.bundled_manifest", contents: "")
        try home.file(
            ".hermes/skills/one/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".hermes/skills/two/tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("tool", variant: "Other."))
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")
        let kept = try #require(try Self.memberPaths(report, "tool").first)

        let problems = Support.problems(
            report, [Support.decide(id, .arbitrate, .keepEntry(path: kept))])
        #expect(problems.contains { $0.contains("managed by hermes-agent") })
    }

    @Test("Keeping refuses a path outside the finding and a same-folder collision")
    func keepRefusesInvalidChoices() throws {
        let home = try TempTree()
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".factory/skills/tool", to: "../../.agents/skills/tool")
        let report = try OwnershipBuilders.scan(home: home)
        let id = try Support.findingID(report, Self.rule, "tool")

        let problems = Support.problems(
            report, [Support.decide(id, .arbitrate, .keepEntry(path: "/elsewhere"))])
        #expect(problems.contains { $0.contains("nothing to choose") })
    }

    @Test("The decisions file and batch records carry the kept entry")
    func keepChoiceWireFormat() throws {
        let data = Data(#"{"f1": {"action": "arbitrate", "choice": {"keep": "/a/tool"}}}"#.utf8)
        let entries = try DecisionsFile.parse(data).get()
        #expect(
            entries == [
                DecisionEntry(
                    findingID: "f1", action: .arbitrate, choice: .keepEntry(path: "/a/tool"))
            ])

        let encoded = try JSONEncoder().encode(DecisionChoice.keepEntry(path: "/a/tool"))
        #expect(
            try JSONDecoder().decode(DecisionChoice.self, from: encoded)
                == .keepEntry(path: "/a/tool"))
    }
}
