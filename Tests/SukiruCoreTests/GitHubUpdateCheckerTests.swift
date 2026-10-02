import Foundation
import Testing

@testable import SukiruCore

/// Checking GitHub-ledger skills for updates through
/// `gh skill update --dry-run`. The outputs are real, captured piped from
/// gh 2.102.0 against `anthropics/skills` (stdout and stderr separately).
@Suite("GitHub update checker")
struct GitHubUpdateCheckerTests {
    private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
        var calls: [[String]] = []
        let respond: ([String]) -> ProcessOutcome?

        init(_ respond: @escaping ([String]) -> ProcessOutcome?) {
            self.respond = respond
        }

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            calls.append([executable] + arguments)
            return respond(arguments)
        }
    }

    /// `gh skill update --dry-run brand-guidelines xlsx --dir <dir>`: one
    /// update, one pinned skill (the notice and summary are on stderr).
    private let updateStdout = """
          • brand-guidelines (anthropics/skills) 4f2a9c1e > 1dc8bd35 [main]

        """
    private let updateStderr = """
        ⊘ xlsx is pinned to 1ed29a03dc852d30fa6ef2ca53a67dc2c2c2c563 (skipped)

        1 update(s) available:


        """
    /// `--force --dry-run`: an up-to-date skill listed as a reinstall.
    private let reinstallStdout = "  • xlsx (anthropics/skills) fe6471cc (reinstall) [main]\n"
    /// gh abbreviates a malformed local SHA to nothing.
    private let blankOldStdout = "  • brand-guidelines (anthropics/skills)  > 1dc8bd35 [main]\n"
    private let upToDateStderr = """
        ! xlsx has no GitHub metadata. Run `gh skill update xlsx` interactively to add metadata, \
        or reinstall to enable updates
        All skills are up to date.

        """

    @Test("Update rows parse to the name, upstream tree, and ref")
    func parsesUpdateRows() {
        #expect(
            GitHubUpdateChecker.parseDryRun(updateStdout) == [
                .init(name: "brand-guidelines", tree: "1dc8bd35", ref: "main")
            ])
        #expect(
            GitHubUpdateChecker.parseDryRun(reinstallStdout) == [
                .init(name: "xlsx", tree: "fe6471cc", ref: "main")
            ])
        #expect(
            GitHubUpdateChecker.parseDryRun(blankOldStdout) == [
                .init(name: "brand-guidelines", tree: "1dc8bd35", ref: "main")
            ])
    }

    @Test("Notices, summaries, and colored output are handled")
    func ignoresNotices() {
        #expect(GitHubUpdateChecker.parseDryRun(updateStderr).isEmpty)
        #expect(GitHubUpdateChecker.parseDryRun(upToDateStderr).isEmpty)
        #expect(GitHubUpdateChecker.parseDryRun("").isEmpty)
        let colored =
            "  \u{1B}[0;36m•\u{1B}[0m g (o/r) \u{1B}[0;90mabc12345\u{1B}[0m > def67890 [v2]\n"
        #expect(
            GitHubUpdateChecker.parseDryRun(colored) == [
                .init(name: "g", tree: "def67890", ref: "v2")
            ])
    }

    @Test("One dry run per skills folder, mapped back to GitHub-ledger skills only")
    func checksPerFolder() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock(["v"]))
        try home.file(".agents/skills/v/SKILL.md", contents: OwnershipBuilders.skillMD("v"))
        try project.file(
            ".claude/skills/brand-guidelines/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("brand-guidelines", repo: "anthropics/skills"))
        try project.file(
            ".claude/skills/xlsx/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("xlsx", repo: "anthropics/skills"))
        try project.file(
            ".agents/skills/other/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("other", repo: "o/r"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let claudeDir = project.path + "/.claude/skills"
        let agentsDir = project.path + "/.agents/skills"
        let stdout = updateStdout
        let stderr = updateStderr
        let runner = ScriptedRunner { arguments in
            arguments.last == claudeDir
                ? ProcessOutcome(exitCode: 0, stdout: stdout, stderr: stderr)
                : ProcessOutcome(
                    exitCode: 1, stdout: "", stderr: "none of the specified skills are installed\n")
        }
        let result = GitHubUpdateChecker(runner: runner).check(report.skills)

        #expect(
            runner.calls.sorted { $0.last ?? "" < $1.last ?? "" } == [
                ["gh", "skill", "update", "--dry-run", "other", "--dir", agentsDir],
                [
                    "gh", "skill", "update", "--dry-run", "brand-guidelines", "xlsx", "--dir",
                    claudeDir
                ]
            ])
        let found = try #require(result.updates.only)
        #expect(found.skill.name == "brand-guidelines")
        #expect(found.update.availableTree == "1dc8bd35")
        #expect(found.update.ref == "main")
        #expect(found.update.installedTreeSha == found.skill.provenance.github?.treeSha)
        #expect(result.failures == ["\(agentsDir): none of the specified skills are installed"])
    }

    @Test("Nothing to check runs no gh at all")
    func nothingToCheck() throws {
        let home = try TempTree()
        try home.file(".claude/settings.json", contents: "{}")
        try home.file(".claude/skills/stray/SKILL.md", contents: OwnershipBuilders.skillMD("stray"))
        let report = try OwnershipBuilders.scan(home: home)
        let runner = ScriptedRunner { _ in nil }
        let result = GitHubUpdateChecker(runner: runner).check(report.skills)
        #expect(runner.calls.isEmpty)
        #expect(result.updates.isEmpty && result.failures.isEmpty)
        #expect(GitHubUpdateChecker.checkable(report.skills).isEmpty)
    }
}
