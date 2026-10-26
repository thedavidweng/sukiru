import Foundation
import Testing

@testable import SukiruCore

@Suite("Codex plugin enablement CLI")
struct CodexPluginEnablementCLIIntegrationTests {
    static let config = """
        # Codex settings
        model = "gpt"

        [plugins."demo@team"] # pinned
        enabled = true  # on

        [plugins."demo@team".options]
        verbose = 1

        [plugins."lab@team"]
        # no explicit key

        """

    static func codex(projects: [String] = []) throws -> (PluginHostFixture, String) {
        let fixture = try PluginHostFixture(
            host: "codex", version: "codex-cli 0.160.0", help: "--json", projects: projects)
        let path = try fixture.tree.file("home/.codex/config.toml", contents: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return (fixture, path)
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("Disable then enable edits only the enabled value, keeping bytes and permissions")
    func roundTrip() throws {
        let (fixture, path) = try Self.codex()
        let plan = try fixture.plan([fixture.request("disable", "demo@team")])
        #expect(plan.exitCode == 0, "\(plan.stderrText)")
        let command = try #require(try plan.plannedCommands().first)
        let argv = try #require(command["argv"] as? [String])
        #expect(Array(argv.prefix(3)) == ["sukiru-fileop", "replace-config-source", path])
        #expect(command["dangerFlags"] as? [String] == ["direct-file-operation"])
        #expect(command["captureRoots"] as? [String] == [path])
        let warning = try #require(command["warning"] as? String)
        #expect(warning.contains("[plugins.\"demo@team\"] enabled = false in \(path)"))
        #expect(warning.contains("next session starts"))

        let disabled = try fixture.execute([fixture.request("disable", "demo@team")])
        #expect(disabled.exitCode == 0, "\(disabled.stderrText)")
        #expect(
            try contents(path)
                == Self.config.replacingOccurrences(
                    of: "enabled = true  # on", with: "enabled = false  # on"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let enabled = try fixture.execute([fixture.request("enable", "demo@team")])
        #expect(enabled.exitCode == 0, "\(enabled.stderrText)")
        #expect(try contents(path) == Self.config)
        #expect(fixture.invocations.isEmpty)
    }

    @Test("A table without enabled gets the key after its header, and rollback restores it")
    func insertionAndRollback() throws {
        let (fixture, path) = try Self.codex()
        let result = try fixture.execute([fixture.request("disable", "lab@team")])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(
            try contents(path)
                == Self.config.replacingOccurrences(
                    of: "[plugins.\"lab@team\"]\n",
                    with: "[plugins.\"lab@team\"]\nenabled = false\n"))
        #expect(try fixture.rollback(result).exitCode == 0)
        #expect(try contents(path) == Self.config)
    }

    @Test("Project scope edits only the project's .codex/config.toml")
    func projectScope() throws {
        let (fixture, userPath) = try Self.codex(projects: ["project"])
        let root = try #require(fixture.roots.first)
        let project = "[plugins.\"demo@team\"]\nenabled = true\n"
        let projectPath = try fixture.tree.file("project/.codex/config.toml", contents: project)
        let result = try fixture.execute([
            fixture.request("disable", "demo@team", scope: "project", root: root)
        ])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(try contents(projectPath) == "[plugins.\"demo@team\"]\nenabled = false\n")
        #expect(try contents(userPath) == Self.config)
    }

    @Test("Duplicate tables and unconfigured plugins are refused without an edit")
    func refusals() throws {
        let (fixture, path) = try Self.codex()
        let duplicate = Self.config + "[plugins.\"demo@team\"]\nenabled = true\n"
        try duplicate.write(toFile: path, atomically: true, encoding: .utf8)
        let refused = try fixture.execute([fixture.request("disable", "demo@team")])
        #expect(refused.exitCode != 0)
        #expect(refused.stderrText.contains("declared twice"))
        #expect(try contents(path) == duplicate)

        let missing = try fixture.plan([fixture.request("disable", "ghost@team")])
        #expect(missing.exitCode != 0)
        #expect(missing.stderrText.contains("not configured"))
        let already = try fixture.plan([fixture.request("enable", "demo@team")])
        #expect(already.exitCode != 0)
    }

    @Test("A file changed after review is refused before snapshot and left as is")
    func changedAfterReview() throws {
        let (fixture, path) = try Self.codex()
        let environment = ExecutorTestSupport.environment(home: fixture.home)
        let inventory = PluginInventoryReader(environment: environment).read(ScanRequest())
        let plan = try PluginLifecyclePlanner(environment: environment).plan(
            requests: [
                PluginLifecycleRequest(
                    host: .codex, action: "disable", target: "demo@team", scope: "user",
                    scopeRoot: fixture.home)
            ], inventory: inventory)
        let batch = try #require(plan.batch)
        let edited = "# later edit\n" + Self.config
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        let executor = ExecutorTestSupport.makeExecutor(
            home: fixture.home, shimPath: fixture.tree.path + "/bin")
        #expect(throws: (any Error).self) {
            try executor.execute(
                batch: try batch.transitioned(to: .reviewed),
                report: ExecutorTestSupport.userReport(home: fixture.home))
        }
        #expect(try contents(path) == edited)
        let operation = try #require(batch.commands.first?.fileOperation)
        #expect(throws: (any Error).self) { try operation.perform() }
        #expect(try contents(path) == edited)
    }

    @Test("The plugins disable subcommand edits the Codex config")
    func subcommand() throws {
        let (fixture, path) = try Self.codex()
        let result = try CLIRunner.run(
            [
                "plugins", "disable", "demo@team", "--host", "codex", "--scope", "user", "--yes",
                "--confirm-dangerous"
            ], environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(try contents(path).contains("enabled = false  # on"))
    }

    @Test("Capabilities no longer list Codex enable or disable as limits")
    func capabilities() throws {
        let (fixture, _) = try Self.codex()
        let result = try CLIRunner.run(
            ["plugins", "capabilities", "--host", "codex"], environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let object = try #require(try result.jsonObject())
        let limits = try #require(object["limits"] as? [String: String])
        #expect(limits["enable"] == nil)
        #expect(limits["disable"] == nil)
        let native = try #require(object["nativeCandidates"] as? [String])
        #expect(native.contains("enable") && native.contains("disable"))
    }
}
