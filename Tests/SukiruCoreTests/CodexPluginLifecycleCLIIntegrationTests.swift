import Foundation
import Testing

@Suite("Codex plugin lifecycle CLI")
struct CodexPluginLifecycleCLIIntegrationTests {
    /// A Git `team` marketplace snapshot listing `demo`, plus a local `lab`
    /// marketplace used in place.
    static func codex(
        version: String = "codex-cli 0.160.0", projects: [String] = [], onRun: String = ""
    ) throws -> PluginHostFixture {
        let fixture = try PluginHostFixture(
            host: "codex", version: version, help: "--json", projects: projects, onRun: onRun)
        let lab = try fixture.tree.dir("lab")
        try fixture.tree.file(
            "home/.codex/config.toml",
            contents: """
                [marketplaces."team"]
                source_type = "git"
                source = "https://example.test/team.git"
                ref = "main" # tracked branch

                [marketplaces.lab]
                source_type = "local"
                source = "\(lab)"

                [plugins."demo@team"]
                enabled = true

                [plugins."demo@team".options]
                verbose = 1
                """)
        try fixture.tree.file(
            "home/.codex/.tmp/marketplaces/team/.agents/plugins/marketplace.json",
            contents: #"{"name":"team","plugins":[{"name":"demo","source":{"path":"./demo"}}]}"#)
        try fixture.tree.file("home/.codex/plugins/data/demo-team/state", contents: "kept\n")
        return fixture
    }

    @Test(
        "Configured-marketplace and marketplace routes dispatch Codex's own argv",
        arguments: [
            ["install", "demo@team", "plugin add demo@team --json"],
            ["remove", "demo@team", "plugin remove demo@team --json"],
            [
                "marketplace-add", "https://example.test/other.git",
                "plugin marketplace add https://example.test/other.git --json"
            ],
            ["marketplace-refresh", "team", "plugin marketplace upgrade team --json"],
            ["marketplace-remove", "team", "plugin marketplace remove team --json"]
        ])
    func nativeRoutes(values: [String]) throws {
        let fixture = try Self.codex()
        let result = try fixture.plan([fixture.request(values[0], values[1])])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let command = try #require(try result.plannedCommands().first)
        #expect((command["argv"] as? [String])?.joined(separator: " ") == "codex " + values[2])
        #expect(fixture.invocations.isEmpty)
    }

    @Test(
        "Install, remove and marketplace changes keep their diff and roll back",
        arguments: [
            ["install", "demo@team"], ["remove", "demo@team"],
            ["marketplace-refresh", "team"], ["marketplace-remove", "team"]
        ])
    func roundTrip(values: [String]) throws {
        let fixture = try Self.codex(onRun: "rm -rf \"$HOME/.codex/plugins/data\"")
        let state = fixture.home + "/.codex/plugins/data/demo-team/state"
        let result = try fixture.execute([fixture.request(values[0], values[1])])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(!FileManager.default.fileExists(atPath: state))
        #expect(try fixture.rollback(result).exitCode == 0)
        #expect(try String(contentsOfFile: state, encoding: .utf8) == "kept\n")
    }

    @Test("Project scope, unconfigured sources and local marketplace refresh are refused")
    func refusals() throws {
        let fixture = try Self.codex(projects: ["project"])
        let project = try #require(fixture.roots.first)
        let projectScope = try fixture.plan([
            fixture.request("install", "demo@team", scope: "project", root: project)
        ])
        #expect(try projectScope.instructions().first?.contains("user scope only") == true)

        let unconfigured = try fixture.plan([fixture.request("install", "demo@nowhere")])
        #expect(unconfigured.exitCode != 0)
        #expect(unconfigured.stderrText.contains("configured host marketplace"))

        let local = try fixture.plan([fixture.request("marketplace-refresh", "lab")])
        #expect(try local.instructions().first?.contains("local Codex marketplace") == true)
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Marketplace removal states that Codex documents no uninstall cascade")
    func removalImpact() throws {
        let fixture = try Self.codex()
        let result = try fixture.plan([fixture.request("marketplace-remove", "team")])
        let warning = try #require(try result.plannedCommands().first?["warning"] as? String)
        #expect(warning.contains("no plugin-uninstall cascade"))
        #expect(warning.contains("demo@team"))
        #expect(!warning.contains("cascades to installations"))
    }

    @Test("Local marketplace add captures plugin sources named by the Codex catalog")
    func localAddCapture() throws {
        let fixture = try Self.codex()
        let external = try fixture.tree.dir("external-plugin")
        try fixture.tree.file(
            "new-catalog/.agents/plugins/marketplace.json",
            contents: #"{"name":"new","plugins":[{"name":"x","source":{"path":"\#(external)"}}]}"#)
        let result = try fixture.plan([
            fixture.request("marketplace-add", fixture.tree.path + "/new-catalog")
        ])
        let capture = try #require(try result.plannedCommands().first?["captureRoots"] as? [String])
        #expect(capture.contains(external))
    }

    @Test("Inventory reads scope, ref and source type passively despite subtables and comments")
    func passiveInventory() throws {
        let fixture = try Self.codex()
        let result = try CLIRunner.run(["scan"], environment: fixture.environment)
        #expect(result.exitCode == 0)
        #expect(fixture.invocations.isEmpty)
        let object = try #require(try result.jsonObject())
        let inventory = try #require(object["pluginInventory"] as? [String: Any])
        #expect((inventory["issues"] as? [Any])?.isEmpty != false)
        let plugin = try #require((inventory["installations"] as? [[String: Any]])?.first)
        #expect(plugin["installationStatus"] as? String == "configured")
        #expect(plugin["source"] as? String == "team")
        let catalogs = try #require(inventory["marketplaces"] as? [[String: Any]])
        let team = try #require(catalogs.first { $0["name"] as? String == "team" })
        #expect(team["scope"] as? String == "user")
        #expect(team["ref"] as? String == "main")
        #expect(team["localSource"] as? Bool == false)
        #expect(catalogs.first { $0["name"] as? String == "lab" }?["localSource"] as? Bool == true)
    }
}
