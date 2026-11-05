import Foundation
import Testing

@testable import SukiruCore

/// User-initiated deployment of a global Skill into an installed agent
/// (issue #82): which agents can receive a link, the one-command batch, and
/// the refusals that keep an existing entry safe.
@Suite("Host links")
struct HostLinkPlannerTests {
    private static func home() throws -> TempTree {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["tool"]))
        try home.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        return home
    }

    private static func planner(_ home: TempTree) -> HostLinkPlanner {
        HostLinkPlanner(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home.path])),
            idProvider: { "batch-1" },
            dateProvider: { Date(timeIntervalSince1970: 0) })
    }

    private static func skill(in home: TempTree) throws -> Skill {
        let report = try OwnershipBuilders.scan(home: home)
        return try #require(report.skills.first { $0.name == "tool" })
    }

    @Test("A detected agent with its own global folder can receive the link")
    func detectedSeparateFolder() throws {
        let home = try Self.home()
        try home.file(".gemini/antigravity-cli/state.json", contents: "{}")
        let targets = Self.planner(home).targets(for: try Self.skill(in: home))
        let target = try #require(targets.first { $0.hostIDs.contains("antigravity-cli") })
        #expect(target.hostIDs == ["antigravity-cli"])
        #expect(target.linkPath == home.path + "/.gemini/config/skills/tool")
        #expect(target.storePath == home.path + "/.agents/skills/tool")
    }

    @Test("Agents sharing one global folder collapse into one target")
    func sharedFolderCollapses() throws {
        let home = try Self.home()
        try home.file(".gemini/antigravity/state.json", contents: "{}")
        try home.file(".gemini/antigravity-cli/state.json", contents: "{}")
        let targets = Self.planner(home).targets(for: try Self.skill(in: home))
        let shared = try #require(targets.first { $0.hostIDs.contains("antigravity") })
        #expect(shared.hostIDs == ["antigravity", "antigravity-cli"])
        #expect(shared.displayName == "Antigravity, Antigravity CLI")
        #expect(shared.hostID == "antigravity")
    }

    @Test("An agent that already holds the name is not offered")
    func existingEntryIsNotOffered() throws {
        let home = try Self.home()
        try home.file(".gemini/antigravity/state.json", contents: "{}")
        try home.symlink(
            ".gemini/config/skills/tool", to: "../../../.agents/skills/tool")
        let targets = Self.planner(home).targets(for: try Self.skill(in: home))
        #expect(!targets.contains { $0.hostIDs.contains("antigravity") })
        #expect(!targets.contains { $0.hostIDs.contains("antigravity-cli") })
    }

    @Test("CLI spray residue is not an installed agent")
    func leftoverFolderIsNotOffered() throws {
        let home = try Self.home()
        try home.dir(".kilo/skills")
        let targets = Self.planner(home).targets(for: try Self.skill(in: home))
        #expect(!targets.contains { $0.hostIDs.contains("kilo") })
    }

    @Test("Project Skills are not deployed to global folders")
    func projectSkillHasNoTargets() throws {
        let home = try Self.home()
        try home.file(".gemini/antigravity-cli/state.json", contents: "{}")
        let project = try TempTree()
        try project.file(
            ".agents/skills/local/SKILL.md", contents: OwnershipBuilders.skillMD("local"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let local = try #require(report.skills.first { $0.name == "local" })
        #expect(Self.planner(home).targets(for: local).isEmpty)
    }

    @Test("The batch is one snapshot-protected file operation")
    func batchBuildsOneLink() throws {
        let home = try Self.home()
        try home.file(".gemini/antigravity-cli/state.json", contents: "{}")
        let skill = try Self.skill(in: home)
        let batch = try Self.planner(home).batch(skill: skill, host: "antigravity-cli")
        #expect(batch.commands.count == 1)
        #expect(
            batch.commands[0].argv == [
                "sukiru-fileop", "link", home.path + "/.gemini/config/skills/tool",
                home.path + "/.agents/skills/tool"
            ])
        #expect(batch.commands[0].dangerFlags == [.directFileOperation])
        #expect(batch.findingRefs.map(\.workspaceID) == ["user"])
        #expect(batch.findingRefs.map(\.skillName) == ["tool"])
    }

    @Test("A host that is not a target refuses with a reason")
    func batchRefusesNonTarget() throws {
        let home = try Self.home()
        try home.file(".gemini/antigravity-cli/state.json", contents: "{}")
        try home.symlink(
            ".gemini/config/skills/tool", to: "../../../.agents/skills/tool")
        let skill = try Self.skill(in: home)
        #expect(throws: BatchBuildError.self) {
            try Self.planner(home).batch(skill: skill, host: "antigravity-cli")
        }
        #expect(throws: BatchBuildError.self) {
            try Self.planner(home).batch(skill: skill, host: "not-an-agent")
        }
    }
}
