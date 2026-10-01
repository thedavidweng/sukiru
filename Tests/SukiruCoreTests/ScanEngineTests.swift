import Foundation
import Testing

@testable import SukiruCore

@Suite("ScanEngine workspace enumeration")
struct ScanEngineTests {
    private func scan(
        vars: [String: String],
        explicitRoots: [String] = [],
        scope: Scope = .all,
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) throws -> ScanReport {
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        let engine = ScanEngine(environment: environment, fileSystem: fileSystem)
        return try engine.scan(ScanRequest(explicitRoots: explicitRoots, scope: scope))
    }

    private func ids(_ report: ScanReport) -> String {
        report.workspaces.map(\.id).joined(separator: " ")
    }

    @Test("Emits the canonical user workspace for a valid home")
    func canonicalUserWorkspace() throws {
        let report = try scan(
            vars: ["SUKIRU_HOME": "/fixture"],
            fileSystem: StubFileSystem(existing: ["/fixture"])
        )
        #expect(report.schemaVersion == 1)
        #expect(
            report.workspaces == [
                Workspace(id: "user", kind: .user, root: "/fixture/.agents/skills", installed: true)
            ]
        )
        #expect(report.skills.isEmpty)
        #expect(report.findings.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test("Throws when SUKIRU_HOME is set but missing")
    func missingHome() {
        #expect(throws: FatalEnvironmentProblem.sukiruHomeMissing(path: "/gone")) {
            try scan(
                vars: ["SUKIRU_HOME": "/gone"],
                fileSystem: StubFileSystem(existing: [])
            )
        }
    }

    @Test("JSON output is deterministic and carries the report top-level keys")
    func deterministicJSON() throws {
        let report = ScanReport()
        let first = try report.jsonData()
        let second = try report.jsonData()
        #expect(first == second)

        let object = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        let keys = Set((object ?? [:]).keys)
        #expect(keys == ["schemaVersion", "workspaces", "skills", "findings", "issues"])
    }

    @Test("--scope partitions workspaces into user and project")
    func scopePartition() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.dir(".claude/skills")
        try project.dir(".claude/skills")

        let vars = ["SUKIRU_HOME": home.path, "SUKIRU_ROOTS": project.path]
        let proj = project.path
        let all = try scan(vars: vars)
        let userOnly = try scan(vars: vars, scope: .user)
        let projectOnly = try scan(vars: vars, scope: .project)

        #expect(ids(all) == "user host:claude-code project:\(proj) project:\(proj)#claude-code")
        #expect(ids(userOnly) == "user host:claude-code")
        #expect(ids(projectOnly) == "project:\(proj) project:\(proj)#claude-code")
        // The union property: all == user ++ project, order preserved.
        #expect(all.workspaces == userOnly.workspaces + projectOnly.workspaces)
    }

    @Test("Explicit roots replace SUKIRU_ROOTS, never merge")
    func explicitRootsReplace() throws {
        let home = try TempTree()
        let envRoot = try TempTree()
        let flagRoot = try TempTree()
        try envRoot.dir(".claude/skills")
        try flagRoot.dir(".claude/skills")

        let vars = ["SUKIRU_HOME": home.path, "SUKIRU_ROOTS": envRoot.path]
        let env = envRoot.path
        let flag = flagRoot.path
        let fromEnv = try scan(vars: vars)
        #expect(ids(fromEnv) == "user project:\(env) project:\(env)#claude-code")

        let fromFlag = try scan(vars: vars, explicitRoots: [flag])
        #expect(ids(fromFlag) == "user project:\(flag) project:\(flag)#claude-code")
        #expect(!fromFlag.workspaces.contains { $0.root.hasPrefix(env) })
    }
}
