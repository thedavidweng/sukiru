import Foundation
import Testing

@testable import SukiruCore

final class PnpmRealSandbox {
    let tree: TempTree
    let environment: [String: String]
    let binary: String
    var home: String { tree.path + "/home" }
    var root: String { tree.path + "/project" }

    init() throws {
        let tree = try TempTree()
        self.tree = tree
        for directory in ["home", "config", "cache", "data", "state", "store", "tmp", "project"] {
            try tree.dir(directory)
        }
        try tree.file("user.npmrc")
        try tree.file("global.npmrc")
        environment = [
            "HOME": tree.path + "/home", "SUKIRU_HOME": tree.path + "/home",
            "XDG_CONFIG_HOME": tree.path + "/config", "XDG_CACHE_HOME": tree.path + "/cache",
            "XDG_DATA_HOME": tree.path + "/data", "XDG_STATE_HOME": tree.path + "/state",
            "TMPDIR": tree.path + "/tmp", "PNPM_HOME": tree.path + "/data/pnpm",
            "npm_config_userconfig": tree.path + "/user.npmrc",
            "npm_config_globalconfig": tree.path + "/global.npmrc",
            "npm_config_cache": tree.path + "/cache/npm", "PATH": "/usr/bin:/bin",
            "CI": "1", "NO_COLOR": "1", "LC_ALL": "C", "TZ": "UTC"
        ]
        binary = try PnpmRealSupport.resolvePnpm(tree: tree, environment: environment)
    }

    @discardableResult
    func pnpm(_ arguments: [String], project: String = "project") throws -> CLIRunner.Result {
        let result = try PnpmRealSupport.run(
            binary, arguments + ["--store-dir", tree.path + "/store"],
            cwd: tree.path + "/" + project, environment: environment)
        try PnpmRealSupport.requireSuccess(
            result, command: "pnpm " + arguments.joined(separator: " "))
        return result
    }

    func install(project: String = "project") throws {
        try pnpm(["install", "--offline", "--ignore-scripts"], project: project)
    }

    func package(
        name: String = "@sukiru/real-alpha", version: String = "1.0.0",
        archive: String = "alpha-v1.tgz", addedSkill: Bool = false
    ) throws {
        let source = "packages/" + archive + "/package"
        try writeJSON(
            source + "/package.json",
            ["name": name, "version": version, "files": ["skills"]])
        try tree.file(
            source + "/skills/guide/SKILL.md",
            contents: OwnershipBuilders.skillMD(
                "shared-guide", variant: "Package \(name) \(version)."))
        if addedSkill {
            try tree.file(
                source + "/skills/added/SKILL.md",
                contents: OwnershipBuilders.skillMD("added-guide", variant: "Added in \(version)."))
        }
        let result = try PnpmRealSupport.run(
            "/usr/bin/tar", ["-czf", tree.path + "/" + archive, "package"],
            cwd: tree.path + "/packages/" + archive, environment: environment)
        try PnpmRealSupport.requireSuccess(result, command: "tar local skill package")
    }

    func project(
        _ relative: String = "project", dependencies: [String: String],
        directories: [String] = [".claude/skills", ".codebuddy/skills"]
    ) throws {
        try writeJSON(
            relative + "/package.json",
            [
                "name": "isolated-" + relative.replacingOccurrences(of: "/", with: "-"),
                "private": true, "dependencies": dependencies
            ])
        for directory in directories { try tree.dir(relative + "/" + directory) }
    }

    func writeJSON(_ path: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try tree.file(path, contents: PnpmRealSupport.text(data))
    }

    func modules(project: String = "project") throws -> [String: Any] {
        let data = try Data(
            contentsOf: URL(
                fileURLWithPath: tree.path + "/" + project + "/node_modules/.modules.yaml"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var scanEnvironment: SukiruEnvironment {
        SukiruEnvironment(
            reader: DictionaryEnvironmentReader(environment.merging(["PATH": ""]) { _, new in new })
        )
    }

    func scan(project: String = "project") throws -> ScanReport {
        let root = tree.path + "/" + project
        let before = try TreeChecksum.manifest(root: tree.path)
        let report = try ScanEngine(environment: scanEnvironment).scan(
            ScanRequest(explicitRoots: [root], scope: .project))
        var childEnvironment = environment
        childEnvironment["PATH"] = ""
        childEnvironment["SUKIRU_ROOTS"] = root
        for command in ["scan", "health"] {
            let arguments = [command, "--scope", "project", "--json"]
            let result = try CLIRunner.run(arguments, environment: childEnvironment)
            #expect(result.exitCode == 0)
            #expect(try JSONDecoder().decode(ScanReport.self, from: result.stdout) == report)
        }
        #expect(try TreeChecksum.manifest(root: tree.path) == before)
        return report
    }

    func assertReadOnly(_ report: ScanReport, project: String = "project") throws {
        let before = try TreeChecksum.manifest(root: tree.path)
        let protected = report.skills.filter(\.isPnpmReadOnly)
        let builder = CommandBatchBuilder()
        for skill in protected {
            for action in LifecycleAction.allCases {
                #expect(
                    CommandBatchBuilder.lifecycleBlocker(
                        skill: skill, action: action, capabilities: nil, report: report)
                        == .pnpmManaged)
                let plan = builder.buildApplicable(
                    report: report, decisions: [],
                    lifecycle: [LifecycleRequest(skill: skill, action: action)])
                #expect(plan.batch == nil)
                #expect(!plan.skipped.isEmpty)
            }
            for mode in [PlacementMode.copy, .link] {
                #expect(throws: BatchBuildError.self) {
                    try builder.buildModeSwitch(skill: skill, to: mode, report: report)
                }
            }
        }
        let root = tree.path + "/" + project
        let context = HostRemovalContext(
            environment: scanEnvironment, report: report, projectRoots: [root])
        let plan = try builder.planHostRemoval(
            hostID: "claude-code", bucket: "project:" + root, report: report, context: context)
        let protectedPaths = Set(protected.flatMap { $0.placements.map(\.path) })
        #expect(plan.removed.allSatisfy { !protectedPaths.contains($0.path) })
        for command in ["clean", "fix"] {
            var childEnvironment = environment
            childEnvironment["PATH"] = ""
            childEnvironment["SUKIRU_ROOTS"] = root
            let result = try CLIRunner.run(
                [command, "--scope", "project", "--dry-run"], environment: childEnvironment)
            #expect(result.exitCode == 0)
        }
        #expect(try TreeChecksum.manifest(root: tree.path) == before)
    }
}
