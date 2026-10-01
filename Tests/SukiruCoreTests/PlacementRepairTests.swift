import Foundation
import Testing

@testable import SukiruCore

/// Agent-managed ownership, the user-facing problem catalog, and the
/// placement-level repairs of ADR-0007: stale lock entries, dead links,
/// link ↔ copy mode, and Vercel adoption.
@Suite("Placement repairs")
struct PlacementRepairTests {
    private typealias Support = BatchTestSupport

    /// A user scope with a locked `tool` in the shared store, a diverged
    /// Claude Code copy of it, a stale lock entry `gone` with a dead link,
    /// and a dead link with no lock entry.
    private static func messyHome() throws -> TempTree {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool", "gone"]))
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".claude/skills/tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("tool", variant: "Edited."))
        try home.symlink(".claude/skills/gone", to: "../../.agents/skills/gone")
        try home.symlink(".claude/skills/dead", to: "/nonexistent/dead")
        return home
    }

    // MARK: - agent-managed ownership

    @Test("Hermes hub skills and Codex built-ins are agent-managed, not orphans")
    func agentManagedSkills() throws {
        let home = try TempTree()
        try home.file(".hermes/skills/.bundled_manifest", contents: "")
        try home.file(".hermes/skills/notes/SKILL.md", contents: OwnershipBuilders.skillMD("notes"))
        try home.file(".codex/config.toml", contents: "")
        try home.file(
            ".codex/skills/.system/builtin/SKILL.md",
            contents: OwnershipBuilders.skillMD("builtin"))
        let report = try OwnershipBuilders.scan(home: home)
        let notes = try #require(report.skills.first { $0.name == "notes" })
        #expect(notes.ownership == .agent)
        #expect(notes.managingAgent == "hermes-agent")
        let builtin = try #require(report.skills.first { $0.name == "builtin" })
        #expect(builtin.ownership == .agent)
        #expect(builtin.managingAgent == "codex")
        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
        #expect(!report.findings.contains { ProblemKind.of($0).isProblem })
    }

    // MARK: - problem catalog

    @Test("Findings map to plain problems with one-click fixes")
    func problemCatalog() throws {
        let home = try Self.messyHome()
        let report = try OwnershipBuilders.scan(home: home)
        let kinds = Dictionary(
            grouping: report.findings, by: { ProblemKind.of($0) }
        ).mapValues { $0.compactMap(\.skillName).sorted() }
        #expect(kinds[.staleLockEntry] == ["gone"])
        #expect(kinds[.deadLink] == ["dead", "gone"])
        #expect(kinds[.copyInsteadOfLink]?.contains("tool") == true)
        #expect(kinds[.outOfSync]?.contains("tool") == true)
        for finding in report.findings where ProblemKind.of(finding) == .deadLink {
            #expect(ProblemKind.oneClickFix(for: finding) == .cleanup)
        }
    }

    // MARK: - Fix All

    @Test("Fix All builds one deduplicated batch for every one-click problem")
    func fixAllBatch() throws {
        let home = try Self.messyHome()
        let report = try OwnershipBuilders.scan(home: home)
        let decisions = FindingID.assignments(for: report.findings).compactMap { pair in
            ProblemKind.oneClickFix(for: pair.finding).map { Support.decide(pair.id, $0) }
        }
        let built = Support.makeBuilder().buildApplicable(report: report, decisions: decisions)
        #expect(built.skipped.isEmpty)
        let batch = try #require(built.batch)
        let argvs = batch.commands.map(\.argv)
        let claude = home.path + "/.claude/skills"
        #expect(argvs.contains(["sukiru-fileop", "delete-link", claude + "/dead"]))
        #expect(argvs.contains(["sukiru-fileop", "delete-link", claude + "/gone"]))
        #expect(argvs.contains(["npx", "skills", "remove", "gone", "-g", "-y"]))
        let relinks = batch.commands.filter { $0.argv[1] == "relink" }
        let relink = try #require(relinks.only, "every finding on 'tool' relinks one copy once")
        #expect(relink.argv[2] == claude + "/tool")
        #expect(relink.dangerFlags.contains(.discardsLocalChanges))
        #expect(batch.findingRefs.allSatisfy { $0.workspaceID == "user" })
    }

    @Test("Fix All skips a repair that cannot apply and keeps the rest")
    func fixAllSkipsInapplicable() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".claude/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.file(".cursor/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.symlink(".claude/skills/dead", to: "/nonexistent/dead")
        let report = try OwnershipBuilders.scan(home: home)
        let decisions = FindingID.assignments(for: report.findings).compactMap { pair in
            ProblemKind.oneClickFix(for: pair.finding).map { Support.decide(pair.id, $0) }
        }
        let built = Support.makeBuilder().buildApplicable(report: report, decisions: decisions)
        #expect(built.skipped.contains { $0.contains("no copy in the shared skills folder") })
        let batch = try #require(built.batch)
        #expect(batch.commands.map { $0.argv[1] } == ["delete-link"])
    }

    // MARK: - link ↔ copy

    @Test("Switching to copies materializes every host link; links back relinks them")
    func modeSwitch() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".claude/skills/tool", to: "../../.agents/skills/tool")
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "tool" })
        let builder = Support.makeBuilder()
        let toCopy = try builder.buildModeSwitch(skill: skill, to: .copy, report: report)
        #expect(
            toCopy.commands.map(\.argv)
                == [["sukiru-fileop", "materialize", home.path + "/.claude/skills/tool"]])
        #expect(toCopy.findingRefs.only?.workspaceID == "user")
        #expect(throws: BatchBuildError.self) {
            try builder.buildModeSwitch(skill: skill, to: .link, report: report)
        }
    }

    @Test("A link into another manager's store relinks to the shared store")
    func foreignLinkRelinks() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(
            ".other-store/tool/SKILL.md",
            contents: OwnershipBuilders.skillMD("tool", variant: "Old."))
        try home.symlink(".claude/skills/tool", to: home.path + "/.other-store/tool")
        let report = try OwnershipBuilders.scan(home: home)
        let skill = try #require(report.skills.first { $0.name == "tool" })
        let batch = try Support.makeBuilder().buildModeSwitch(
            skill: skill, to: .link, report: report)
        let command = try #require(batch.commands.only)
        #expect(command.argv[1...2] == ["relink", home.path + "/.claude/skills/tool"])
        #expect(!command.dangerFlags.contains(.discardsLocalChanges))
    }

    // MARK: - adoption

    @Test("Vercel adoption installs the source for every host holding the orphan")
    func vercelAdoption() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(
            ".claude/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))
        let report = try OwnershipBuilders.scan(home: home)
        let findingID = try Support.findingID(report, "files-without-lock", "orphan")
        let batch = try Support.build(
            report, [Support.decide(findingID, .adopt, .adoptVercel(source: "owner/repo"))])
        #expect(
            batch.commands.only?.argv == [
                "npx", "skills", "add", "owner/repo", "--skill", "orphan", "-a", "claude-code",
                "-g", "-y"
            ])
    }

    @Test("Decisions files accept relink and a Vercel adoption source")
    func decisionsVocabulary() throws {
        let json =
            #"{"a": {"action": "relink"}, "b": {"action": "adopt", "choice": {"source": "o/r"}}}"#
        let entries = try DecisionsFile.parse(Data(json.utf8)).get()
        #expect(
            entries == [
                Support.decide("a", .relink),
                Support.decide("b", .adopt, .adoptVercel(source: "o/r"))
            ])
    }
}

/// The direct file operations themselves, on a real tree.
@Suite("File operations")
struct FileOperationTests {
    @Test("relink, materialize, and delete-link change placements and keep content")
    func operations() throws {
        let tree = try TempTree()
        let store = try tree.file("store/tool/SKILL.md", contents: "shared")
        let storeDir = URL(fileURLWithPath: store).deletingLastPathComponent().path
        try tree.file("host/tool/SKILL.md", contents: "local")
        let host = tree.path + "/host/tool"
        let probe = DefaultFileSystemProbe()

        try FileOperation.relink(path: host, target: storeDir).perform()
        #expect(probe.entryKind(atPath: host) == .symlink(target: storeDir))

        try FileOperation.materialize(host).perform()
        #expect(probe.entryKind(atPath: host) == .directory)
        #expect(try String(contentsOfFile: host + "/SKILL.md", encoding: .utf8) == "shared")
        #expect(FileManager.default.fileExists(atPath: store))

        #expect(throws: FileOperationError.self) { try FileOperation.deleteLink(host).perform() }
        let dead = try tree.symlink("host/dead", to: "/nonexistent")
        try FileOperation.deleteLink(dead).perform()
        #expect(probe.entryKind(atPath: dead) == nil)
        try FileOperation.deleteLink(dead).perform()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: tree.path + "/host") == ["tool"])
    }

    @Test("Unknown verbs and wrong arity never parse")
    func parsing() {
        #expect(FileOperation(argv: ["sukiru-fileop", "chmod", "/x"]) == nil)
        #expect(FileOperation(argv: ["sukiru-fileop", "relink", "/x"]) == nil)
        #expect(FileOperation(argv: ["rm", "delete-link", "/x"]) == nil)
        let relink = FileOperation.relink(path: "/a", target: "/b")
        #expect(FileOperation(argv: relink.argv) == relink)
    }
}
