import Foundation
import Testing

@testable import SukiruCore

/// Legacy host dirs (`legacyProjectSkillDirs` / `legacyGlobalSkillDirs`):
/// dirs the CLI no longer installs into are still scanned, but no command
/// ever targets them through their host.
@Suite("Legacy host dirs")
struct LegacyHostDirTests {
    private typealias Support = BatchTestSupport

    @Test("Skills in legacy host dirs are scanned in both scopes")
    func legacyDirsScanned() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(
            ".kilocode/skills/kilo-old/SKILL.md", contents: OwnershipBuilders.skillMD("kilo-old"))
        try project.file(
            ".factory/skills/droid-old/SKILL.md", contents: OwnershipBuilders.skillMD("droid-old"))

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let kilo = try #require(report.skills.first { $0.name == "kilo-old" })
        #expect(kilo.scope == .user)
        #expect(kilo.placements.map(\.path) == ["\(home.path)/.kilocode/skills/kilo-old"])
        let droid = try #require(report.skills.first { $0.name == "droid-old" })
        #expect(droid.scope == .project)
        #expect(droid.placements.map(\.path) == ["\(project.path)/.factory/skills/droid-old"])
        // Their first components stay known containers inside skills roots.
        #expect(ContainerIgnoreList.knownContainerNames.isSuperset(of: [".factory", ".kilocode"]))
    }

    @Test("Repairs never target a copy in a legacy folder through its host")
    func missingSharedCopyLegacyCopy() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["kept"]))
        try home.file(".other-store/kept/SKILL.md", contents: OwnershipBuilders.skillMD("kept"))
        try home.symlink(".claude/skills/kept", to: home.path + "/.other-store/kept")
        try home.symlink(".kilocode/skills/kept", to: home.path + "/.other-store/kept")
        let report = try OwnershipBuilders.scan(home: home)
        let findingID = try Support.findingID(report, MissingSharedCopyRule.ruleID, "kept")
        let reachable = [home.path + "/.claude/skills/kept"]
        let reinstall = try #require(
            try Support.build(report, [Support.decide(findingID, .update)]).commands.only)
        #expect(!reinstall.argv.contains("kilo"))
        #expect(reinstall.consequenceKind == .restoresSharedCopy(replacing: reachable))
        let remove = try #require(
            try Support.build(report, [Support.decide(findingID, .cleanup)]).commands.only)
        #expect(remove.consequenceKind == .removesLockedSkill(skill: "kept", deleting: reachable))
    }

    @Test("Vercel adoption refuses an orphan held in a legacy folder")
    func vercelAdoptionRefusesLegacy() throws {
        let home = try TempTree()
        try home.file(
            ".kilocode/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))
        let report = try OwnershipBuilders.scan(home: home)
        let findingID = try Support.findingID(report, "files-without-lock", "orphan")
        #expect(throws: (any Error).self) {
            try Support.build(
                report, [Support.decide(findingID, .adopt, .adoptVercel(source: "owner/repo"))])
        }
    }
}
