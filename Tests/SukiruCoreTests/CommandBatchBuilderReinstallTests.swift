import Foundation
import Testing

@testable import SukiruCore

/// D22 targeted re-install routing (probe-verified against skills@1.5.26,
/// seam-b-e2e): an UNTARGETED `npx skills add <source> --skill <name>`
/// refreshes ONLY the canonical `.agents/skills` copy, leaving drifted or
/// gh-overwritten host copies (and their provenance) untouched — so drift
/// repair and keep-vercel arbitration name every placement's host
/// explicitly, with `--copy` when a physical copy lives outside the
/// canonical store.
@Suite("CommandBatchBuilder targeted re-install routing")
struct CommandBatchBuilderReinstallTests {
    private typealias Support = BatchTestSupport

    @Test("FIX-HOST-DIVERGENCE: drift repair targets every placement host with --copy")
    func driftRepairTargetsPlacementHosts() throws {
        let report = try OwnershipBuilders.scanSplitFixture("FIX-HOST-DIVERGENCE")
        let findingID = try Support.findingID(report, "vercel-lock-drift", "web-tool")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        let command = try #require(batch.commands.only)
        let expected =
            "npx skills add thedavidweng/skills --skill web-tool -a claude-code -a codex --copy -y"
        #expect(command.argv.joined(separator: " ") == expected)
        #expect(command.owningCLI == .vercel)
        #expect(command.workingDirectory != nil, "project-scope npx runs in the project root")
    }

    @Test("CM-3 keep-vercel: re-install targets both placement hosts, erasing gh provenance")
    func keepVercelTargetsPlacementHosts() throws {
        let report = try OwnershipBuilders.scanSplitFixture("CM-3")
        let findingID = try Support.findingID(report, "double-booked", "stale-docs-cleanup")
        let batch = try Support.build(
            report, [Support.decide(findingID, .arbitrate, .keepVercel)])
        let command = try #require(batch.commands.only)
        let expected =
            "npx skills add thedavidweng/skills --skill stale-docs-cleanup"
            + " -a claude-code -a codex --copy -y"
        #expect(command.argv.joined(separator: " ") == expected)
        #expect(command.owningCLI == .vercel)
    }

    @Test("Symlinked host placements reinstall in link mode (no --copy)")
    func symlinkPlacementsReinstallInLinkMode() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.dir(".agents/skills/linked")
        try project.file(
            ".agents/skills/linked/SKILL.md",
            contents: OwnershipBuilders.skillMD("linked", variant: "Edited after install."))
        try project.dir(".claude/skills")
        try FileManager.default.createSymbolicLink(
            atPath: project.path + "/.claude/skills/linked",
            withDestinationPath: "../../.agents/skills/linked")
        // The v1 lock's fixed hash never matches the edited content → drift.
        try project.file(
            "skills-lock.json", contents: OwnershipBuilders.projectLock("linked"))
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        let findingID = try Support.findingID(report, "vercel-lock-drift", "linked")
        let batch = try Support.build(report, [Support.decide(findingID, .update)])
        let command = try #require(batch.commands.only)
        #expect(command.argv.contains("-a"))
        #expect(command.argv.contains("claude-code"))
        #expect(!command.argv.contains("--copy"), "symlink placements repair in link mode")
    }
}
