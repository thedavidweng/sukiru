import Foundation
import Testing

@testable import SukiruCore

@Suite("pnpm ownership at the scan and mutation seams")
struct PnpmOwnershipTests {
    @Test func realInstallationWithoutPnpmOnPath() throws {
        let fixture = try PnpmFixture()
        let before = try fixture.metadata()
        let result = try CLIRunner.run(
            ["scan", "--scope", "project", "--json"],
            environment: CLIRunner.fixtureEnvironment(
                home: fixture.tree.path + "/home", roots: [fixture.root], path: ""))
        #expect(result.exitCode == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        let skill = try #require(report.skills.first)
        #expect(report.skills.count == 1)
        #expect(skill.name == "original-guide")
        #expect(skill.scope == .project)
        #expect(skill.ownership == .pnpm)
        #expect(skill.placements.count == 2)
        let evidence = try #require(skill.provenance.pnpm)
        #expect(evidence.count == 2)
        #expect(
            evidence.allSatisfy {
                $0.packageName == "@sukiru/fixture-skills" && $0.packageVersion == "1.0.0"
                    && $0.originalName == "original-guide" && $0.projectRoot == fixture.root
                    && $0.target == fixture.target && $0.dependency == "file:../fixture.tgz"
            })
        #expect(report.findings.isEmpty)
        #expect(report.issues.isEmpty)
        #expect(try fixture.metadata() == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.root + "/skills-lock.json"))
    }

    @Test(arguments: ["missing", "corrupt", "old", "future", "wrongType", "unrecorded"])
    func invalidNativeDataIsUnverified(_ variant: String) throws {
        let fixture = try PnpmFixture()
        let path = fixture.root + "/node_modules/.modules.yaml"
        var metadata = try fixture.metadata()
        switch variant {
        case "missing": try FileManager.default.removeItem(atPath: path)
        case "corrupt": try "{".write(toFile: path, atomically: true, encoding: .utf8)
        default:
            switch variant {
            case "old": metadata = metadata.replacingOccurrences(of: "12.11.0", with: "12.10.0")
            case "future": metadata = metadata.replacingOccurrences(of: "12.11.0", with: "13.0.0")
            case "wrongType": metadata = #"{"linkedSkills":42}"#
            default:
                metadata = metadata.replacingOccurrences(of: "linkedSkills", with: "pendingSkills")
            }
            try metadata.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let report = try fixture.scan()
        #expect(report.skills.allSatisfy { $0.ownership != .pnpm && $0.isPnpmReadOnly })
        for placement in fixture.paths {
            #expect(
                report.issues.contains {
                    $0.kind == IssueKind.pnpmUnverified && $0.path == placement
                })
        }
        #expect(report.findings.isEmpty)
        #expect(try report.jsonData() == fixture.scan().jsonData())
    }

    @Test func recordAndPrefixCannotClaimCopiedDirectory() throws {
        let fixture = try PnpmFixture()
        let path = fixture.paths[0]
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.copyItem(atPath: fixture.target, toPath: path)
        let report = try fixture.scan()
        let copied = try #require(report.skills.first { $0.ownership != .pnpm })
        #expect(copied.isPnpmReadOnly)
        #expect(copied.placements.map(\.path) == [path])
        let linked = try #require(report.skills.first { $0.ownership == .pnpm })
        #expect(linked.provenance.pnpm?.count == 1)
        #expect(report.issues.contains { $0.path == path && $0.kind == IssueKind.pnpmUnverified })
    }

    @Test func outOfProjectAndBrokenTargetsAreUnverified() throws {
        let fixture = try PnpmFixture()
        let outside = try fixture.tree.dir("outside/skills/guide")
        try fixture.tree.file(
            "outside/skills/guide/SKILL.md",
            contents: "---\nname: original-guide\ndescription: outside\n---\n")
        for (index, path) in fixture.paths.enumerated() {
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createSymbolicLink(
                atPath: path, withDestinationPath: index == 0 ? outside : outside + "/missing")
        }
        let report = try fixture.scan()
        #expect(report.skills.allSatisfy { $0.ownership != .pnpm && $0.isPnpmReadOnly })
        #expect(!report.findings.contains { $0.ruleID == "broken-symlink" })
    }

    @Test func projectsDoNotBorrowRecords() throws {
        let fixture = try PnpmFixture()
        let other = try fixture.tree.dir("other")
        try fixture.tree.symlink(
            "other/.claude/skills/pnpm-@sukiru+fixture-skills-guide", to: fixture.target)
        let report = try fixture.scan(roots: [fixture.root, other])
        #expect(report.skills.filter { $0.ownership == .pnpm }.count == 1)
        #expect(report.skills.filter { $0.ownership == .ownerless }.count == 1)
    }

    @Test func nativeEvidenceBlocksAllForeignMutationRoutes() throws {
        let fixture = try PnpmFixture()
        let report = try fixture.scan()
        let skill = try #require(report.skills.first)
        let builder = CommandBatchBuilder()
        for action in LifecycleAction.allCases {
            #expect(
                CommandBatchBuilder.lifecycleBlocker(
                    skill: skill, action: action, capabilities: nil, report: report) == .pnpmManaged
            )
            let result = builder.buildApplicable(
                report: report, decisions: [],
                lifecycle: [LifecycleRequest(skill: skill, action: action)])
            #expect(result.batch == nil)
            #expect(result.skipped.count == 1)
        }
        for mode in [PlacementMode.link, .copy] {
            #expect(throws: BatchBuildError.self) {
                try builder.buildModeSwitch(skill: skill, to: mode, report: report)
            }
        }
        for installer in [InstallerChoice.vercel, .github] {
            for name in [skill.name, (fixture.paths[0] as NSString).lastPathComponent] {
                #expect(throws: InstallPlanError.pnpmReadOnly) {
                    try InstallPlanBuilder(report: report).build(
                        repo: "example/skills", skills: [name], installer: installer,
                        target: .project(root: fixture.root),
                        options: InstallOptions(ghAgent: "claude-code"))
                }
            }
        }
        let finding = Finding(
            ruleID: "files-without-lock", severity: .info, skillName: skill.name,
            workspaceID: "project:" + fixture.root, evidence: [])
        let withFinding = ScanReport(
            workspaces: report.workspaces, skills: report.skills, findings: [finding])
        let identifier = try #require(FindingID.assignments(for: [finding]).first?.id)
        for action in DecisionAction.allCases where action != .leave {
            #expect(throws: BatchBuildError.self) {
                try builder.build(
                    report: withFinding,
                    decisions: [DecisionEntry(findingID: identifier, action: action)])
            }
        }
    }
}

struct PnpmFixture {
    let tree: TempTree
    let root: String
    let target: String
    let paths: [String]

    init() throws {
        tree = try TempTree()
        root = try tree.dir("project")
        try tree.dir("home")
        let source = FixturePaths.root.appendingPathComponent("pnpm-12.11.0")
        func text(_ name: String) throws -> String {
            try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)
        }
        let links = try JSONDecoder().decode(
            [String: String].self, from: Data(text("links.json").utf8))
        let relativeTarget =
            "node_modules/.pnpm/@sukiru+fixture-skills@file+..+fixture.tgz"
            + "/node_modules/@sukiru/fixture-skills"
        try tree.file("project/package.json", contents: text("project.json"))
        try tree.file("project/node_modules/.modules.yaml", contents: text("modules.json"))
        try tree.file(
            "project/" + relativeTarget + "/package.json", contents: text("dependency.json"))
        try tree.file(
            "project/" + relativeTarget + "/skills/guide/SKILL.md", contents: text("SKILL.md"))
        try tree.symlink(
            "project/node_modules/@sukiru/fixture-skills",
            to:
                "../.pnpm/@sukiru+fixture-skills@file+..+fixture.tgz/node_modules/@sukiru/fixture-skills"
        )
        for path in links.keys.sorted() {
            try tree.symlink("project/" + path, to: links[path]!)
        }
        let projectRoot = root
        let canonicalTarget = tree.canonicalPath + "/project/" + relativeTarget + "/skills/guide"
        paths = links.keys.sorted().map { projectRoot + "/" + $0 }
        target = canonicalTarget
    }

    func metadata() throws -> String {
        try String(contentsOfFile: root + "/node_modules/.modules.yaml", encoding: .utf8)
    }

    func scan(roots: [String]? = nil) throws -> ScanReport {
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": tree.path + "/home", "PATH": ""]))
        return try ScanEngine(environment: environment).scan(
            ScanRequest(explicitRoots: roots ?? [root], scope: .project))
    }
}
