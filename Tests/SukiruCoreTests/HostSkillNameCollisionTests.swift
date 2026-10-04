import Foundation
import Testing

@testable import SukiruCore

@Suite("Host skill name collisions")
struct HostSkillNameCollisionTests {
    @Test("Droid reports shared and personal entries even when they resolve to one directory")
    func droidAliases() throws {
        let home = try TempTree()
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".factory/skills/tool", to: "../../.agents/skills/tool")

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(report.findings.first { $0.ruleID == "host-name-collision" })
        #expect(finding.skillName == "tool")
        #expect(finding.severity == .warning)
        #expect(ProblemKind.of(finding).isProblem)
        #expect(ProblemKind.oneClickFix(for: finding) == nil)
        #expect(finding.evidence.contains { $0.kind == "hostID" && $0.detail == "droid" })
        #expect(finding.evidence.filter { $0.kind == "memberPath" }.count == 2)
    }

    @Test("OpenCode checks Claude-compatible and shared entries without requiring its own copy")
    func openCodeCompatibilityRoots() throws {
        let home = try TempTree()
        try home.dir(".config/opencode")
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".claude/skills/tool", to: "../../.agents/skills/tool")

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(report.findings.first { $0.ruleID == "host-name-collision" })
        #expect(finding.evidence.contains { $0.kind == "hostID" && $0.detail == "opencode" })
    }

    @Test("Any host reports two names within its own skills root, including aliases")
    func sameHostDuplicates() throws {
        let home = try TempTree()
        try home.file(".hermes/skills/first/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".hermes/skills/second", to: "first")

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(report.findings.first { $0.ruleID == "host-name-collision" })
        #expect(finding.evidence.contains { $0.kind == "hostID" && $0.detail == "hermes-agent" })
    }

    @Test("Shared links for separate hosts stay informational")
    func separateHosts() throws {
        let home = try TempTree()
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".claude/skills/tool", to: "../../.agents/skills/tool")
        try home.symlink(".cursor/skills/tool", to: "../../.agents/skills/tool")

        let report = try OwnershipBuilders.scan(home: home)
        #expect(!report.findings.contains { $0.ruleID == "host-name-collision" })
    }

    @Test("An absent compatibility-reading host does not turn project sharing into a conflict")
    func absentProjectHost() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.symlink(".claude/skills/tool", to: "../../.agents/skills/tool")

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        #expect(!report.findings.contains { $0.ruleID == "host-name-collision" })
    }

    @Test("Claude Code coalesces same-target aliases within its own root")
    func claudeAliases() throws {
        let home = try TempTree()
        try home.file(".claude/skills/first/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".claude/skills/second", to: "first")

        let report = try OwnershipBuilders.scan(home: home)
        #expect(!report.findings.contains { $0.ruleID == "host-name-collision" })
    }

    @Test("Same-name physical entries collide even when their contents match")
    func identicalDirectories() throws {
        let home = try TempTree()
        try home.file(".cursor/skills/first/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.file(".cursor/skills/second/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))

        let report = try OwnershipBuilders.scan(home: home)
        let finding = try #require(report.findings.first { $0.ruleID == "host-name-collision" })
        #expect(finding.evidence.contains { $0.kind == "hostID" && $0.detail == "cursor" })
    }

    @Test("A broken link is not a second loadable definition")
    func brokenLink() throws {
        let home = try TempTree()
        try home.file(".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try home.symlink(".factory/skills/tool", to: "missing")

        let report = try OwnershipBuilders.scan(home: home)
        #expect(!report.findings.contains { $0.ruleID == "host-name-collision" })
        #expect(report.findings.contains { $0.ruleID == "broken-symlink" })
    }

    @Test("User and project definitions do not collide across precedence levels")
    func separateScopes() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".factory/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        #expect(!report.findings.contains { $0.ruleID == "host-name-collision" })
    }

    @Test("Project Droid compatibility roots also report aliases")
    func projectAliases() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file(
            ".agents/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.symlink(".factory/skills/tool", to: "../../.agents/skills/tool")

        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let finding = try #require(report.findings.first { $0.ruleID == "host-name-collision" })
        #expect(finding.workspaceID == "project:\(project.path)")
    }
}
