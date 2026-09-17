import Foundation
import Testing

@testable import SukiruCore

/// Shared helpers for the `sukiru-cli batch` contract suites.
enum BatchCLITestSupport {
    static func stderrText(_ result: CLIRunner.Result) -> String {
        String(bytes: result.stderr, encoding: .utf8) ?? ""
    }

    /// Mints the finding ID for a rule/skill pair from a live scan.
    static func findingID(
        _ scan: [String: Any], ruleID: String, skill: String
    ) throws -> String {
        let findings = try #require(scan["findings"] as? [[String: Any]])
        let match = try #require(
            findings.first {
                ($0["ruleID"] as? String) == ruleID && ($0["skillName"] as? String) == skill
            })
        let workspace = try #require(match["workspaceID"] as? String)
        return ruleID + ":" + workspace + ":" + skill
    }

    /// Runs `batch --decisions` against a fixture with the given decisions
    /// dictionary. The decisions file is written into a temp dir (it is an
    /// input of the CLI, never an output).
    static func runBatch(
        fixture: String,
        decisions: [String: Any],
        extraArguments: [String] = []
    ) throws -> CLIRunner.Result {
        let tree = try TempTree()
        let decisionsPath = tree.path + "/decisions.json"
        let data = try JSONSerialization.data(withJSONObject: decisions, options: [.sortedKeys])
        try Data(data).write(to: URL(fileURLWithPath: decisionsPath))
        let inputs = FixturePaths.homeAndRoots(fixture)
        let environment = CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)
        return try CLIRunner.run(
            ["batch", "--decisions", decisionsPath] + extraArguments,
            environment: environment
        )
    }

    static func scanObject(_ fixture: String) throws -> [String: Any] {
        let result = try CLIRunner.scanFixture(fixture)
        #expect(result.exitCode == 0, "stderr: \(stderrText(result))")
        return try #require(try result.jsonObject())
    }

    /// First command of a dry-run batch JSON, with the count asserted.
    static func onlyCommand(
        in batch: [String: Any], fileID: String = #fileID
    ) throws -> [String: Any] {
        let commands = try #require(batch["commands"] as? [[String: Any]])
        return try #require(commands.only)
    }
}

/// Dry-run rendering of every decision type (architecture D12,
/// VAL-REPAIR-001…005, 010, 014, 015, 017, 018).
@Suite("sukiru-cli batch dry-run rendering")
struct BatchCLIDryRunTests {
    private typealias Support = BatchCLITestSupport

    // MARK: - VAL-REPAIR-005: dry-run renders everything, writes nothing

    @Test("CM-3 keep-vercel dry-run: full batch JSON, exit 0, fixture byte-identical")
    func dryRunWritesNothing() throws {
        let scan = try Support.scanObject("CM-3")
        let findingID = try Support.findingID(
            scan, ruleID: "double-booked", skill: "stale-docs-cleanup")
        let before = try TreeChecksum.manifest(root: FixturePaths.tree("CM-3"))
        let result = try Support.runBatch(
            fixture: "CM-3",
            decisions: [findingID: ["action": "arbitrate", "choice": "keep-vercel"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let batch = try #require(try result.jsonObject())
        #expect(batch["status"] as? String == "proposed")
        #expect(batch["snapshotID"] is NSNull)
        #expect(batch["id"] is String)
        #expect(batch["createdAt"] is String)
        let commands = try #require(batch["commands"] as? [[String: Any]])
        #expect(commands.count == 1)
        let argv = try #require(commands[0]["argv"] as? [String])
        // D22 targeted re-install (probe-verified, seam-b-e2e): a plain
        // untargeted `add` refreshes ONLY the canonical store and leaves the
        // gh-overwritten host copy (and its provenance) untouched, so the
        // arbitration names every placement host explicitly.
        let expected =
            "npx skills add thedavidweng/skills --skill stale-docs-cleanup"
            + " -a claude-code -a codex --copy -y"
        #expect(argv.joined(separator: " ") == expected)
        let refs = try #require(batch["findingRefs"] as? [[String: Any]])
        #expect(refs.first?["findingID"] as? String == findingID)
        #expect(refs.first?["ruleID"] as? String == "double-booked")
        let after = try TreeChecksum.manifest(root: FixturePaths.tree("CM-3"))
        #expect(before == after, "dry-run must not touch the sandbox")
    }

    @Test("CM-3 keep-github dry-run: remove danger-flagged, then gh install --force --dir")
    func keepGitHubDryRun() throws {
        let scan = try Support.scanObject("CM-3")
        let findingID = try Support.findingID(
            scan, ruleID: "double-booked", skill: "stale-docs-cleanup")
        let result = try Support.runBatch(
            fixture: "CM-3",
            decisions: [findingID: ["action": "arbitrate", "choice": "keep-github"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let batch = try #require(try result.jsonObject())
        let commands = try #require(batch["commands"] as? [[String: Any]])
        #expect(commands.count == 2)
        let removeArgv = try #require(commands[0]["argv"] as? [String])
        #expect(removeArgv.joined(separator: " ") == "npx skills remove stale-docs-cleanup -y")
        #expect(commands[0]["dangerFlags"] as? [String] == ["dangerous-deletion"])
        let warning = try #require(commands[0]["warning"] as? String)
        #expect(warning.contains("stale-docs-cleanup"))
        let installArgv = try #require(commands[1]["argv"] as? [String])
        #expect(installArgv.prefix(3) == ["gh", "skill", "install"])
        #expect(installArgv.contains("--force"))
        #expect(installArgv.contains("--dir"))
        #expect(commands[1]["dangerFlags"] as? [String] == [])
    }

    // MARK: - VAL-REPAIR-001/002/009/010: routing surfaces

    @Test("CM-1 update dry-run: every command is an official CLI call with intent + owning CLI")
    func officialCLIOnly() throws {
        let scan = try Support.scanObject("CM-1")
        let findingID = try Support.findingID(
            scan, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        let result = try Support.runBatch(
            fixture: "CM-1", decisions: [findingID: ["action": "update"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let batch = try #require(try result.jsonObject())
        let commands = try #require(batch["commands"] as? [[String: Any]])
        #expect(!commands.isEmpty)
        for command in commands {
            let argv = try #require(command["argv"] as? [String])
            #expect(["npx", "gh"].contains(argv.first))
            let owningCLI = try #require(command["owningCLI"] as? String)
            #expect(["vercel", "github"].contains(owningCLI))
            #expect(owningCLI == (argv.first == "npx" ? "vercel" : "github"))
            let intent = try #require(command["intent"] as? String)
            #expect(!intent.isEmpty)
            #expect(command["displayString"] is String)
        }
    }

    @Test("CM-2 update dry-run: gh skill update <name> --dir <dir>, never --all, never npx")
    func githubUpdateDryRun() throws {
        let scan = try Support.scanObject("CM-2")
        let findingID = try Support.findingID(
            scan, ruleID: "dangerous-removal-surface", skill: "stale-docs-cleanup")
        let result = try Support.runBatch(
            fixture: "CM-2", decisions: [findingID: ["action": "update"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let batch = try #require(try result.jsonObject())
        let command = try Support.onlyCommand(in: batch)
        let argv = try #require(command["argv"] as? [String])
        #expect(argv.prefix(4) == ["gh", "skill", "update", "stale-docs-cleanup"])
        #expect(argv.contains("--dir"))
        #expect(!argv.contains("--all"))
    }

    // MARK: - VAL-REPAIR-017/018: ownerless adopt and cleanup

    @Test("ownerless adopt dry-run renders the gh re-anchoring shape")
    func adoptDryRun() throws {
        let scan = try Support.scanObject("FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(scan, ruleID: "files-without-lock", skill: "orphan")
        let choice: [String: Any] = ["repo": "acme/tools", "path": "skills/orphan"]
        let result = try Support.runBatch(
            fixture: "FIX-FILES-NO-LOCK",
            decisions: [findingID: ["action": "adopt", "choice": choice]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let batch = try #require(try result.jsonObject())
        let argv = try #require(try Support.onlyCommand(in: batch)["argv"] as? [String])
        #expect(argv.prefix(5) == ["gh", "skill", "install", "acme/tools", "skills/orphan"])
        #expect(argv.contains("--force"))
        #expect(argv.contains("--dir"))
    }

    @Test("ownerless cleanup dry-run is a flagged file operation, not a CLI call")
    func cleanupDryRun() throws {
        let scan = try Support.scanObject("FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(scan, ruleID: "files-without-lock", skill: "orphan")
        let result = try Support.runBatch(
            fixture: "FIX-FILES-NO-LOCK", decisions: [findingID: ["action": "cleanup"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        let batch = try #require(try result.jsonObject())
        let command = try Support.onlyCommand(in: batch)
        #expect(command["owningCLI"] as? String == "file")
        let flags = try #require(command["dangerFlags"] as? [String])
        #expect(flags.contains("direct-file-operation"))
        #expect(flags.contains("ownerless-cleanup"))
    }

    // MARK: - VAL-REPAIR-019: leave produces no batch

    @Test("leave-only decisions: exit 0, no batch JSON, sandbox unchanged")
    func leaveNoBatch() throws {
        let scan = try Support.scanObject("FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(scan, ruleID: "files-without-lock", skill: "orphan")
        let before = try TreeChecksum.manifest(root: FixturePaths.tree("FIX-FILES-NO-LOCK"))
        let result = try Support.runBatch(
            fixture: "FIX-FILES-NO-LOCK", decisions: [findingID: ["action": "leave"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 0, "stderr: \(Support.stderrText(result))")
        #expect(result.stdout.isEmpty, "leave must not render a batch")
        let after = try TreeChecksum.manifest(root: FixturePaths.tree("FIX-FILES-NO-LOCK"))
        #expect(before == after)
    }
}

/// Invalid decisions files and refusals (VAL-REPAIR-012, 013, 052, 056) plus
/// the no-execution guarantee of this build.
@Suite("sukiru-cli batch refusals")
struct BatchCLIRefusalTests {
    private typealias Support = BatchCLITestSupport

    @Test("unknown finding ID exits 1, naming the ID, writing nothing")
    func unknownFinding() throws {
        let before = try TreeChecksum.manifest(root: FixturePaths.tree("CM-1"))
        let result = try Support.runBatch(
            fixture: "CM-1",
            decisions: ["no-such-rule:user:ghost": ["action": "update"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("no-such-rule:user:ghost"))
        #expect(result.stdout.isEmpty)
        let after = try TreeChecksum.manifest(root: FixturePaths.tree("CM-1"))
        #expect(before == after)
    }

    @Test("unknown action exits 1 naming the action; arbitrate without choice exits 1")
    func invalidVocabulary() throws {
        let scan = try Support.scanObject("CM-3")
        let findingID = try Support.findingID(
            scan, ruleID: "double-booked", skill: "stale-docs-cleanup")
        let badAction = try Support.runBatch(
            fixture: "CM-3", decisions: [findingID: ["action": "obliterate"]],
            extraArguments: ["--dry-run"])
        #expect(badAction.exitCode == 1)
        #expect(Support.stderrText(badAction).contains("obliterate"))
        #expect(badAction.stdout.isEmpty)

        let noChoice = try Support.runBatch(
            fixture: "CM-3", decisions: [findingID: ["action": "arbitrate"]],
            extraArguments: ["--dry-run"])
        #expect(noChoice.exitCode == 1)
        #expect(Support.stderrText(noChoice).contains("choice"))
        #expect(noChoice.stdout.isEmpty)
    }

    @Test("update on a double-booked finding exits 1 naming both surviving-ledger choices")
    func arbitrationRequired() throws {
        let scan = try Support.scanObject("CM-3")
        let findingID = try Support.findingID(
            scan, ruleID: "double-booked", skill: "stale-docs-cleanup")
        let result = try Support.runBatch(
            fixture: "CM-3", decisions: [findingID: ["action": "update"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("keep-vercel"))
        #expect(Support.stderrText(result).contains("keep-github"))
        #expect(result.stdout.isEmpty)
    }

    @Test("update on an ownerless skill exits 1: no ledger owns this skill")
    func ownerlessUpdateRefused() throws {
        let scan = try Support.scanObject("FIX-FILES-NO-LOCK")
        let findingID = try Support.findingID(scan, ruleID: "files-without-lock", skill: "orphan")
        let result = try Support.runBatch(
            fixture: "FIX-FILES-NO-LOCK", decisions: [findingID: ["action": "update"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("no ledger owns this skill"))
    }

    @Test("update on an ambiguous skill exits 1 with an attribution-voided explanation")
    func ambiguousUpdateRefused() throws {
        let scan = try Support.scanObject("FIX-AMBIGUOUS")
        let findingID = try Support.findingID(scan, ruleID: "ambiguous-name", skill: "dup")
        let result = try Support.runBatch(
            fixture: "FIX-AMBIGUOUS", decisions: [findingID: ["action": "update"]],
            extraArguments: ["--dry-run"])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("attribution"))
    }

    @Test("batch without --dry-run refuses with exit 1 and writes nothing")
    func noExecutionWithoutDryRun() throws {
        let scan = try Support.scanObject("CM-1")
        let findingID = try Support.findingID(
            scan, ruleID: "cross-host-duplicate", skill: "stale-docs-cleanup")
        let before = try TreeChecksum.manifest(root: FixturePaths.tree("CM-1"))
        let result = try Support.runBatch(
            fixture: "CM-1", decisions: [findingID: ["action": "update"]])
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("--dry-run"))
        #expect(result.stdout.isEmpty)
        let after = try TreeChecksum.manifest(root: FixturePaths.tree("CM-1"))
        #expect(before == after)
    }

    @Test("missing --decisions and unknown flags are usage errors (exit 1)")
    func usageErrors() throws {
        let inputs = FixturePaths.homeAndRoots("CM-1")
        let environment = CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)
        let missing = try CLIRunner.run(["batch", "--dry-run"], environment: environment)
        #expect(missing.exitCode == 1)
        #expect(Support.stderrText(missing).contains("--decisions"))
        let unknownFlag = try CLIRunner.run(
            ["batch", "--decisions", "/tmp/x.json", "--frobnicate"], environment: environment)
        #expect(unknownFlag.exitCode == 1)
        #expect(Support.stderrText(unknownFlag).contains("--frobnicate"))
    }

    @Test("an unreadable decisions file exits 1 naming the path")
    func unreadableDecisionsFile() throws {
        let inputs = FixturePaths.homeAndRoots("CM-1")
        let environment = CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)
        let result = try CLIRunner.run(
            ["batch", "--decisions", "/nonexistent/decisions.json", "--dry-run"],
            environment: environment)
        #expect(result.exitCode == 1)
        #expect(Support.stderrText(result).contains("/nonexistent/decisions.json"))
        #expect(result.stdout.isEmpty)
    }
}
