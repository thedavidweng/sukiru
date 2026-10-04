import Foundation
import Testing

@testable import SukiruCore

/// End-to-end validation against the REAL pinned CLIs in sandboxed HOMEs
/// (repair, arbitration, adopt, cross-scope isolation, node-absent
/// degradation). Serialized because each test spawns `sukiru-cli`, which spawns
/// the real `npx`/`gh` (network access, downloads per sandbox). The suite
/// continues in `RealCLIEndToEndTests+Isolation.swift` (same struct, so the
/// serialized trait covers every test).
@Suite(
    "Real-CLI end-to-end (sandboxed HOMEs)",
    .serialized,
    .enabled(if: RealCLIE2ESupport.enabled, "set SUKIRU_E2E=1 to run the real-CLI e2e suite")
)
struct RealCLIEndToEndTests {
    typealias Support = RealCLIE2ESupport
    typealias Batch = BatchExecutionSupport

    // MARK: - Drift repair makes the findings disappear

    @Test("Real-npx drift repair on CM-1 clears drift + divergence on rescan")
    func driftRepairMakesFindingsDisappear() throws {
        let tree = try TempTree()
        let fixture = try Support.prepare("CM-1", into: tree)
        let home = fixture.home
        let roots = fixture.roots
        let bin = fixture.bin
        let root = try #require(roots.only)
        let canary = Support.HomeCanary()

        // Introduce drift on the host copy only: the canonical store still
        // matches the lock, the .claude copy no longer does.
        let hostCopy = root + "/.claude/skills/stale-docs-cleanup/SKILL.md"
        let original = try String(contentsOfFile: hostCopy, encoding: .utf8)
        try (original + "\nLocal drift introduced by the real-CLI e2e suite.\n")
            .write(toFile: hostCopy, atomically: true, encoding: .utf8)

        let pre = try Batch.scanObject(home: home, roots: roots)
        let driftID = try BatchCLITestSupport.findingID(
            pre, ruleID: "vercel-lock-drift", skill: "stale-docs-cleanup")
        let divergence = try Support.findings(
            pre, ruleID: "canonical-host-divergence", skill: "stale-docs-cleanup")
        #expect(!divergence.isEmpty, "pre-state: the drifted copy diverges")

        _ = try Support.executeBatch(
            home: home, roots: roots, decisions: [driftID: ["action": "update"]],
            tree: tree, bin: bin)

        // Targeted reinstall against the REAL CLI: every placement host
        // named, copy mode (an untargeted `add` refreshes only the canonical
        // store and the drift would survive — probe-verified).
        let transcript = try Support.transcript(tree)
        #expect(transcript.contains("-a claude-code -a codex --copy -y"))
        #expect(transcript.contains("skills add thedavidweng/skills"))

        let post = try Batch.scanObject(home: home, roots: roots)
        let driftGone = try Support.findings(
            post, ruleID: "vercel-lock-drift", skill: "stale-docs-cleanup")
        let divergenceGone = try Support.findings(
            post, ruleID: "canonical-host-divergence", skill: "stale-docs-cleanup")
        let duplicate = try Support.findings(
            post, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        #expect(driftGone.isEmpty, "the originating drift finding is gone")
        #expect(divergenceGone.isEmpty, "the divergence finding is gone too")
        #expect(!duplicate.isEmpty, "unrelated finding intact (inherent copy-mode duplicate)")
        let ownership = try Support.skillOwnership(
            post, name: "stale-docs-cleanup", scope: "project")
        #expect(ownership == "vercel")

        // Sandboxing proof: the real npx ran with HOME = the sandbox and no
        // token; the real $HOME never changed.
        let env = try Support.envDump(tree, tool: "npx")
        #expect(env.contains("HOME=\(home)"))
        #expect(env.contains("GH_TOKEN=absent"))
        try canary.verifyUnchanged()
    }

    // MARK: - keep-vercel arbitration end-to-end

    @Test("Keep-vercel on CM-3 → single vercel ownership, findings gone")
    func keepVercelRepairsDoubleBooked() throws {
        let tree = try TempTree()
        let fixture = try Support.prepare("CM-3", into: tree)
        let home = fixture.home
        let roots = fixture.roots
        let bin = fixture.bin
        let canary = Support.HomeCanary()

        let pre = try Batch.scanObject(home: home, roots: roots)
        let findingID = try BatchCLITestSupport.findingID(
            pre, ruleID: "double-booked", skill: "stale-docs-cleanup")
        let preFindings = try Support.findingIdentities(pre)
        #expect(preFindings.contains { $0.hasPrefix("vercel-lock-drift|") })
        #expect(preFindings.contains { $0.hasPrefix("canonical-host-divergence|") })

        _ = try Support.executeBatch(
            home: home, roots: roots,
            decisions: [findingID: ["action": "arbitrate", "choice": "keep-vercel"]],
            tree: tree, bin: bin)

        let transcript = try Support.transcript(tree)
        #expect(transcript.contains("-a claude-code -a codex --copy -y"))
        #expect(!transcript.contains("gh|"), "keep-vercel never invokes the gh CLI")

        let post = try Batch.scanObject(home: home, roots: roots)
        let ownership = try Support.skillOwnership(
            post, name: "stale-docs-cleanup", scope: "project")
        #expect(ownership == "vercel", "Single ownership = kept ledger")
        let postFindings = try Support.findingIdentities(post)
        #expect(!postFindings.contains { $0.hasPrefix("double-booked|") })
        #expect(!postFindings.contains { $0.hasPrefix("vercel-lock-drift|") })
        #expect(!postFindings.contains { $0.hasPrefix("canonical-host-divergence|") })
        try canary.verifyUnchanged()
    }

    // MARK: - keep-github arbitration end-to-end

    @Test(
        "Keep-github on CM-3 → single github ownership, no double-booked",
        .enabled(if: RealCLIE2ESupport.gitHubToken != nil, "GH_TOKEN required for gh skill install")
    )
    func keepGitHubRepairsDoubleBooked() throws {
        let tree = try TempTree()
        let fixture = try Support.prepare("CM-3", into: tree)
        let home = fixture.home
        let roots = fixture.roots
        let bin = fixture.bin
        let canary = Support.HomeCanary()

        let pre = try Batch.scanObject(home: home, roots: roots)
        let findingID = try BatchCLITestSupport.findingID(
            pre, ruleID: "double-booked", skill: "stale-docs-cleanup")
        let record = try Support.executeBatch(
            home: home, roots: roots,
            decisions: [findingID: ["action": "arbitrate", "choice": "keep-github"]],
            tree: tree, bin: bin, token: Support.gitHubToken)
        #expect(record["snapshotID"] is String)

        // The keep-github arbitration sequence against the real CLIs: danger-flagged npx remove
        // first, then gh install --force --dir re-anchoring the provenance.
        let lines = try Support.transcript(tree).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("skills remove stale-docs-cleanup -y") == true)
        #expect(lines.last?.hasPrefix("gh|") == true)
        #expect(lines.last?.contains("skill install thedavidweng/skills") == true)
        #expect(lines.last?.contains("--force") == true)
        #expect(lines.last?.contains("--dir") == true)
        let npxEnv = try Support.envDump(tree, tool: "npx")
        let ghEnv = try Support.envDump(tree, tool: "gh")
        #expect(npxEnv.contains("GH_TOKEN=absent"), "token scoped to gh commands only")
        #expect(ghEnv.contains("GH_TOKEN=present"))

        let post = try Batch.scanObject(home: home, roots: roots)
        let ownership = try Support.skillOwnership(
            post, name: "stale-docs-cleanup", scope: "project")
        #expect(ownership == "github", "Single ownership = kept ledger")
        let postFindings = try Support.findingIdentities(post)
        #expect(
            !postFindings.contains { $0.hasPrefix("double-booked|") },
            "no double-booked finding remains in any scope")
        // Known upstream side effect (probe-verified): `npx skills remove`
        // writes a spurious entry to the GLOBAL lock even from a project
        // cwd, so the user scope may show `lock-without-files` afterwards.
        // The arbitration check is scoped to the arbitrated skill's
        // single ownership; the pollution is documented here so a future
        // skills CLI that stops polluting is a visible, intentional change.
        try canary.verifyUnchanged()
    }

    // MARK: - Node-absent degradation

    @Test("Node-absent: capabilities report npx unresolvable; vercel repair blocked with a hint")
    func nodeAbsentDegradesCleanly() throws {
        let tree = try TempTree()
        let copy = try Batch.copyFixture("CM-1", into: tree)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let projectRoot = try #require(inputs.roots.only)
        let projectBefore = try TreeChecksum.manifest(root: projectRoot)

        // The capability surface says what the repair surface will do.
        let capabilities = try CLIRunner.run(
            ["capabilities", "--json"],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots))
        #expect(capabilities.exitCode == 0)
        let caps = try #require(try capabilities.jsonObject())
        let npxCaps = try #require(caps["npx"] as? [String: Any])
        #expect(npxCaps["resolvable"] as? Bool == false)

        // A vercel repair batch FAILS — it never half-executes.
        let scan = try Batch.scanObject(home: inputs.home, roots: inputs.roots)
        let findingID = try BatchCLITestSupport.findingID(
            scan, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        let decisions = try Batch.writeDecisions(
            [findingID: ["action": "update"]], into: tree)
        let result = try Batch.runBatch(
            home: inputs.home, roots: inputs.roots, decisionsPath: decisions,
            arguments: ["--execute", "--yes", "--confirm-dangerous"])
        #expect(result.exitCode == 1)
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "failed")
        let command = try #require(try Batch.commands(of: record).only)
        #expect(command["failureKind"] as? String == "executable-missing")
        let diagnostics = try #require(command["diagnostics"] as? String)
        #expect(diagnostics.contains("npx"))
        #expect(diagnostics.contains("install"), "the failure carries an actionable hint")

        // Zero mutations: the project tree is byte-identical and the
        // pre-batch snapshot exists for inspection.
        let snapshotID = try #require(record["snapshotID"] as? String)
        let manifest =
            inputs.home + "/Library/Application Support/Sukiru/snapshots/"
            + snapshotID + "/manifest.json"
        #expect(FileManager.default.fileExists(atPath: manifest))
        #expect(try TreeChecksum.manifest(root: projectRoot) == projectBefore)
    }
}
