import Foundation
import Testing

@testable import SukiruCore

@Suite("pnpm package-qualified identity")
struct PnpmIdentityTests {
    @Test("Two packages retain their own identities and aliases despite one declared name")
    func sameDeclaredName() throws {
        let fixture = try PnpmFixture()
        try addPackage(to: fixture, package: "@other/guide", version: "2.0.0", host: ".claude")
        let report = try fixture.scan()
        #expect(report.skills.count == 2)
        #expect(report.skills.allSatisfy { $0.ownership == .pnpm && !$0.ambiguous })
        #expect(Set(report.skills.map(\.name)) == ["original-guide"])
        #expect(
            Set(report.skills.compactMap(\.packageQualifiedName)) == [
                "pnpm-@sukiru+fixture-skills-guide", "pnpm-@other+guide-guide"
            ])
        #expect(
            report.skills.first { $0.packageQualifiedName == "pnpm-@sukiru+fixture-skills-guide" }?
                .placements.count == 2)
        let collision = try #require(
            report.findings.first { $0.ruleID == HostNameCollisionRule.ruleID })
        #expect(HostNameCollisionRule.subtype(of: collision) == .distinct)
        #expect(collision.evidence.contains(Evidence(kind: "hostID", detail: "claude-code")))
        #expect(!report.findings.contains { $0.ruleID == "ambiguous-name" })
        #expect(try report.jsonData() == fixture.scan().jsonData())
    }

    @Test("Equal declared names in separate host roots do not invent loading conflicts")
    func separateHosts() throws {
        let fixture = try PnpmFixture()
        try addPackage(to: fixture, package: "@other/guide", version: "2.0.0", host: ".continue")
        let report = try fixture.scan()
        #expect(report.skills.filter { $0.ownership == .pnpm }.count == 2)
        #expect(report.findings.isEmpty)
    }

    @Test("Unrelated GitHub and pnpm sources remain independently owned")
    func githubSameName() throws {
        let fixture = try PnpmFixture()
        try fixture.tree.file(
            "project/.agents/skills/original-guide/SKILL.md",
            contents: OwnershipBuilders.ghSkillMD("original-guide", repo: "example/guide"))
        let report = try fixture.scan()
        #expect(report.skills.filter { $0.ownership == .pnpm }.count == 1)
        #expect(report.skills.filter { $0.ownership == .github }.count == 1)
        #expect(
            !report.findings.contains {
                $0.ruleID == "double-booked" || $0.ruleID == "pnpm-owner-conflict"
            })
    }

    @Test("A physical competing claim stays a blocked ownership conflict")
    func physicalClaimConflict() throws {
        let fixture = try PnpmFixture()
        let identity = (fixture.paths[0] as NSString).lastPathComponent
        try fixture.tree.file(
            "project/skills-lock.json", contents: OwnershipBuilders.projectLock(identity))
        let report = try fixture.scan()
        let skill = try #require(report.skills.first)
        #expect(skill.isPnpmReadOnly && skill.ownership == .ownerless)
        let finding = try #require(report.findings.first { $0.ruleID == "pnpm-owner-conflict" })
        #expect(ProblemKind.of(finding) == .ownerConflict)
        #expect(
            finding.evidence.contains(Evidence(kind: "placementPath", detail: fixture.paths[0])))
        #expect(
            CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .uninstall,
                capabilities: nil, report: report) == .pnpmManaged)
    }

    @Test("The package-qualified selector reaches the read-only refusal in CLI")
    func cliSelectsQualifiedName() throws {
        let fixture = try PnpmFixture()
        let environment = CLIRunner.fixtureEnvironment(
            home: fixture.tree.path + "/home", roots: [fixture.root])
        let identity = (fixture.paths[0] as NSString).lastPathComponent
        let result = try CLIRunner.run(
            ["skills", "uninstall", identity, "--scope", "project", "--dry-run"],
            environment: environment)
        #expect(result.exitCode == 1)
        #expect(String(bytes: result.stderr, encoding: .utf8)?.contains("pnpm") == true)
        #expect(result.stdout.isEmpty)
    }

    @Test("A custom native skills directory is scanned without claiming a compatible host")
    func customTarget() throws {
        let fixture = try PnpmFixture()
        let path = ".special/agent-skills/" + (fixture.paths[0] as NSString).lastPathComponent
        try fixture.tree.symlink("project/" + path, to: fixture.target)
        try appendRecord(path, fixture: fixture)
        try fixture.tree.file(
            "project/pnpm-workspace.yaml",
            contents: "skills:\n  dirs:\n    - .special/agent-skills\n")
        let report = try fixture.scan()
        let skill = try #require(report.skills.first)
        #expect(skill.ownership == .pnpm)
        #expect(skill.placements.contains { $0.path == fixture.root + "/" + path })
        #expect(report.workspaces.contains { $0.id.contains("#pnpm:") })
        #expect(!report.findings.contains { $0.ruleID == HostNameCollisionRule.ruleID })
    }

    @Test("Workspace root links verify through direct importer dependencies")
    func workspaceImporters() throws {
        let fixture = try PnpmFixture()
        try fixture.tree.file("project/package.json", contents: #"{"private":true}"#)
        try FileManager.default.removeItem(
            atPath: fixture.root + "/node_modules/@sukiru/fixture-skills")
        for importer in ["apps/a", "apps/b"] {
            try fixture.tree.file(
                "project/" + importer + "/package.json",
                contents:
                    #"{"dependencies":{"@sukiru/fixture-skills":"file:../../../fixture.tgz"}}"#)
            try fixture.tree.symlink(
                "project/" + importer + "/node_modules/@sukiru/fixture-skills",
                to: URL(fileURLWithPath: fixture.target).deletingLastPathComponent()
                    .deletingLastPathComponent().path
            )
        }
        try fixture.tree.file(
            "project/pnpm-lock.yaml",
            contents:
                "lockfileVersion: '9.0'\nimporters:\n  .: {}\n  apps/a: {}\n  apps/b: {}\n")
        let report = try fixture.scan()
        #expect(report.skills.first?.ownership == .pnpm)
        #expect(
            report.skills.first?.provenance.pnpm?.first?.dependency == "file:../../../fixture.tgz")
        #expect(report.issues.isEmpty)
    }

    private func addPackage(
        to fixture: PnpmFixture, package: String, version: String, host: String
    ) throws {
        let qualified = package.replacingOccurrences(of: "/", with: "+")
        let base = "node_modules/.pnpm/" + qualified + "@" + version + "/node_modules/" + package
        try fixture.tree.file(
            "project/" + base + "/package.json",
            contents:
                "{\"name\":\"\(package)\",\"version\":\"\(version)\"}")
        try fixture.tree.file(
            "project/" + base + "/skills/guide/SKILL.md",
            contents:
                OwnershipBuilders.skillMD("original-guide", variant: "Another package"))
        try fixture.tree.symlink("project/node_modules/" + package, to: fixture.root + "/" + base)
        var manifest = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf:
                        URL(fileURLWithPath: fixture.root + "/package.json"))) as? [String: Any])
        var dependencies = try #require(manifest["dependencies"] as? [String: String])
        dependencies[package] = version
        manifest["dependencies"] = dependencies
        try JSONSerialization.data(withJSONObject: manifest).write(
            to:
                URL(fileURLWithPath: fixture.root + "/package.json"))
        let path = host + "/skills/pnpm-" + qualified + "-guide"
        try fixture.tree.symlink("project/" + path, to: fixture.root + "/" + base + "/skills/guide")
        try appendRecord(path, fixture: fixture)
    }

    private func appendRecord(_ path: String, fixture: PnpmFixture) throws {
        var metadata = try #require(
            JSONSerialization.jsonObject(with: Data(fixture.metadata().utf8))
                as? [String: Any])
        var links = try #require(metadata["linkedSkills"] as? [String])
        links.append(path)
        metadata["linkedSkills"] = links
        try JSONSerialization.data(withJSONObject: metadata).write(
            to:
                URL(fileURLWithPath: fixture.root + "/node_modules/.modules.yaml"))
    }
}
