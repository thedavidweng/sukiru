import Foundation
import Testing

@testable import SukiruCore

/// The Search/Install milestone's real-CLI end-to-end validation (stories
/// 22–24): an install batch built by `InstallPlanBuilder` executes through
/// the REAL pinned `npx skills` into a sandboxed HOME, and the post-state
/// rescan shows the skill installed with Vercel ownership. This proves the
/// verified non-interactive command shape end to end, exactly like the
/// seam-B e2e harness (logging wrappers, transcript, real-$HOME canary).
///
/// Gated: skipped unless `SUKIRU_E2E=1` (network + toolchain required).
@Suite(
    "search/install end-to-end (real CLI, sandboxed HOME)",
    .serialized,
    .enabled(if: SeamBE2ESupport.enabled, "set SUKIRU_E2E=1 to run the real-CLI install e2e")
)
struct SearchInstallEndToEndTests {
    /// The real upstream repo + skill proven by the seam-B fixtures (the
    /// same source the CM corpus was generated against).
    static let upstreamRepo = "thedavidweng/skills"
    static let upstreamSkill = "stale-docs-cleanup"

    @Test("a built install batch installs through real npx and lands in the Vercel ledger")
    func installEndToEnd() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let canary = SeamBE2ESupport.HomeCanary()
        defer { try? canary.verifyUnchanged() }

        let tools = try SeamBE2ESupport.resolveTools()
        let bin = try SeamBE2ESupport.installToolWrappers(tools, into: tree)

        // Pre-state: an empty sandboxed user scope, scanned like the app
        // would scan before building the batch.
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home]))
        let engine = ScanEngine(environment: environment)
        let pre = try engine.scan(ScanRequest())
        #expect(pre.skills.isEmpty, "sandbox starts with no skills")

        // Build the install batch exactly as the app's Search → Install
        // sheet does (story 23: search result + installer + target).
        let result = SkillSearchResult(
            name: Self.upstreamSkill,
            repo: Self.upstreamRepo,
            path: nil,
            description: nil,
            installs: nil,
            stars: nil,
            backend: .skillsDotSh)
        let batch = try InstallPlanBuilder().build(
            result: result, installer: .vercel, target: .user)
        let reviewed = try batch.transitioned(to: .reviewed)

        // Execute through the REAL skill CLI into the sandbox (cwd-scoped
        // PATH with logging wrappers; HOME is the sandbox).
        let executor = CLIExecutor(
            environment: environment,
            commandTimeout: SeamBE2ESupport.batchTimeout,
            pathOverride: bin + ":/usr/bin:/bin")
        let execution = try executor.execute(batch: reviewed, report: pre)
        #expect(execution.record.batchStatus == .succeeded)
        #expect(!execution.record.snapshotID.isEmpty)

        // The transcript proves the exact verified shape ran. The PWD field
        // is the executor's cwd (user-scope installs carry no working
        // directory); the sandbox isolation is the HOME assertion below.
        let transcript = try SeamBE2ESupport.transcript(tree)
        #expect(
            transcript.contains(
                "skills add \(Self.upstreamRepo) -s \(Self.upstreamSkill) -g -y"),
            "install transcript shows the exact verified command: \(transcript)")
        let npxEnv = try SeamBE2ESupport.envDump(tree, tool: "npx")
        #expect(npxEnv.contains("HOME=\(home)"), "npx ran with the sandboxed HOME")

        // Post-state: the rescan shows the skill installed, Vercel-owned
        // (the Vercel ledger recorded it).
        let post = try engine.scan(ScanRequest())
        let installed = post.skills.first { $0.name == Self.upstreamSkill }
        let installedSkill = try #require(installed)
        #expect(installedSkill.ownership == .vercel)
        #expect(installedSkill.scope == .user)
        #expect(installedSkill.placements.contains { $0.path.hasPrefix(home + "/.agents") })

        // The snapshot captured the pre-batch ledger state; rollback must be
        // available for the terminal batch (the install writes are covered
        // by the same seam-B safety model).
        let record = execution.record
        let canRollback =
            record.batchStatus == .succeeded && !record.snapshotID.isEmpty
        #expect(canRollback)
    }
}
