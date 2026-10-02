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
            result: result, installer: .github, target: .user,
            options: InstallOptions(ghAgent: "codex"))
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
            options: InstallOptions(ghAgent: "codex"))
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
            options: InstallOptions(ghAgent: "codex", ghPinRef: "v1.2.0"))
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
                result: result, installer: .github, target: .user,
                options: InstallOptions(ghAgent: nil))
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
                result: repoLess, installer: .github, target: .user,
                options: InstallOptions(ghAgent: "codex"))
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

    // MARK: - several skills from one repository

    @Test("vercel installs every selected skill in one add, with -a per agent")
    func vercelSeveralSkillsAndAgents() throws {
        let batch = try InstallPlanBuilder().build(
            repo: "anthropics/skills", skills: ["docx", "pdf"], installer: .vercel,
            target: .user, options: InstallOptions(vercelAgents: ["claude-code", "cursor"]))
        #expect(
            batch.commands.map(\.argv) == [
                [
                    "npx", "skills", "add", "anthropics/skills", "-s", "docx", "-s", "pdf",
                    "-a", "claude-code", "-a", "cursor", "-g", "-y"
                ]
            ])
        #expect(batch.findingRefs.map(\.skillName) == ["docx", "pdf"])
        #expect(Set(batch.findingRefs.map(\.workspaceID)) == ["user"])
    }

    @Test("vercel agents precede --copy and the project scope flag")
    func vercelAgentsWithCopyInProject() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .vercel, target: .project(root: "/tmp/proj"),
            options: InstallOptions(vercelAgents: ["codex"], copy: true))
        #expect(
            batch.commands[0].argv == [
                "npx", "skills", "add", "SectionTN/stale-docs", "-s", "stale-docs",
                "-a", "codex", "--copy", "-p", "-y"
            ])
    }

    @Test("github installs one command per skill, names passed verbatim")
    func githubSeveralSkills() throws {
        let batch = try InstallPlanBuilder().build(
            repo: "anthropics/skills", skills: ["[root] template", "pdf"], installer: .github,
            target: .user, options: InstallOptions(ghAgent: "claude-code"))
        #expect(
            batch.commands.map(\.argv) == [
                [
                    "gh", "skill", "install", "anthropics/skills", "[root] template",
                    "--agent", "claude-code", "--scope", "user", "-f"
                ],
                [
                    "gh", "skill", "install", "anthropics/skills", "pdf",
                    "--agent", "claude-code", "--scope", "user", "-f"
                ]
            ])
        #expect(batch.findingRefs.count == 2)
    }

    @Test("github ignores Vercel agents")
    func githubIgnoresVercelAgents() throws {
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .github, target: .user,
            options: InstallOptions(vercelAgents: ["cursor"], ghAgent: "codex"))
        #expect(!batch.commands[0].argv.contains("-a"))
    }

    @Test("an empty selection is refused")
    func emptySelectionRefused() {
        #expect(throws: InstallPlanError.noSkillsSelected) {
            _ = try InstallPlanBuilder().build(
                repo: "owner/repo", skills: [], installer: .vercel, target: .user)
        }
    }

    // MARK: - typed sources

    @Test("typed sources normalize to owner/repo")
    func typedSourceNormalization() throws {
        let accepted = [
            "owner/repo", "  owner/repo\n", "https://github.com/owner/repo",
            "https://github.com/owner/repo/", "https://github.com/owner/repo.git",
            "http://github.com/owner/repo", "git@github.com:owner/repo.git"
        ]
        for source in accepted {
            #expect(try InstallPlanBuilder.ownerRepo(fromSource: source) == "owner/repo")
        }
    }

    @Test("typed sources that are not GitHub repositories are refused")
    func typedSourceRefusal() {
        let refused = [
            "", "owner", "https://gitlab.com/owner/repo",
            "https://github.com/owner/repo/tree/main/skills", "owner/repo name"
        ]
        for source in refused {
            #expect(throws: InstallPlanError.self) {
                _ = try InstallPlanBuilder.ownerRepo(fromSource: source)
            }
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
