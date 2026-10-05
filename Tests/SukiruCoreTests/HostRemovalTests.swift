import Foundation
import Testing

@testable import SukiruCore

@Suite("Remove Skills from Agent")
struct HostRemovalTests {
    @Test("Only official host entries are removed; copies and other owners are explained")
    func explicitNames() throws {
        let home = try TempTree()
        try home.file(
            ".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a", "b"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.file(".agents/skills/b/SKILL.md", contents: OwnershipBuilders.skillMD("b"))
        try home.symlink(".claude/skills/a", to: home.path + "/.agents/skills/a")
        try home.file(".claude/skills/b/SKILL.md", contents: OwnershipBuilders.skillMD("b"))
        try home.file(".claude/skills/own/SKILL.md", contents: OwnershipBuilders.skillMD("own"))
        try home.file(
            ".claude/skills/gh/SKILL.md", contents: OwnershipBuilders.ghSkillMD("gh", repo: "o/r"))
        try home.dir(".codex")
        let report = try OwnershipBuilders.scan(home: home)
        let context = Self.context(home, report: report)
        let plan = try CommandBatchBuilder().planHostRemoval(
            hostID: "claude-code", bucket: "user", report: report, context: context)
        #expect(plan.removed.map(\.name) == ["a", "b"])
        #expect(plan.leftInPlace.map(\.reason) == [.githubLedger, .ownerless])
        #expect(plan.sharedCopyDeletions.isEmpty)
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: [], hostRemovals: [plan.request], hostRemovalContext: context
        )
        let batch = try #require(built.batch)
        #expect(built.skipped.isEmpty)
        #expect(
            batch.commands.only?.argv == [
                "npx", "skills", "remove", "a", "b", "-a", "claude-code", "-g", "-y"
            ])
        #expect(batch.findingRefs.only?.ruleID == "library-host-removal")
        #expect(batch.commands.only?.dangerFlags == [.dangerousDeletion])
    }

    static func context(_ home: TempTree, report: ScanReport) -> HostRemovalContext {
        HostRemovalContext(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home.path])),
            report: report,
            projectRoots: report.workspaces.filter {
                $0.kind == .project && !$0.id.contains("#")
            }.map { String($0.id.dropFirst("project:".count)) })
    }

    @Test("No other detected host predicts Shared Copy deletion and captures its ledger")
    func sharedDeletion() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.symlink(".claude/skills/a", to: home.path + "/.agents/skills/a")
        let report = try OwnershipBuilders.scan(home: home)
        let context = Self.context(home, report: report)
        let plan = try CommandBatchBuilder().planHostRemoval(
            hostID: "claude-code", bucket: "user", report: report, context: context)
        #expect(plan.sharedCopyDeletions == ["a"])
        let batch = try #require(
            CommandBatchBuilder().buildApplicable(
                report: report, decisions: [], hostRemovals: [plan.request],
                hostRemovalContext: context
            ).batch)
        #expect(batch.commands.only?.warning?.contains("from every agent") == true)
        #expect(batch.commands.only?.consequenceKind != nil)
        #expect(
            batch.commands.only?.captureRoots == [
                home.path + "/.claude/skills", home.path + "/.agents/skills",
                home.path + "/.agents/.skill-lock.json"
            ])
    }

    @Test("OpenCode retains shared and Claude-compatible discovery entries")
    func stillVisible() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.symlink(".config/opencode/skills/a", to: home.path + "/.agents/skills/a")
        try home.symlink(".claude/skills/a", to: home.path + "/.agents/skills/a")
        let report = try OwnershipBuilders.scan(home: home)
        let plan = try CommandBatchBuilder().planHostRemoval(
            hostID: "opencode", bucket: "user", report: report,
            context: Self.context(home, report: report))
        #expect(plan.removed.map(\.name) == ["a"])
        #expect(plan.sharedCopyDeletions.isEmpty)
        #expect(
            plan.stillVisible.map(\.path) == [
                home.path + "/.agents/skills/a", home.path + "/.claude/skills/a"
            ])
        #expect(plan.settingHint?.contains("permission.skill") == true)
    }

    @Test("Shared destinations cannot be cleared for one host; managed entries remain")
    func nothingRemovable() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.file(
            ".codex/skills/.system/notes/SKILL.md", contents: OwnershipBuilders.skillMD("notes"))
        let report = try OwnershipBuilders.scan(home: home)
        let context = Self.context(home, report: report)
        let builder = CommandBatchBuilder()
        let plan = try builder.planHostRemoval(
            hostID: "cline", bucket: "user", report: report, context: context)
        #expect(plan.removed.isEmpty)
        #expect(plan.leftInPlace.only?.reason == .sharedFolder)
        #expect(plan.stillVisible.map(\.name) == ["a"])
        #expect(!plan.problems.isEmpty)
        #expect(
            builder.buildApplicable(
                report: report, decisions: [], hostRemovals: [plan.request],
                hostRemovalContext: context
            ).batch == nil)
        let managed = try builder.planHostRemoval(
            hostID: "codex", bucket: "user", report: report, context: context)
        #expect(managed.leftInPlace.only?.reason == .agentManaged)
        #expect(managed.removed.isEmpty)
        #expect(
            builder.hostRemovalCandidates(bucket: "user", report: report, context: context).map(
                \.id
            ).contains("codex"))
        #expect(
            !builder.hostRemovalCandidates(bucket: "user", report: report, context: context).map(
                \.id
            ).contains("claude-code"))
    }

    @Test("Project removal targets exactly one project root and a missing Node blocks planning")
    func projectScope() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.file("skills-lock.json", contents: OwnershipBuilders.projectLock("a"))
        try project.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try project.symlink(".claude/skills/a", to: project.path + "/.agents/skills/a")
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let context = Self.context(home, report: report)
        let builder = CommandBatchBuilder()
        let plan = try builder.planHostRemoval(
            hostID: "claude-code", bucket: "project:" + project.path, report: report,
            context: context)
        let batch = try #require(
            builder.buildApplicable(
                report: report, decisions: [], hostRemovals: [plan.request],
                hostRemovalContext: context
            ).batch)
        #expect(
            batch.commands.only?.argv == [
                "npx", "skills", "remove", "a", "-a", "claude-code", "-p", "-y"
            ])
        #expect(batch.commands.only?.workingDirectory == project.path)
        let blocked = builder.buildApplicable(
            report: report, decisions: [], hostRemovals: [plan.request],
            hostRemovalContext: context, capabilities: .pending())
        #expect(blocked.batch == nil)
        #expect(blocked.skipped.only?.contains("npx skills") == true)
    }

    @Test("Several queued host removals warn when the final consumer disappears")
    func combinedRemoval() throws {
        let home = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.symlink(".claude/skills/a", to: home.path + "/.agents/skills/a")
        try home.symlink(".gemini/skills/a", to: home.path + "/.agents/skills/a")
        let report = try OwnershipBuilders.scan(home: home)
        let context = Self.context(home, report: report)
        let builder = CommandBatchBuilder()
        let requests = try ["claude-code", "gemini-cli"].map {
            try builder.planHostRemoval(
                hostID: $0, bucket: "user", report: report, context: context
            ).request
        }
        let batch = try #require(
            builder.buildApplicable(
                report: report, decisions: [], hostRemovals: requests, hostRemovalContext: context
            ).batch)
        #expect(batch.commands.count == 2)
        #expect(batch.commands.first?.consequenceKind == nil)
        #expect(
            batch.commands.last?.warning?.contains("Also uninstalls a from every agent") == true)
    }

    @Test("XDG hosts are not detected from a same-name directory under HOME")
    func xdgDetection() throws {
        let home = try TempTree()
        try home.dir("opencode")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["a"]))
        try home.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
        try home.symlink(".claude/skills/a", to: home.path + "/.agents/skills/a")
        let report = try OwnershipBuilders.scan(home: home)
        let plan = try CommandBatchBuilder().planHostRemoval(
            hostID: "claude-code", bucket: "user", report: report,
            context: Self.context(home, report: report))
        #expect(plan.sharedCopyDeletions == ["a"])
    }

    @Test("Identical argv in two project scopes retains both commands and capture roots")
    func separateProjects() throws {
        let home = try TempTree()
        let projects = try [TempTree(), TempTree()]
        for project in projects {
            try project.file("skills-lock.json", contents: OwnershipBuilders.projectLock("a"))
            try project.file(".agents/skills/a/SKILL.md", contents: OwnershipBuilders.skillMD("a"))
            try project.symlink(".claude/skills/a", to: project.path + "/.agents/skills/a")
        }
        let report = try OwnershipBuilders.scan(home: home, projectRoots: projects)
        let context = Self.context(home, report: report)
        let builder = CommandBatchBuilder()
        let requests = try projects.map { project in
            try builder.planHostRemoval(
                hostID: "claude-code", bucket: "project:" + project.path,
                report: report, context: context
            ).request
        }
        let batch = try #require(
            builder.buildApplicable(
                report: report, decisions: [], hostRemovals: requests,
                hostRemovalContext: context
            ).batch)
        #expect(batch.commands.count == 2)
        #expect(Set(batch.commands.compactMap(\.workingDirectory)) == Set(projects.map(\.path)))
        #expect(
            Set(batch.findingRefs.map(\.workspaceID)) == Set(projects.map { "project:" + $0.path }))
    }
}
