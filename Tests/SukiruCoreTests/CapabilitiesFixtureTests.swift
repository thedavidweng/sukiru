import Foundation
import Testing

@testable import SukiruCore

/// End-to-end capability-detection tests
/// driving the REAL built `sukiru-cli` against the checked-in `cap-*`
/// PATH-stub fixtures (see each fixture's EXPECTATION.md). Stubs report
/// controlled versions/probe outcomes without any network, and log their
/// invocations to `$SUKIRU_STUB_TRANSCRIPT` when set — the validator's
/// transcript evidence.
@Suite("sukiru-cli capabilities over the cap-* fixtures")
struct CapabilitiesFixtureTests {
    private let basePath = "/usr/bin:/bin"

    /// `Fixtures/<name>/bin` — the PATH entry a cap-* fixture contributes.
    private func bin(_ fixture: String) -> String {
        FixturePaths.tree(fixture) + "/bin"
    }

    private func path(_ fixtures: [String]) -> String {
        (fixtures.map { bin($0) } + [basePath]).joined(separator: ":")
    }

    /// Runs `capabilities --format json` with the given PATH composition and
    /// an optional transcript file the stubs append their invocations to.
    private func capabilities(path: String, transcript: String? = nil) throws -> CLIRunner.Result {
        let inputs = FixturePaths.homeAndRoots("FIX-EMPTY")
        var extra: [String: String] = [:]
        if let transcript {
            extra["SUKIRU_STUB_TRANSCRIPT"] = transcript
        }
        return try CLIRunner.run(
            ["capabilities", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home, path: path, extra: extra)
        )
    }

    private func githubSection(_ result: CLIRunner.Result) throws -> [String: Any] {
        #expect(result.exitCode == 0, "capabilities must exit 0")
        let object = try #require(try result.jsonObject())
        return try #require(object["github"] as? [String: Any])
    }

    private func transcriptLines(at path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map { String($0) }
    }

    // MARK: gh present and ≥ 2.90.0 detected with version

    @Test("cap-gh-ok stub detected available with version and transcript")
    func ghAvailableFixture() throws {
        let scratch = try TempTree()
        let transcript = scratch.path + "/transcript.log"
        let result = try capabilities(
            path: path(["cap-gh-ok", "cap-npx-ok"]), transcript: transcript)
        let github = try githubSection(result)
        #expect(github["available"] as? Bool == true)
        #expect(github["present"] as? Bool == true)
        #expect(github["meetsMinimum"] as? Bool == true)
        #expect(github["version"] as? String == "2.100.0")
        #expect(github["reason"] == nil, "no reason key when available")

        let lines = try transcriptLines(at: transcript)
        #expect(lines.contains("gh --version"))
        #expect(lines.contains("gh skill --help"))
    }

    // MARK: gh ≥ 2.90.0 but the skill probe fails

    @Test("cap-gh-probe-fail reports unavailable with probe-failed reason")
    func ghProbeFailureFixture() throws {
        let scratch = try TempTree()
        let transcript = scratch.path + "/transcript.log"
        let result = try capabilities(
            path: path(["cap-gh-probe-fail"]), transcript: transcript)
        #expect(result.exitCode == 0)
        let github = try githubSection(result)
        #expect(github["available"] as? Bool == false)
        #expect(github["present"] as? Bool == true)
        #expect(github["meetsMinimum"] as? Bool == true)
        #expect(github["version"] as? String == "2.100.0")
        #expect(github["reason"] as? String == "probe-failed")

        let lines = try transcriptLines(at: transcript)
        #expect(lines.contains("gh skill --help"), "the probe really ran against the stub")
    }

    // MARK: gh absent or too old; disk provenance still read

    @Test("cap-gh-absent and cap-gh-old states; own-github provenance intact")
    func ghAbsentAndOldFixtures() throws {
        // Absent: no gh on PATH at all.
        let absent = try capabilities(path: path(["cap-gh-absent"]))
        let absentGitHub = try githubSection(absent)
        #expect(absentGitHub["available"] as? Bool == false)
        #expect(absentGitHub["present"] as? Bool == false)
        #expect(absentGitHub["meetsMinimum"] as? Bool == false)
        #expect(absentGitHub["version"] == nil)
        #expect(absentGitHub["reason"] as? String == "absent")

        // Too old: gh answers with 2.80.0, below the 2.90.0 floor.
        let scratch = try TempTree()
        let transcript = scratch.path + "/transcript.log"
        let old = try capabilities(path: path(["cap-gh-old"]), transcript: transcript)
        let oldGitHub = try githubSection(old)
        #expect(oldGitHub["available"] as? Bool == false)
        #expect(oldGitHub["present"] as? Bool == true)
        #expect(oldGitHub["meetsMinimum"] as? Bool == false)
        #expect(oldGitHub["version"] as? String == "2.80.0")
        #expect(oldGitHub["reason"] as? String == "too-old")
        // The below-minimum gh is never probed for `skill` support.
        #expect(try !transcriptLines(at: transcript).contains("gh skill --help"))

        // In BOTH environments a scan over own-github still exits 0 and
        // surfaces metadata.github-* provenance from disk (provenance reading
        // never depends on the gh binary).
        for environmentPath in [path(["cap-gh-absent"]), path(["cap-gh-old"])] {
            let inputs = FixturePaths.homeAndRoots("own-github")
            let scan = try CLIRunner.run(
                ["scan", "--format", "json"],
                environment: CLIRunner.fixtureEnvironment(
                    home: inputs.home, roots: inputs.roots, path: environmentPath)
            )
            #expect(scan.exitCode == 0)
            try assertOwnGithubProvenance(scan)
        }
    }

    /// The own-github expectation (its EXPECTATION.md): both skills report
    /// ownership=github with full provenance; pinned-tool keeps its `.git`
    /// suffix and pinned=true; unpinned-tool reports pinned=false.
    private func assertOwnGithubProvenance(_ scan: CLIRunner.Result) throws {
        let object = try #require(try scan.jsonObject())
        let skills = try #require(object["skills"] as? [[String: Any]])

        let pinned = try #require(skills.first { $0["name"] as? String == "pinned-tool" })
        #expect(pinned["ownership"] as? String == "github")
        let pinnedProvenance = try #require(
            (pinned["provenance"] as? [String: Any])?["github"] as? [String: Any])
        #expect(pinnedProvenance["repo"] as? String == "https://github.com/thedavidweng/skills.git")
        #expect(pinnedProvenance["ref"] as? String == "refs/heads/main")
        #expect(pinnedProvenance["pinned"] as? Bool == true)
        #expect(pinnedProvenance["treeSha"] is String)

        let unpinned = try #require(skills.first { $0["name"] as? String == "unpinned-tool" })
        #expect(unpinned["ownership"] as? String == "github")
        let unpinnedProvenance = try #require(
            (unpinned["provenance"] as? [String: Any])?["github"] as? [String: Any])
        #expect(unpinnedProvenance["repo"] as? String == "https://github.com/thedavidweng/skills")
        #expect(unpinnedProvenance["pinned"] as? Bool == false)
    }

    // MARK: npx skills resolvable vs unresolvable

    @Test("cap-npx-ok reports resolvable with version; cap-npx-absent does not")
    func npxFixtures() throws {
        let resolvable = try capabilities(path: path(["cap-npx-ok"]))
        #expect(resolvable.exitCode == 0)
        let okObject = try #require(try resolvable.jsonObject())
        let okNpx = try #require(okObject["npx"] as? [String: Any])
        #expect(okNpx["resolvable"] as? Bool == true)
        #expect(okNpx["skillsVersion"] as? String == "1.5.26")

        let absent = try capabilities(path: path(["cap-npx-absent"]))
        #expect(absent.exitCode == 0)
        let absentObject = try #require(try absent.jsonObject())
        let absentNpx = try #require(absentObject["npx"] as? [String: Any])
        #expect(absentNpx["resolvable"] as? Bool == false)
        #expect(absentNpx["skillsVersion"] == nil)
        #expect(absentNpx["reason"] as? String == "absent")
        #expect(okNpx["reason"] == nil)
    }

    // MARK: Neither CLI: full read-only scan still completes

    @Test(
        "CM-3 scan under cap-neither is byte-identical to the full-capability scan",
        .disabled(
            if: !FileManager.default.fileExists(
                atPath: FixturePaths.tree("CM-3") + "/EXPECTATION.md"),
            "CM-3 is CLI-generated and gitignored; run SUKIRU_E2E=1 Scripts/fixtures/generate.sh"
        )
    )
    func neitherCliScanMatchesFullScan() throws {
        let inputs = FixturePaths.homeAndRoots("CM-3")
        let neither = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(
                home: inputs.home, roots: inputs.roots, path: path(["cap-neither"]))
        )
        let full = try CLIRunner.run(
            ["scan", "--format", "json"],
            environment: CLIRunner.fixtureEnvironment(
                home: inputs.home, roots: inputs.roots,
                path: path(["cap-gh-ok", "cap-npx-ok"]))
        )
        #expect(neither.exitCode == 0)
        #expect(full.exitCode == 0)
        // Scan never spawns subprocesses, so capability availability can
        // change NOTHING in the report — the outputs must be byte-identical.
        #expect(neither.stdout == full.stdout)

        let object = try #require(try neither.jsonObject())
        let skills = try #require(object["skills"] as? [[String: Any]])
        let findings = try #require(object["findings"] as? [[String: Any]])
        #expect(!skills.isEmpty, "CM-3 must produce a full inventory")
        #expect(!findings.isEmpty, "CM-3 must produce its expected findings")
    }
}
