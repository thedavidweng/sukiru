import Foundation
import Testing

@testable import SukiruCore

/// End-to-end contract tests for the `sukiru-cli` report surfaces
/// (architecture §4.2, D18), driving the REAL built executable with an
/// explicit, hermetic environment. Nothing here inherits the developer's
/// PATH/HOME; capability probes only ever meet temp PATH stubs. The
/// safety-guarantee twins (exit codes, root precedence, subprocess-freedom,
/// read-only) live in `CLIGuaranteeTests`.
@Suite("sukiru-cli end-to-end contract")
struct CLIIntegrationTests {
    private let d18TopLevelKeys: Set<String> =
        ["schemaVersion", "workspaces", "skills", "findings", "issues"]
    private let d18WorkspaceKeys: Set<String> = ["id", "kind", "root", "installed"]

    private func stderrText(_ result: CLIRunner.Result) -> String {
        String(bytes: result.stderr, encoding: .utf8) ?? ""
    }

    // MARK: VAL-SCAN-001 — complete D18 report, exit 0

    @Test("VAL-SCAN-001: scan emits a complete D18 ScanReport with exit 0")
    func scanReportShape() throws {
        let result = try CLIRunner.scanFixture("clean-copy-mode")
        #expect(result.exitCode == 0, "stderr: \(stderrText(result))")
        let object = try #require(try result.jsonObject())
        #expect(Set(object.keys) == d18TopLevelKeys)
        #expect(object["schemaVersion"] as? Int == 1)

        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        #expect(!workspaces.isEmpty)
        for workspace in workspaces {
            #expect(Set(workspace.keys) == d18WorkspaceKeys)
            #expect(["user", "project"].contains(workspace["kind"] as? String))
            #expect(workspace["root"] is String)
            #expect(workspace["installed"] is Bool)
        }
    }

    // MARK: VAL-SCAN-002 — capabilities report populated from PATH stubs

    @Test("VAL-SCAN-002: capabilities reports gh + npx from PATH stubs, exit 0")
    func capabilitiesFromPathStubs() throws {
        let stubs = try TempTree()
        try stubs.executable(
            "gh",
            contents: """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                    echo "gh version 2.100.0 (2026-01-15)"
                    exit 0
                fi
                if [ "$1" = "skill" ] && [ "$2" = "--help" ]; then
                    echo "Work with agent skills"
                    exit 0
                fi
                exit 1
                """
        )
        try stubs.executable(
            "npx",
            contents: """
                #!/bin/sh
                echo "1.5.26"
                exit 0
                """
        )

        let inputs = FixturePaths.homeAndRoots("FIX-EMPTY")
        let result = try CLIRunner.run(
            ["capabilities", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(
                home: inputs.home, path: stubs.path + ":/usr/bin:/bin")
        )
        #expect(result.exitCode == 0, "stderr: \(stderrText(result))")
        let object = try #require(try result.jsonObject())
        let github = try #require(object["github"] as? [String: Any])
        #expect(github["available"] as? Bool == true)
        #expect(github["present"] as? Bool == true)
        #expect(github["version"] as? String == "2.100.0")
        #expect(github["meetsMinimum"] as? Bool == true)
        let npx = try #require(object["npx"] as? [String: Any])
        #expect(npx["resolvable"] as? Bool == true)
        #expect(npx["skillsVersion"] as? String == "1.5.26")
    }

    @Test("VAL-SCAN-002: capabilities with neither CLI reports unavailability, exit 0")
    func capabilitiesNeither() throws {
        let inputs = FixturePaths.homeAndRoots("FIX-EMPTY")
        let result = try CLIRunner.run(
            ["capabilities", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home)
        )
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let github = try #require(object["github"] as? [String: Any])
        #expect(github["available"] as? Bool == false)
        #expect(github["present"] as? Bool == false)
        #expect(github["meetsMinimum"] as? Bool == false)
        let npx = try #require(object["npx"] as? [String: Any])
        #expect(npx["resolvable"] as? Bool == false)
    }

    // MARK: VAL-SCAN-003 — determinism

    @Test("VAL-SCAN-003: byte-identical repeat scans and root-order independence")
    func determinism() throws {
        let inputs = FixturePaths.homeAndRoots("own-per-project")
        #expect(inputs.roots.count == 2)
        let base = CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)

        let first = try CLIRunner.run(["scan", "--format", "json"], environment: base)
        let second = try CLIRunner.run(["scan", "--format", "json"], environment: base)
        #expect(first.exitCode == 0 && second.exitCode == 0)
        #expect(first.stdout == second.stdout)

        var permuted = base
        permuted["SUKIRU_ROOTS"] = inputs.roots.reversed().joined(separator: ":")
        let third = try CLIRunner.run(["scan", "--format", "json"], environment: permuted)
        #expect(third.exitCode == 0)
        #expect(first.stdout == third.stdout)
    }

    // MARK: VAL-SCAN-004 — hermeticity

    @Test("VAL-SCAN-004: no path outside SUKIRU_HOME/SUKIRU_ROOTS appears in the report")
    func hermeticity() throws {
        // Scan a COPY under $TMPDIR (outside the real home) so a leaked
        // real-home path is unambiguous — the checked-in fixture legitimately
        // lives under the developer's home directory.
        let sandbox = try TempTree()
        // Canonicalize the sandbox base: macOS temp dirs live under /var, a
        // symlink to /private/var, and realpath-resolved canonicalPath fields
        // in the report use the resolved form.
        let copy = sandbox.canonicalPath + "/scope-isolation"
        try FileManager.default.copyItem(
            atPath: FixturePaths.tree("scope-isolation"), toPath: copy)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let result = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)
        )
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let paths = ReportPathAudit.absolutePaths(in: object)
        let violations = ReportPathAudit.pathsOutside(
            paths, allowedRoots: [inputs.home] + inputs.roots)
        #expect(violations.isEmpty, "paths outside the sandbox: \(violations)")
        let realHome = NSHomeDirectory()
        #expect(!paths.contains { $0 == realHome || $0.hasPrefix(realHome + "/") })
    }

    // MARK: VAL-SCAN-005 — scope partitioning

    @Test("VAL-SCAN-005: --scope user/project partition the report; all is their union")
    func scopePartitioning() throws {
        let inputs = FixturePaths.homeAndRoots("scope-isolation")
        let all = try CLIRunner.scanFixture("scope-isolation")
        let user = try CLIRunner.scanFixture("scope-isolation", arguments: ["--scope", "user"])
        let project = try CLIRunner.scanFixture(
            "scope-isolation", arguments: ["--scope", "project"])
        for result in [all, user, project] {
            #expect(result.exitCode == 0)
        }
        let allObject = try #require(try all.jsonObject())
        let userObject = try #require(try user.jsonObject())
        let projectObject = try #require(try project.jsonObject())

        let allIDs = try #require(allObject["workspaces"] as? [[String: Any]])
            .compactMap { $0["id"] as? String }
        let userIDs = try #require(userObject["workspaces"] as? [[String: Any]])
            .compactMap { $0["id"] as? String }
        let projectIDs = try #require(projectObject["workspaces"] as? [[String: Any]])
            .compactMap { $0["id"] as? String }

        #expect(!userIDs.isEmpty && !projectIDs.isEmpty)
        #expect(userIDs.allSatisfy { !$0.hasPrefix("project:") })
        #expect(projectIDs.allSatisfy { $0.hasPrefix("project:") })
        #expect(allIDs == userIDs + projectIDs)

        // Findings anchor only to workspaces of their own scope.
        let userFindingWorkspaces = try #require(userObject["findings"] as? [[String: Any]])
            .compactMap { $0["workspaceID"] as? String }
        #expect(userFindingWorkspaces.allSatisfy { userIDs.contains($0) })
        let projectFindingWorkspaces = try #require(projectObject["findings"] as? [[String: Any]])
            .compactMap { $0["workspaceID"] as? String }
        #expect(projectFindingWorkspaces.allSatisfy { projectIDs.contains($0) })

        // No cross-scope placement paths: project placements live under the
        // project root, user placements under the home.
        let projectRoot = inputs.roots[0]
        let userPlacements = try #require(userObject["skills"] as? [[String: Any]])
            .flatMap { ($0["placements"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["path"] as? String }
        #expect(!userPlacements.isEmpty)
        #expect(userPlacements.allSatisfy { !$0.hasPrefix(projectRoot + "/") })
        let projectPlacements = try #require(projectObject["skills"] as? [[String: Any]])
            .flatMap { ($0["placements"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["path"] as? String }
        #expect(!projectPlacements.isEmpty)
        #expect(projectPlacements.allSatisfy { $0.hasPrefix(projectRoot + "/") })
    }
}
