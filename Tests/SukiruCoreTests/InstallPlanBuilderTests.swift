import Foundation
import Testing

@testable import SukiruCore

/// The install-plan builder: search result + installer +
/// target → a reviewable Command Batch whose command is exactly one
/// official-CLI invocation (npx skills add / gh skill install), whose
/// finding ref carries the target ownership bucket, and whose refusal
/// vocabulary covers sources a batch cannot honestly be derived from.
@Suite("Install plan builder")
struct InstallPlanBuilderTests {
    private let result = SkillSearchResult(
        name: "stale-docs",
        repo: "SectionTN/stale-docs",
        path: "skills/stale-docs/SKILL.md",
        description: nil,
        installs: nil,
        stars: 3,
        backend: .github)

    // MARK: - vercel (npx skills add)

    @Test("vercel user scope: npx skills add -g")
    func vercelUserScope() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .vercel, target: .user)
        #expect(batch.status == .proposed)
        #expect(batch.snapshotID == nil)
        #expect(batch.commands.count == 1)
        let command = batch.commands[0]
        #expect(
            command.argv == [
                "npx", "skills", "add", "SectionTN/stale-docs", "-s", "stale-docs", "-g", "-y"
            ])
        #expect(command.owningCLI == .vercel)
        #expect(command.workingDirectory == nil)
        #expect(batch.findingRefs.map(\.workspaceID) == ["user"])
        #expect(batch.findingRefs.first?.ruleID == "new-install")
        #expect(batch.findingRefs.first?.skillName == "stale-docs")
    }

    @Test("vercel project scope: npx skills add -p with cwd = root")
    func vercelProjectScope() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .vercel, target: .project(root: "/tmp/proj"))
        let command = batch.commands[0]
        #expect(
            command.argv == [
                "npx", "skills", "add", "SectionTN/stale-docs", "-s", "stale-docs", "-p", "-y"
            ])
        #expect(command.workingDirectory == "/tmp/proj")
        #expect(batch.findingRefs.map(\.workspaceID) == ["project:/tmp/proj"])
    }

    // MARK: - github (gh skill install)

    @Test("github user scope: gh skill install --agent --scope user")
    func githubUserScope() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .github, target: .user, ghAgent: "codex")
        let command = batch.commands[0]
        #expect(
            command.argv == [
                "gh", "skill", "install", "SectionTN/stale-docs", "stale-docs",
                "--agent", "codex", "--scope", "user", "-f"
            ])
        #expect(command.owningCLI == .github)
        #expect(command.workingDirectory == nil)
    }

    @Test("github project scope: cwd = root, scope project")
    func githubProjectScope() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .github, target: .project(root: "/tmp/proj"),
            ghAgent: "codex")
        let command = batch.commands[0]
        #expect(
            command.argv == [
                "gh", "skill", "install", "SectionTN/stale-docs", "stale-docs",
                "--agent", "codex", "--scope", "project", "-f"
            ])
        #expect(command.workingDirectory == "/tmp/proj")
    }

    @Test("github --pin appends the pin ref")
    func githubPin() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .github, target: .user,
            ghAgent: "codex", ghPinRef: "v1.2.0")
        let command = batch.commands[0]
        #expect(
            command.argv == [
                "gh", "skill", "install", "SectionTN/stale-docs", "stale-docs",
                "--agent", "codex", "--scope", "user", "-f", "--pin", "v1.2.0"
            ])
        #expect(command.consequence?.contains("Pinned to v1.2.0") == true)
    }

    @Test("github without an agent is refused")
    func githubWithoutAgent() {
        #expect(throws: InstallPlanError.self) {
            _ = try InstallPlanBuilder().build(
                result: result, installer: .github, target: .user, ghAgent: nil)
        }
    }

    // MARK: - refusals

    @Test("repo-less result is refused for both installers")
    func repoLessResultRefused() {
        let repoLess = SkillSearchResult(
            name: "x", repo: nil, path: nil, description: nil,
            installs: nil, stars: nil, backend: .skillsDotSh)
        #expect(throws: InstallPlanError.self) {
            _ = try InstallPlanBuilder().build(
                result: repoLess, installer: .vercel, target: .user)
        }
        #expect(throws: InstallPlanError.self) {
            _ = try InstallPlanBuilder().build(
                result: repoLess, installer: .github, target: .user, ghAgent: "codex")
        }
    }

    @Test("non-owner/repo source is refused with a named message")
    func malformedRepoRefused() {
        let bad = SkillSearchResult(
            name: "x", repo: "https://github.com/owner/repo", path: nil,
            description: nil, installs: 1, stars: nil, backend: .skillsDotSh)
        do {
            _ = try InstallPlanBuilder().build(
                result: bad, installer: .vercel, target: .user)
            Issue.record("expected a malformed-repo refusal")
        } catch let error as InstallPlanError {
            #expect(
                error == .malformedRepo("https://github.com/owner/repo")
                    || error.message.contains("not an owner/repo slug"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("empty skill name is refused")
    func emptyNameRefused() {
        let empty = SkillSearchResult(
            name: "", repo: "owner/repo", path: nil, description: nil,
            installs: nil, stars: nil, backend: .skillsDotSh)
        #expect(throws: InstallPlanError.self) {
            _ = try InstallPlanBuilder().build(
                result: empty, installer: .vercel, target: .user)
        }
    }

    // MARK: - owner/repo validation

    @Test("owner/repo acceptance")
    func ownerRepoValidation() {
        #expect(InstallPlanBuilder.isOwnerRepo("owner/repo"))
        #expect(InstallPlanBuilder.isOwnerRepo("a-b.c/Repo_1"))
        #expect(!InstallPlanBuilder.isOwnerRepo("owner"))
        #expect(!InstallPlanBuilder.isOwnerRepo("a/b/c"))
        #expect(!InstallPlanBuilder.isOwnerRepo("owner/"))
        #expect(!InstallPlanBuilder.isOwnerRepo("/repo"))
        #expect(!InstallPlanBuilder.isOwnerRepo("owner/repo path"))
    }

    // MARK: - batch wire integrity

    @Test("the install batch round-trips through its deterministic JSON")
    func batchJSONRoundTrip() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .vercel, target: .user)
        let data = try batch.jsonData()
        let decoded = try JSONDecoder().decode(CommandBatch.self, from: data)
        #expect(decoded == batch)
        #expect(decoded.decisions.isEmpty)
        #expect(decoded.snapshotID == nil)
        #expect(decoded.status == .proposed)
        #expect(CommandBatch.allowsTransition(from: decoded.status, to: .reviewed))
    }

    @Test("installer consequence vocabulary covered by the owning CLI")
    func owningCLIMapping() {
        #expect(InstallerChoice.vercel.owningCLI == .vercel)
        #expect(InstallerChoice.github.owningCLI == .github)
        #expect(InstallerChoice.vercel.executable == "npx")
        #expect(InstallerChoice.github.executable == "gh")
    }
}
