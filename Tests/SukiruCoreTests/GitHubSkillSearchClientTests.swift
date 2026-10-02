import Foundation
import Testing

@testable import SukiruCore

/// The `gh skill search` client (github backend): parses the
/// verified `--json description,namespace,path,repo,skillName,stars` array,
/// normalizes to SkillSearchResult, and surfaces subprocess failures.
/// Offline via the stub command runner (never shells out in unit tests).
@Suite("gh skill search client")
struct GitHubSkillSearchClientTests {
    private struct StubRunner: CommandRunning {
        let outcome: ProcessOutcome?

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            outcome
        }
    }

    private let fixture = """
        [
          {
            "description": "Repairs stale docs against current source.",
            "namespace": "",
            "path": "skills/stale-docs/SKILL.md",
            "repo": "SectionTN/stale-docs",
            "skillName": "stale-docs",
            "stars": 3
          },
          {
            "description": null,
            "namespace": "team",
            "path": "skills/prune-stale-docs/SKILL.md",
            "repo": "ShaalanMarwan/skills",
            "skillName": "prune-stale-docs",
            "stars": 0
          }
        ]
        """

    @Test("parses the gh JSON array into normalized results")
    func parsesResults() async throws {
        let client = GitHubSkillSearchClient(
            runner: StubRunner(
                outcome: ProcessOutcome(
                    exitCode: 0, stdout: fixture, stderr: "")))
        let results = try await client.search(query: "stale docs")
        #expect(results.count == 2)
        let first = results[0]
        #expect(first.name == "stale-docs")
        #expect(first.repo == "SectionTN/stale-docs")
        #expect(first.path == "skills/stale-docs/SKILL.md")
        #expect(first.description == "Repairs stale docs against current source.")
        #expect(first.stars == 3)
        #expect(first.backend == .github)
        #expect(first.popularityLabel == "3★")
        #expect(first.id == "github|SectionTN/stale-docs|stale-docs")
    }

    @Test("an owner filter maps to --owner")
    func ownerFilter() async throws {
        final class RecordingRunner: CommandRunning, @unchecked Sendable {
            var arguments: [String] = []

            func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
                self.arguments = arguments
                return ProcessOutcome(exitCode: 0, stdout: "[]", stderr: "")
            }
        }
        let runner = RecordingRunner()
        _ = try await GitHubSkillSearchClient(runner: runner)
            .search(query: "react", owner: "vercel-labs", limit: 5)
        #expect(
            runner.arguments == [
                "skill", "search", "react",
                "--json", "description,namespace,path,repo,skillName,stars",
                "-L", "5", "--owner", "vercel-labs"
            ])
    }

    @Test("missing gh surfaces as a transport error")
    func missingGh() async {
        let client = GitHubSkillSearchClient(runner: StubRunner(outcome: nil))
        do {
            _ = try await client.search(query: "stale docs")
            Issue.record("expected a failure for absent gh")
        } catch let error as MarketplaceError {
            #expect(error.message == "marketplace request failed: gh executable not found")
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("non-zero exit surfaces stderr as the diagnostic")
    func nonZeroExit() async {
        let client = GitHubSkillSearchClient(
            runner: StubRunner(
                outcome: ProcessOutcome(
                    exitCode: 1, stdout: "", stderr: "authentication required")))
        do {
            _ = try await client.search(query: "stale docs")
            Issue.record("expected a failure for non-zero exit")
        } catch let error as MarketplaceError {
            #expect(error.message.contains("authentication required"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("non-zero exit with empty stderr falls back to the exit code")
    func nonZeroExitNoStderr() async {
        let client = GitHubSkillSearchClient(
            runner: StubRunner(
                outcome: ProcessOutcome(exitCode: 2, stdout: "", stderr: "  ")))
        do {
            _ = try await client.search(query: "stale docs")
            Issue.record("expected a failure for non-zero exit")
        } catch let error as MarketplaceError {
            #expect(error.message.contains("exited 2"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("malformed JSON surfaces as a marketplace error")
    func malformedJSON() async {
        let client = GitHubSkillSearchClient(
            runner: StubRunner(
                outcome: ProcessOutcome(exitCode: 0, stdout: "nope", stderr: "")))
        do {
            _ = try await client.search(query: "stale docs")
            Issue.record("expected a malformed-payload failure")
        } catch let error as MarketplaceError {
            #expect(error.message.hasPrefix("marketplace response was malformed"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }
}
