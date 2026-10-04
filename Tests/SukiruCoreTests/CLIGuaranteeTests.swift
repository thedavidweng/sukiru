import Foundation
import Testing

@testable import SukiruCore

/// End-to-end safety guarantees of the `sukiru-cli` scan surface
/// exit codes, `--root` precedence,
/// subprocess-freedom, and strict read-only behavior, exercised against the
/// REAL built executable with an explicit, hermetic environment.
@Suite("sukiru-cli safety guarantees")
struct CLIGuaranteeTests {
    private let reportTopLevelKeys: Set<String> =
        ["schemaVersion", "workspaces", "skills", "findings", "issues"]

    // MARK: Exit codes

    @Test("Exit 2 only when SUKIRU_HOME is set but nonexistent")
    func exitCode2ForMissingHome() throws {
        let missing = "/tmp/sukiru-nonexistent-\(UUID().uuidString)"
        let env = ["PATH": "/usr/bin:/bin", "SUKIRU_HOME": missing]
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        #expect(scan.exitCode == 2)
        // No healthy-looking report on stdout.
        #expect(scan.stdout.isEmpty)
        #expect(try scan.jsonObject() == nil)

        // The exit-code contract applies to every command.
        let capabilities = try CLIRunner.run(["capabilities"], environment: env)
        #expect(capabilities.exitCode == 2)
    }

    @Test("Unknown flag exits 64; garbage fixtures still exit 0")
    func exitCodesUsageAndGarbage() throws {
        let inputs = FixturePaths.homeAndRoots("FIX-EMPTY")
        let env = CLIRunner.fixtureEnvironment(home: inputs.home)
        let badFlag = try CLIRunner.run(["scan", "--bogus"], environment: env)
        #expect(badFlag.exitCode == 64)
        let badCommand = try CLIRunner.run(["frobnicate"], environment: env)
        #expect(badCommand.exitCode == 64)
        let badScope = try CLIRunner.run(["scan", "--scope", "everything"], environment: env)
        #expect(badScope.exitCode == 64)

        let garbage = try CLIRunner.scanFixture("FIX-GARBAGE")
        #expect(garbage.exitCode == 0)
        #expect(try garbage.jsonObject() != nil)
    }

    // MARK: Root flag replaces SUKIRU_ROOTS

    @Test("--root replaces SUKIRU_ROOTS, never merges")
    func rootReplacesRoots() throws {
        let perProject = FixturePaths.homeAndRoots("own-per-project")
        let rootA = perProject.roots[0]
        let rootB = perProject.roots[1]
        let rootC = FixturePaths.tree("clean-copy-mode") + "/proj"
        let env = CLIRunner.fixtureEnvironment(home: perProject.home, roots: [rootA, rootB])

        // SUKIRU_ROOTS alone → a and b present.
        let fromEnv = try CLIRunner.run(["scan", "--json"], environment: env)
        let envIDs = try workspaceIDs(fromEnv)
        #expect(envIDs.contains("project:\(rootA)"))
        #expect(envIDs.contains("project:\(rootB)"))

        // --root c REPLACES the env roots: only c's project workspace appears.
        let fromFlag = try CLIRunner.run(
            ["scan", "--root", rootC, "--json"], environment: env)
        let flagIDs = try workspaceIDs(fromFlag)
        #expect(flagIDs.contains("project:\(rootC)"))
        #expect(!flagIDs.contains("project:\(rootA)"))
        #expect(!flagIDs.contains("project:\(rootB)"))

        // Neither --root nor SUKIRU_ROOTS → default discovery (user scope only).
        let noRoots = try CLIRunner.run(
            ["scan", "--json"],
            environment: CLIRunner.fixtureEnvironment(home: perProject.home))
        let defaultIDs = try workspaceIDs(noRoots)
        #expect(defaultIDs.allSatisfy { !$0.hasPrefix("project:") })
    }

    private func workspaceIDs(_ result: CLIRunner.Result) throws -> [String] {
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        return workspaces.compactMap { $0["id"] as? String }
    }

    // MARK: Zero subprocesses during scan

    @Test("Scan spawns zero subprocesses (PATH logging shims stay silent)")
    func zeroSubprocesses() throws {
        let shims = try TempTree()
        let log = shims.path + "/invocations.log"
        let shim = """
            #!/bin/sh
            echo "$0 $*" >> "$SUKIRU_SHIM_LOG"
            exit 1
            """
        for tool in ["gh", "npx", "node", "git"] {
            try shims.executable(tool, contents: shim)
        }

        let inputs = FixturePaths.homeAndRoots("clean-copy-mode")
        let result = try CLIRunner.run(
            ["scan", "--json"],
            environment: CLIRunner.fixtureEnvironment(
                home: inputs.home,
                roots: inputs.roots,
                path: shims.path + ":/usr/bin:/bin",
                extra: ["SUKIRU_SHIM_LOG": log]
            )
        )
        #expect(result.exitCode == 0)
        let invocations = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(invocations.isEmpty, "scan spawned subprocesses: \(invocations)")

        // The report carries no capability/version fields — report keys only.
        let object = try #require(try result.jsonObject())
        #expect(Set(object.keys) == reportTopLevelKeys)
    }

    // MARK: Strictly read-only

    @Test("Scan and capabilities leave the fixture tree byte-identical")
    func readOnly() throws {
        let fixture = FixturePaths.tree("scope-isolation")
        let inputs = FixturePaths.homeAndRoots("scope-isolation")
        let before = try TreeChecksum.manifest(root: fixture)

        let env = CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        #expect(scan.exitCode == 0)
        // Base PATH holds no gh/npx stubs, so capabilities spawns nothing.
        let capabilities = try CLIRunner.run(
            ["capabilities", "--json"], environment: env)
        #expect(capabilities.exitCode == 0)

        let after = try TreeChecksum.manifest(root: fixture)
        #expect(before == after)
    }

    @Test("Read-only holds while capabilities really spawns probe subprocesses")
    func readOnlyWithLiveProbeStubs() throws {
        // The base test's PATH holds no gh/npx stubs, so its capabilities run
        // spawns nothing. This variant composes the cap-* stub bins so the
        // probes DO spawn real subprocesses against the fixture tree; the
        // stubs are side-effect-free unless SUKIRU_STUB_TRANSCRIPT is set
        // (unset here).
        let fixture = FixturePaths.tree("scope-isolation")
        let inputs = FixturePaths.homeAndRoots("scope-isolation")
        let before = try TreeChecksum.manifest(root: fixture)

        let stubPath =
            FixturePaths.tree("cap-gh-ok") + "/bin:"
            + FixturePaths.tree("cap-npx-ok") + "/bin:/usr/bin:/bin"
        let env = CLIRunner.fixtureEnvironment(
            home: inputs.home, roots: inputs.roots, path: stubPath)
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        #expect(scan.exitCode == 0)
        let capabilities = try CLIRunner.run(
            ["capabilities", "--json"], environment: env)
        #expect(capabilities.exitCode == 0)
        // Proof the probes really ran: the stubs report gh available.
        let object = try #require(try capabilities.jsonObject())
        let github = try #require(object["github"] as? [String: Any])
        #expect(github["available"] as? Bool == true)

        let after = try TreeChecksum.manifest(root: fixture)
        #expect(before == after)
    }
}
