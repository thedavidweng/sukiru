import Foundation
import Testing

@testable import SukiruCore

@Suite("pnpm Health boundaries")
struct PnpmHealthTests {
    @Test("A Vercel name claim does not make readable pnpm placements fileless")
    func pnpmFilesStillExistForLockHealth() throws {
        let fixture = try PnpmFixture()
        try fixture.tree.file(
            "project/skills-lock.json", contents: OwnershipBuilders.projectLock("original-guide"))
        let before = try TreeChecksum.manifest(root: fixture.tree.path)

        let report = try fixture.scan()
        #expect(report.skills.first?.isPnpmReadOnly == true)
        #expect(report.findings.isEmpty)
        #expect(report.issues.isEmpty)
        #expect(try TreeChecksum.manifest(root: fixture.tree.path) == before)
    }

    @Test("pnpm content is not compared with an unrelated Vercel installation")
    func pnpmDoesNotDivergeFromVercel() throws {
        let fixture = try PnpmFixture()
        try addVercelCopy(to: fixture, name: "original-guide")
        try fixture.tree.dir("home/.config/opencode")

        let report = try fixture.scan()
        #expect(report.findings.allSatisfy { $0.ruleID == HostNameCollisionRule.ruleID })
        #expect(report.issues.isEmpty)
        let collision = try #require(
            report.findings.first {
                $0.ruleID == HostNameCollisionRule.ruleID
            })
        #expect(HostNameCollisionRule.subtype(of: collision) == .distinct)
        let id = try #require(
            FindingID.assignments(for: report.findings).first {
                $0.finding == collision
            }?.id)
        #expect(throws: BatchBuildError(problems: [LifecycleBlocker.pnpmManaged.message])) {
            try CommandBatchBuilder().build(
                report: report,
                decisions: [
                    DecisionEntry(
                        findingID: id, action: .arbitrate,
                        choice: .keepEntry(path: fixture.root + "/.agents/skills/original-guide"))
                ])
        }
    }

    @Test("A protected placement does not hide drift in non-pnpm copies of the same name")
    func mixedGroupRetainsRealDrift() throws {
        let fixture = try PnpmFixture()
        try addVercelCopy(to: fixture, name: "original-guide")
        let manual = fixture.root + "/.claude/skills/manual-guide"
        try fixture.tree.file(
            "project/.claude/skills/manual-guide/SKILL.md",
            contents: OwnershipBuilders.skillMD("original-guide", variant: "Edited manually."))

        let report = try fixture.scan()
        let drift = report.findings.filter { $0.ruleID == "vercel-lock-drift" }
        #expect(drift.count == 1)
        #expect(
            drift.first?.evidence.contains(Evidence(kind: "placementPath", detail: manual)) == true)
        let divergence = try #require(
            report.findings.first { $0.ruleID == "canonical-host-divergence" })
        #expect(!divergence.evidence.contains { fixture.paths.contains($0.detail) })
        #expect(divergence.evidence.contains(Evidence(kind: "hostPath", detail: manual)))
        #expect(!report.findings.contains { $0.ruleID == "lock-without-files" })
    }

    @Test(
        "Unverified dependency state stays visible and cannot be cleaned or fixed",
        arguments: ["target", "dependency", "projectManifest", "packageManifest", "nativeManifest"])
    func damagedPnpmStaysVisible(_ variant: String) throws {
        let fixture = try PnpmFixture()
        switch variant {
        case "target":
            try FileManager.default.removeItem(atPath: fixture.target)
        case "dependency":
            try FileManager.default.removeItem(
                atPath: fixture.root + "/node_modules/@sukiru/fixture-skills")
        case "projectManifest":
            try fixture.tree.file("project/package.json", contents: "{")
        case "packageManifest":
            let package = (fixture.target as NSString).deletingLastPathComponent
            try "{".write(
                toFile: (package as NSString).deletingLastPathComponent + "/package.json",
                atomically: true, encoding: .utf8)
        default:
            try fixture.tree.file("project/node_modules/.modules.yaml", contents: "{")
        }
        let before = try TreeChecksum.manifest(root: fixture.tree.path)
        let report = try fixture.scan()
        #expect(report.skills.allSatisfy { $0.ownership != .pnpm && $0.isPnpmReadOnly })
        for path in fixture.paths {
            #expect(
                report.issues.contains { $0.kind == IssueKind.pnpmUnverified && $0.path == path })
        }
        #expect(
            report.issues.filter { $0.kind == IssueKind.pnpmUnverified }.allSatisfy {
                $0.message.contains("Inspect the project with pnpm")
            })
        #expect(!report.findings.contains { ProblemKind.of($0) == .orphan })
        let health = try run("health", fixture: fixture, arguments: ["--check"], json: false)
        #expect(health.exitCode == 1)
        #expect(try !text(health.stdout).contains("Healthy"))
        for command in ["clean", "fix"] {
            let result = try run(command, fixture: fixture, arguments: ["--dry-run"])
            #expect(result.exitCode == 0)
            #expect(try text(result.stdout) == "null\n")
        }
        #expect(try TreeChecksum.manifest(root: fixture.tree.path) == before)
    }

    @Test("Host collisions remain visible; Fix All skips pnpm and repairs other entries")
    func collisionsDoNotAuthorizePnpmDeletion() throws {
        let fixture = try PnpmFixture()
        try addPnpmLinks(to: fixture, hosts: [".agents", ".factory"])
        try fixture.tree.symlink("project/.agents/skills/unrelated-dead", to: "missing")
        try addVercelCopy(to: fixture, name: "ordinary")
        try fixture.tree.file(
            "project/.claude/skills/ordinary/SKILL.md",
            contents: OwnershipBuilders.skillMD("ordinary"))
        let github = OwnershipBuilders.ghSkillMD("github-tool", repo: "example/skills")
        for host in [".agents", ".claude"] {
            try fixture.tree.file(
                "project/" + host + "/skills/github-tool/SKILL.md", contents: github)
        }
        let before = try TreeChecksum.manifest(root: fixture.tree.path)
        let report = try fixture.scan()
        let collision = try #require(
            report.findings.first {
                $0.ruleID == HostNameCollisionRule.ruleID && $0.skillName == "original-guide"
            })
        #expect(HostNameCollisionRule.subtype(of: collision) == .redundant)
        #expect(ProblemKind.of(collision) == .duplicateName)
        let decisions = FindingID.assignments(for: report.findings).compactMap { entry in
            ProblemKind.oneClickFix(for: entry.finding).map {
                DecisionEntry(findingID: entry.id, action: $0)
            }
        }
        let built = CommandBatchBuilder().buildApplicable(report: report, decisions: decisions)
        let batch = try #require(built.batch)
        #expect(built.skipped == [LifecycleBlocker.pnpmManaged.message])
        #expect(
            Set(batch.findingRefs.compactMap(\.skillName))
                == ["github-tool", "ordinary", "unrelated-dead"])
        for command in ["clean", "fix"] {
            let result = try run(command, fixture: fixture, arguments: ["--dry-run"])
            #expect(result.exitCode == 0)
            let planned = try JSONDecoder().decode(CommandBatch.self, from: result.stdout)
            let expected: Set<String> =
                command == "clean"
                ? ["unrelated-dead"] : ["github-tool", "ordinary", "unrelated-dead"]
            #expect(Set(planned.findingRefs.compactMap(\.skillName)) == expected)
            #expect(try text(result.stderr).contains("pnpm"))
        }
        #expect(try TreeChecksum.manifest(root: fixture.tree.path) == before)
    }

    @Test("CLI Health uses the scan's placements and distinguishes Notes from Problems")
    func healthyCliReport() throws {
        let fixture = try PnpmFixture()
        try addPnpmLinks(to: fixture, hosts: [".agents"])
        try fixture.tree.dir("home/.config/opencode")
        let before = try TreeChecksum.manifest(root: fixture.tree.path)
        let report = try fixture.scan()
        let json = try run("health", fixture: fixture, arguments: ["--check"])
        #expect(json.exitCode == 0)
        #expect(try JSONDecoder().decode(ScanReport.self, from: json.stdout) == report)
        let human = try run("health", fixture: fixture, arguments: ["--check"], json: false)
        #expect(human.exitCode == 0)
        #expect(try text(human.stdout).hasPrefix("Healthy\n"))
        #expect(report.findings.allSatisfy { ProblemKind.of($0) == .note })
        #expect(report.findings.contains { HostNameCollisionRule.subtype(of: $0) == .alias })
        let shared =
            fixture.root + "/.agents/skills/"
            + (fixture.paths[0] as NSString).lastPathComponent
        #expect(
            Set(report.skills.first?.placements.map(\.path) ?? [])
                == Set(fixture.paths + [shared]))
        for command in ["clean", "fix"] {
            let result = try run(command, fixture: fixture, arguments: ["--dry-run"])
            #expect(result.exitCode == 0)
            #expect(try text(result.stdout) == "null\n")
        }
        #expect(try TreeChecksum.manifest(root: fixture.tree.path) == before)
    }

    private func addVercelCopy(to fixture: PnpmFixture, name: String) throws {
        let path = try fixture.tree.file(
            "project/.agents/skills/\(name)/SKILL.md", contents: OwnershipBuilders.skillMD(name))
        let hash = try #require(
            ContentHasher().computedHash(
                ofSkillAtPath: (path as NSString).deletingLastPathComponent
            ).successValue)
        try fixture.tree.file(
            "project/skills-lock.json",
            contents: OwnershipBuilders.projectLock(name, computedHash: hash))
    }

    private func addPnpmLinks(to fixture: PnpmFixture, hosts: [String]) throws {
        var metadata = try #require(
            JSONSerialization.jsonObject(with: Data(fixture.metadata().utf8)) as? [String: Any])
        var links = try #require(metadata["linkedSkills"] as? [String])
        for host in hosts {
            let link = host + "/skills/" + (fixture.paths[0] as NSString).lastPathComponent
            try fixture.tree.symlink("project/" + link, to: fixture.target)
            links.append(link)
        }
        metadata["linkedSkills"] = links
        let nativeData = try JSONSerialization.data(withJSONObject: metadata)
        try fixture.tree.file(
            "project/node_modules/.modules.yaml", contents: text(nativeData))
    }

    private func text(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    private func run(
        _ command: String, fixture: PnpmFixture, arguments: [String], json: Bool = true
    ) throws -> CLIRunner.Result {
        try CLIRunner.run(
            [command, "--scope", "project"] + arguments,
            environment: CLIRunner.fixtureEnvironment(
                home: fixture.tree.path + "/home", roots: [fixture.root], path: ""), json: json)
    }
}
