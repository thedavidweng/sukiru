import Foundation
import Testing

@testable import SukiruCore

/// The skills CLI is never fetched implicitly: the probe is offline, the
/// update check reads registry metadata, and only `fetch` downloads.
@Suite("skills CLI provisioning")
struct SkillsCLITests {
    private final class Calls: @unchecked Sendable {
        var argv: [[String]] = []
    }

    private struct RecordingRunner: CommandRunning {
        let outcome: ProcessOutcome?
        let calls = Calls()

        func run(_ executable: String, _ arguments: [String]) -> ProcessOutcome? {
            calls.argv.append([executable] + arguments)
            return outcome
        }
    }

    @Test("The launch probe never reaches the network")
    func probeIsOffline() {
        #expect(SkillsCLI.probeArguments.first == "--offline")
        #expect(!SkillsCLI.probeArguments.contains { $0.contains("@") || $0 == "-y" })
    }

    @Test("Latest version comes from the registry's latest tag")
    func latestVersion() async throws {
        let transport = StubMarketplaceTransport(responses: [
            SkillsCLI.latestReleaseURL.absoluteString: .success(
                Data(#"{"name":"skills","version":"1.7.0"}"#.utf8))
        ])
        #expect(try await SkillsCLI.latestVersion(transport: transport) == "1.7.0")
    }

    @Test("A malformed registry answer is an error, not a version")
    func latestVersionMalformed() async {
        let transport = StubMarketplaceTransport(responses: [
            SkillsCLI.latestReleaseURL.absoluteString: .success(Data("{}".utf8))
        ])
        await #expect(throws: MarketplaceError.self) {
            try await SkillsCLI.latestVersion(transport: transport)
        }
    }

    @Test("Only a newer release counts as an update")
    func updateComparison() {
        #expect(SkillsCLI.isUpdate("1.7.0", over: "1.5.26"))
        #expect(SkillsCLI.isUpdate("2.0", over: "1.99.9"))
        #expect(!SkillsCLI.isUpdate("1.7.0", over: "1.7.0"))
        #expect(!SkillsCLI.isUpdate("1.5.26", over: "1.7.0"))
    }

    @Test("Fetch runs npx online and reports the failure tail")
    func fetch() {
        let succeeding = RecordingRunner(
            outcome: ProcessOutcome(exitCode: 0, stdout: "1.7.0\n", stderr: ""))
        #expect(SkillsCLI.fetch(runner: succeeding) == nil)
        #expect(
            succeeding.calls.argv == [["npx", "--yes", "--prefer-online", "skills", "--version"]])

        let failing = RecordingRunner(
            outcome: ProcessOutcome(
                exitCode: 1, stdout: "", stderr: "a\nb\nnpm error code E404\nnpm error 404\n"))
        #expect(SkillsCLI.fetch(runner: failing) == "b\nnpm error code E404\nnpm error 404")

        #expect(SkillsCLI.fetch(runner: RecordingRunner(outcome: nil)) != nil)
    }
}
