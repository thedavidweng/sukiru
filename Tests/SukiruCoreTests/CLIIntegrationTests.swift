import Foundation
import Testing

@testable import SukiruCore

/// End-to-end contract tests for the `sukiru-cli` report surfaces
/// driving the REAL built executable with an
/// explicit, hermetic environment. Nothing here inherits the developer's
/// PATH/HOME; capability probes only ever meet temp PATH stubs. The
/// safety-guarantee twins (exit codes, root precedence, subprocess-freedom,
/// read-only) live in `CLIGuaranteeTests`.
@Suite("sukiru-cli end-to-end contract")
struct CLIIntegrationTests {
    private let reportTopLevelKeys: Set<String> =
        ["schemaVersion", "workspaces", "skills", "findings", "issues"]
    private let reportWorkspaceKeys: Set<String> = ["id", "kind", "root", "installed"]

    private func stderrText(_ result: CLIRunner.Result) -> String {
        String(bytes: result.stderr, encoding: .utf8) ?? ""
    }

    // MARK: Complete report, exit 0

    @Test("Scan emits a complete ScanReport with exit 0")
    func scanReportShape() throws {
        let result = try CLIRunner.scanFixture("clean-copy-mode")
        #expect(result.exitCode == 0, "stderr: \(stderrText(result))")
        let object = try #require(try result.jsonObject())
        #expect(Set(object.keys) == reportTopLevelKeys)
        #expect(object["schemaVersion"] as? Int == 1)

        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        #expect(!workspaces.isEmpty)
        for workspace in workspaces {
            #expect(Set(workspace.keys) == reportWorkspaceKeys)
            #expect(["user", "project"].contains(workspace["kind"] as? String))
            #expect(workspace["root"] is String)
            #expect(workspace["installed"] is Bool)
        }
    }

    // MARK: Capabilities report populated from PATH stubs

    @Test("Capabilities reports gh + npx from the cap-* fixtures, exit 0")
    func capabilitiesFromPathStubs() throws {
        // The checked-in PATH-stub fixtures (cap-gh-ok: gh 2.100.0 with a
        // working skill surface; cap-npx-ok: skills 1.5.26). The deeper
        // per-state assertions live in CapabilitiesFixtureTests.
        let stubPath =
            FixturePaths.tree("cap-gh-ok") + "/bin:"
            + FixturePaths.tree("cap-npx-ok") + "/bin:/usr/bin:/bin"
        let inputs = FixturePaths.homeAndRoots("FIX-EMPTY")
        let result = try CLIRunner.run(
            ["capabilities", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home, path: stubPath)
        )
        #expect(result.exitCode == 0, "stderr: \(stderrText(result))")
        let object = try #require(try result.jsonObject())
        let github = try #require(object["github"] as? [String: Any])
        #expect(github["available"] as? Bool == true)
        #expect(github["present"] as? Bool == true)
        #expect(github["version"] as? String == "2.100.0")
        #expect(github["meetsMinimum"] as? Bool == true)
        #expect(github["reason"] == nil)
        let npx = try #require(object["npx"] as? [String: Any])
        #expect(npx["resolvable"] as? Bool == true)
        #expect(npx["skillsVersion"] as? String == "1.5.26")
    }

    @Test("Capabilities with neither CLI reports unavailability, exit 0")
    func capabilitiesNeither() throws {
        let inputs = FixturePaths.homeAndRoots("FIX-EMPTY")
        let neitherPath = FixturePaths.tree("cap-neither") + "/bin:/usr/bin:/bin"
        let result = try CLIRunner.run(
            ["capabilities", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home, path: neitherPath)
        )
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let github = try #require(object["github"] as? [String: Any])
        #expect(github["available"] as? Bool == false)
        #expect(github["present"] as? Bool == false)
        #expect(github["meetsMinimum"] as? Bool == false)
        #expect(github["reason"] as? String == "absent")
        let npx = try #require(object["npx"] as? [String: Any])
        #expect(npx["resolvable"] as? Bool == false)
    }

    // MARK: Determinism

    @Test("Byte-identical repeat scans and root-order independence")
    func determinism() throws {
        // THREE roots (a:b:c vs c:a:b): own-per-project's
        // p1/p2 plus clean-copy-mode's proj as the third.
        let inputs = FixturePaths.homeAndRoots("own-per-project")
        let roots = inputs.roots + [FixturePaths.tree("clean-copy-mode") + "/proj"]
        #expect(roots.count == 3)
        let base = CLIRunner.fixtureEnvironment(home: inputs.home, roots: roots)

        let first = try CLIRunner.run(["scan", "--format", "json"], environment: base)
        let second = try CLIRunner.run(["scan", "--format", "json"], environment: base)
        #expect(first.exitCode == 0 && second.exitCode == 0)
        #expect(first.stdout == second.stdout)

        var permuted = base
        permuted["SUKIRU_ROOTS"] = roots.reversed().joined(separator: ":")
        let third = try CLIRunner.run(["scan", "--format", "json"], environment: permuted)
        #expect(third.exitCode == 0)
        #expect(first.stdout == third.stdout)
    }

    // MARK: Hermeticity

    @Test("No path outside SUKIRU_HOME/SUKIRU_ROOTS appears in the report")
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

    // MARK: Scope partitioning

    @Test("--scope user/project partition the report; all is their union")
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
