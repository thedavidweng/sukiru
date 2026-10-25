import Foundation
import Testing

@testable import SukiruCore

@Suite("pnpm package permission observations")
struct PnpmObservationTests {
    @Test func pendingWithoutPlacementsIsNotASkillOrProblem() throws {
        let fixture = try PendingFixture()
        let report = try fixture.scan()
        let observation = try #require(report.pnpmObservations?.first)
        #expect(observation.packageName == "@sukiru/example")
        #expect(observation.selector == "@sukiru/example@file:../example.tgz")
        #expect(observation.permission == .pending)
        #expect(!observation.installed)
        #expect(report.skills.isEmpty)
        #expect(report.findings.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test func staleNativeRecordWithoutPlacementsRemainsVisible() throws {
        let fixture = try PendingFixture()
        let path = fixture.root + "/.claude/skills/pnpm-@sukiru+example-guide"
        try fixture.tree.file(
            "project/node_modules/.modules.yaml",
            contents: """
                {"packageManager":"pnpm@12.11.0","layoutVersion":5,"nodeLinker":"isolated",
                 "virtualStoreDir":".pnpm","linkedSkills":[".claude/skills/pnpm-@sukiru+example-guide"]}
                """)
        let report = try fixture.scan()
        #expect(report.skills.isEmpty)
        #expect(report.issues.contains { $0.kind == IssueKind.pnpmUnverified && $0.path == path })
    }

    @Test func decisionsArePackageWideAndDoNotImplyInstallation() throws {
        let fixture = try PendingFixture()
        for (value, expected) in [(true, PnpmObservation.Permission.approved), (false, .denied)] {
            try fixture.workspace(value: value)
            let report = try fixture.scan()
            let observations = try #require(report.pnpmObservations)
            #expect(observations.count == 1)
            #expect(observations.first?.permission == expected)
            #expect(observations.first?.installed == false)
        }
        try FileManager.default.removeItem(atPath: fixture.root + "/pnpm-workspace.yaml")
        #expect(try fixture.scan().pnpmObservations?.first?.permission == .pending)
        try fixture.tree.file(
            "project/node_modules/.modules.yaml",
            contents: "{\"packageManager\":\"pnpm@12.11.0\",\"layoutVersion\":5}")
        #expect(try fixture.scan().pnpmObservations?.isEmpty != false)
    }

    @Test func revokedPermissionDoesNotHideStillInstalledLinks() throws {
        let fixture = try PnpmFixture()
        try fixture.tree.file(
            "project/pnpm-workspace.yaml",
            contents:
                "permissions:\n  '@sukiru/fixture-skills@file:../fixture.tgz':\n    skills: false\n"
        )
        let report = try fixture.scan()
        let observation = try #require(report.pnpmObservations?.first)
        #expect(observation.permission == .denied)
        #expect(observation.installed)
        #expect(report.skills.count == 1)
    }

    @Test func malformedWorkspaceFailsClosed() throws {
        let fixture = try PendingFixture()
        try fixture.tree.file(
            "project/pnpm-workspace.yaml",
            contents: "permissions:\n  '@sukiru/example@file:../example.tgz':\n    skills: 42\n")
        let report = try fixture.scan()
        #expect(report.pnpmObservations?.first?.permission == .unknown)
        #expect(report.issues.contains { $0.path == fixture.root + "/pnpm-workspace.yaml" })
        #expect(report.skills.isEmpty)
    }

    @Test func workspaceSymlinkCannotReadOutsideProject() throws {
        let fixture = try PendingFixture()
        let outside = try fixture.tree.file(
            "outside.yaml",
            contents: "permissions:\n  '@sukiru/example@file:../example.tgz':\n    skills: true\n")
        try fixture.tree.symlink("project/pnpm-workspace.yaml", to: outside)
        let report = try fixture.scan()
        #expect(report.pnpmObservations?.first?.permission == .unknown)
        #expect(report.issues.contains { $0.path == fixture.root + "/pnpm-workspace.yaml" })
    }

    @Test func linksWithoutPermissionMetadataRemainUnknown() throws {
        let fixture = try PnpmFixture()
        let report = try fixture.scan()
        let observation = try #require(report.pnpmObservations?.first)
        #expect(observation.permission == .unknown)
        #expect(observation.installed)
    }

    @Test func projectScopeDoesNotLeakOtherRegisteredProjects() throws {
        let fixture = try PendingFixture()
        let report = try fixture.scan(roots: [])
        #expect(report.pnpmObservations?.isEmpty != false)
    }
}

private struct PendingFixture {
    let tree: TempTree
    let root: String

    init() throws {
        tree = try TempTree()
        root = try tree.dir("project")
        try tree.dir("home")
        try tree.file("project/package.json", contents: "{}")
        try tree.file(
            "project/node_modules/.modules.yaml",
            contents: """
                {
                  "packageManager": "pnpm@12.11.0",
                  "layoutVersion": 5,
                  "nodeLinker": "isolated",
                  "virtualStoreDir": ".pnpm",
                  "pendingSkills": ["@sukiru/example@file:../example.tgz"]
                }
                """)
    }

    func workspace(value: Bool) throws {
        try tree.file(
            "project/pnpm-workspace.yaml",
            contents:
                "permissions:\n  '@sukiru/example@file:../example.tgz':\n    skills: \(value)\n")
    }

    func scan(roots: [String]? = nil) throws -> ScanReport {
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader([
                "SUKIRU_HOME": tree.path + "/home", "PATH": ""
            ]))
        return try ScanEngine(environment: environment).scan(
            ScanRequest(explicitRoots: roots ?? [root], scope: .project))
    }
}
