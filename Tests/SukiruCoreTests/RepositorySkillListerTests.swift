import Foundation
import Testing

@testable import SukiruCore

/// Listing a repository's skills through the installer that will install
/// them. The fixtures are trimmed real output: `npx skills add <repo> -l`
/// (skills@1.7.0, colored under `CI=1`) and piped `gh skill install <repo>`
/// (gh 2.102.0), both captured from `anthropics/skills` and
/// `vercel-labs/agent-skills`.
@Suite("Repository skill lister")
struct RepositorySkillListerTests {
    private struct StubRunner: CommandRunning {
        let outcome: ProcessOutcome?

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            outcome
        }
    }

    private final class RecordingRunner: CommandRunning, @unchecked Sendable {
        var calls: [[String]] = []

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            calls.append([executable] + arguments)
            return ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private static let esc = "\u{1B}"

    /// Grouped output (plugin titles, then `General`).
    private let vercelGrouped = """
        \(esc)[1G\(esc)[J◇  Found \(esc)[32m3\(esc)[39m skills
        \(esc)[?25h
        │
        ◇  \(esc)[1mAvailable Skills\(esc)[22m
        \(esc)[1mDocument Skills\(esc)[22m
        │
        │    \(esc)[36mdocx\(esc)[39m
        │
        │      \(esc)[2mUse this skill whenever the user wants to edit Word documents.\(esc)[22m
        │
        │    \(esc)[36mpdf\(esc)[39m
        │
        │      \(esc)[2mUse this skill whenever the user wants to do anything with PDF files.\(esc)[22m

        \(esc)[1mGeneral\(esc)[22m
        │
        │    \(esc)[36mtemplate-skill\(esc)[39m
        │
        │      \(esc)[2mReplace with description of the skill and when Claude should use it.\(esc)[22m

        │
        └  Use --skill <name> to install specific skills

        """

    /// Ungrouped output, with the clack "Tip" line above the listing.
    private let vercelFlat = """
        │  \(esc)[2mTip: use the --yes (-y) and --global (-g) flags to install without prompts.\(esc)[22m
        ◇  Source: https://github.com/vercel-labs/agent-skills.git
        ◇  Found \(esc)[32m2\(esc)[39m skills
        │
        ◇  \(esc)[1mAvailable Skills\(esc)[22m
        │
        │    \(esc)[36mvercel-composition-patterns\(esc)[39m
        │
        │      \(esc)[2mReact composition patterns that scale.\(esc)[22m
        │
        │    \(esc)[36mdeploy-to-vercel\(esc)[39m
        │
        │      \(esc)[2mDeploy applications and websites to Vercel.\(esc)[22m

        │
        └  Use --skill <name> to install specific skills

        """

    /// Piped gh rows: a convention-tagged root skill, a multi-line
    /// description, and blank separator lines.
    private let githubListing = """
        [root] template\tReplace with description of the skill and when Claude should use it.
        academy-guide\tStop and check this skill before finishing any reply.

        claude-api\tReference for the Claude API / Anthropic SDK — model ids, pricing, params.
        TRIGGER — read BEFORE opening the target file; don't skip because it "looks like a one-liner".
        SKIP only when another provider is being worked on.
        discernment-nudge\tAfter you give a substantive answer or draft that the user may act on.

        """

    @Test("npx listing: grouped skills parse in order with descriptions")
    func vercelGroupedListing() {
        let skills = RepositorySkillLister.parseVercelListing(vercelGrouped)
        #expect(skills.map(\.name) == ["docx", "pdf", "template-skill"])
        #expect(
            skills[1].description
                == "Use this skill whenever the user wants to do anything with PDF files.")
    }

    @Test("npx listing: lines before Available Skills are ignored")
    func vercelFlatListing() {
        let skills = RepositorySkillLister.parseVercelListing(vercelFlat)
        #expect(
            skills == [
                RepositorySkill(
                    name: "vercel-composition-patterns",
                    description: "React composition patterns that scale."),
                RepositorySkill(
                    name: "deploy-to-vercel",
                    description: "Deploy applications and websites to Vercel.")
            ])
    }

    @Test("npx listing: output without a listing yields no skills")
    func vercelNoListing() {
        #expect(RepositorySkillLister.parseVercelListing("◇  Source: x\n└  Done\n").isEmpty)
    }

    @Test("gh listing: names stay verbatim; continuation lines are dropped")
    func githubListingParses() {
        let skills = RepositorySkillLister.parseGitHubListing(githubListing)
        #expect(
            skills.map(\.name) == [
                "[root] template", "academy-guide", "claude-api", "discernment-nudge"
            ])
        #expect(
            skills[2].description
                == "Reference for the Claude API / Anthropic SDK — model ids, pricing, params.")
    }

    @Test("listing commands are the read-only forms of each installer")
    func listingArguments() throws {
        let runner = RecordingRunner()
        let lister = RepositorySkillLister(runner: runner)
        _ = try lister.skills(in: "owner/repo", installer: .vercel)
        _ = try lister.skills(in: "owner/repo", installer: .github)
        #expect(
            runner.calls == [
                ["npx", "--offline", "skills", "add", "owner/repo", "-l"],
                ["gh", "skill", "install", "owner/repo"]
            ])
    }

    @Test("a failed npx listing reports the CLI's failure lines from stdout")
    func vercelFailure() {
        let stdout = """
            ◇  Source: https://github.com/owner/missing.git
            ■  Failed to clone repository
            │  Authentication failed for https://github.com/owner/missing.git.
            │    - For private repos, ensure you have access
            └  Installation failed
            """
        let lister = RepositorySkillLister(
            runner: StubRunner(
                outcome: ProcessOutcome(
                    exitCode: 1, stdout: stdout, stderr: "npm notice run npx\n")))
        #expect(
            throws: MarketplaceError.transport(
                "Failed to clone repository\n"
                    + "Authentication failed for https://github.com/owner/missing.git.")
        ) {
            _ = try lister.skills(in: "owner/missing", installer: .vercel)
        }
    }

    @Test("a failed gh listing reports stderr")
    func githubFailure() {
        let stderr =
            "could not resolve version: could not determine default branch: HTTP 404: Not Found\n"
        let lister = RepositorySkillLister(
            runner: StubRunner(outcome: ProcessOutcome(exitCode: 1, stdout: "", stderr: stderr)))
        #expect(
            throws: MarketplaceError.transport(
                "could not resolve version: could not determine default branch: HTTP 404: Not Found"
            )
        ) {
            _ = try lister.skills(in: "owner/missing", installer: .github)
        }
    }

    @Test("a CLI that cannot start is a transport error")
    func missingExecutable() {
        let lister = RepositorySkillLister(runner: StubRunner(outcome: nil))
        #expect(throws: MarketplaceError.self) {
            _ = try lister.skills(in: "owner/repo", installer: .github)
        }
    }
}
