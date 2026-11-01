import Foundation
import Testing

@testable import SukiruCore

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
        try fixture.tree.file(
            "home/.codex/.tmp/marketplaces/team/.codex-marketplace-install.json",
            contents: """
                {"source_type":"git","source":"https://example.test/team.git",
                "ref_name":"main","sparse_paths":[],"revision":"fixture"}
                """)
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

    @Test("Marketplace JSON retains listing metadata without inventing sparse fields")
    func marketplaceMetadata() throws {
        let fixture = try Self.codex()
        try fixture.tree.file(
            "home/.codex/.tmp/marketplaces/team/.agents/plugins/marketplace.json",
            contents: """
                {"name":"team","plugins":[
                  {"name":"demo","source":{"path":"./demo"},"version":"1",
                   "description":"A useful plugin","author":{"name":"Example"},
                   "homepage":"https://example.test","repository":"https://example.test/repo",
                   "license":"MIT","category":"Tools","keywords":["swift"]},
                  {"name":"sparse","source":"./sparse"}
                ]}
                """)
        let result = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--host", "codex", "--json"],
            environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        let team = try #require(catalogs.first { $0["name"] as? String == "team" })
        let entries = try #require(team["plugins"] as? [[String: Any]])
        let demo = try #require(entries.first { $0["name"] as? String == "demo" })
        #expect(demo["summary"] as? String == "A useful plugin")
        #expect(demo["author"] as? String == "Example")
        #expect(demo["homepage"] as? String == "https://example.test")
        #expect(demo["repository"] as? String == "https://example.test/repo")
        #expect(demo["license"] as? String == "MIT")
        #expect(demo["categories"] as? [String] == ["Tools"])
        #expect(demo["keywords"] as? [String] == ["swift"])
        let sparse = try #require(entries.first { $0["name"] as? String == "sparse" })
        #expect(sparse["summary"] == nil)
        #expect(sparse["author"] == nil)
        #expect(fixture.invocations.isEmpty)
    }

}

extension CodexPluginLifecycleCLIIntegrationTests {
    @Test("An unconfigured marketplace install exposes a localizable planner reason")
    func missingMarketplaceReason() throws {
        let fixture = try Self.codex()
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": fixture.home]))
        let planner = PluginLifecyclePlanner(environment: environment)
        let inventory = PluginInventory(installations: [], marketplaces: [], issues: [])
        let request = PluginLifecycleRequest(
            host: .codex, action: "install", target: "demo@missing", scope: "user",
            scopeRoot: fixture.home)
        do {
            try planner.validateInstallMarketplace(request, inventory: inventory)
            Issue.record("Expected the unconfigured marketplace to be refused")
        } catch let error as PluginLifecycleError {
            #expect(error.message == "Choose a plugin from a configured host marketplace")
            guard case .chooseConfiguredMarketplace = error.reason else {
                Issue.record("The refusal must identify its localizable reason")
                return
            }
        }
    }

    @Test("Malformed Codex listings do not hide valid siblings")
    func mixedCatalogEntries() throws {
        let fixture = try Self.codex()
        try fixture.tree.file(
            "home/.codex/.tmp/marketplaces/team/.agents/plugins/marketplace.json",
            contents: #"{"plugins":[{"name":"valid","source":"./valid"},42,{}, {"name":""}]}"#)
        let result = try CLIRunner.run(["scan"], environment: fixture.environment)
        let inventory = try #require(try result.jsonObject()?["pluginInventory"] as? [String: Any])
        let markets = try #require(inventory["marketplaces"] as? [[String: Any]])
        let market = try #require(markets.first { $0["name"] as? String == "team" })
        let entries = try #require(market["plugins"] as? [[String: Any]])
        #expect(entries.compactMap { $0["name"] as? String } == ["valid"])
        let issues = try #require(inventory["issues"] as? [[String: Any]])
        #expect(issues.filter { ($0["path"] as? String)?.contains("team/") == true }.count == 3)
        #expect(issues.contains { $0["message"] as? String == "Invalid marketplace plugin entry" })
    }

    @Test("Inventory distinguishes missing, unreadable and readable catalogs")
    func catalogState() throws {
        let fixture = try Self.codex()
        try fixture.tree.file("lab/.agents/plugins/marketplace.json", contents: "{")
        try fixture.tree.file(
            "home/.codex/config.toml",
            contents: """
                [marketplaces.team]
                source_type = "git"
                source = "https://example.test/team.git"
                ref = "main"
                [marketplaces.lab]
                source_type = "local"
                source = "\(fixture.tree.path)/lab"
                [marketplaces.missing]
                source_type = "local"
                source = "\(fixture.tree.path)/missing"
                """)
        let result = try CLIRunner.run(["scan"], environment: fixture.environment)
        let inventory = try #require(try result.jsonObject()?["pluginInventory"] as? [String: Any])
        let markets = try #require(inventory["marketplaces"] as? [[String: Any]])
        #expect(
            markets.first { $0["name"] as? String == "team" }?["catalogState"] as? String
                == "available")
        #expect(
            markets.first { $0["name"] as? String == "lab" }?["catalogState"] as? String
                == "unreadable")
        #expect(
            markets.first { $0["name"] as? String == "missing" }?["catalogState"] as? String
                == "missing")
    }

    @Test("A user cache does not prove a project installation")
    func projectDeclarationDoesNotInheritPayload() throws {
        let fixture = try Self.codex(projects: ["project"])
        try fixture.tree.file(
            "project/.codex/config.toml", contents: "[plugins.\"demo@team\"]\nenabled = true\n")
        try fixture.tree.file(
            "home/.codex/plugins/cache/team/demo/1.0/plugin.json", contents: "{}")
        let result = try CLIRunner.run(["scan"], environment: fixture.environment)
        let inventory = try #require(try result.jsonObject()?["pluginInventory"] as? [String: Any])
        let plugins = try #require(inventory["installations"] as? [[String: Any]])
            .filter { $0["identifier"] as? String == "demo@team" }
        #expect(
            plugins.first { $0["scope"] as? String == "user" }?["installationStatus"] as? String
                == "installed")
        #expect(
            plugins.first { $0["scope"] as? String == "project" }?["installationStatus"] as? String
                == "configured")
    }

    @Test("A project-only marketplace cannot authorize a user installation")
    func projectMarketplaceDoesNotAuthorizeUserInstall() throws {
        let fixture = try Self.codex(projects: ["project"])
        try fixture.tree.file(
            "project/.codex/config.toml",
            contents: "[marketplaces.project-only]\nsource_type = \"local\"\nsource = \"catalog\"\n"
        )
        try fixture.tree.file(
            "project/catalog/.agents/plugins/marketplace.json",
            contents: #"{"name":"project-only","plugins":[{"name":"demo","source":"./demo"}]}"#)
        let result = try fixture.plan([fixture.request("install", "demo@project-only")])
        #expect(result.exitCode != 0)
        #expect(fixture.invocations.isEmpty)
    }

    @Test("A selected project catalog cannot silently install from a same-name user catalog")
    func selectedProjectCatalogIsNotUserCatalog() throws {
        let fixture = try Self.codex(projects: ["project"])
        let project = try #require(fixture.roots.first)
        try fixture.tree.file(
            "project/.codex/config.toml",
            contents: "[marketplaces.team]\nsource_type = \"local\"\nsource = \"catalog\"\n")
        try fixture.tree.file(
            "project/catalog/.agents/plugins/marketplace.json",
            contents: #"{"name":"team","plugins":[{"name":"demo","source":"./other"}]}"#)
        var request = fixture.request("install", "demo@team")
        request["selectedMarketplaceID"] = "codex:\(project):team:7:catalog::true"
        let result = try fixture.plan([request])
        #expect(result.exitCode != 0)
        #expect(fixture.invocations.isEmpty)
    }

    @Test("A selected user catalog remains installable while its source is unchanged")
    func selectedUserCatalog() throws {
        let fixture = try Self.codex()
        let source = "https://example.test/team.git"
        var request = fixture.request("install", "demo@team")
        request["selectedMarketplaceID"] =
            "codex:\(fixture.home):team:\(source.utf8.count):\(source):main:false"
        let result = try fixture.plan([request])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(try result.plannedCommands().count == 1)
    }

    @Test("Project-only marketplace cannot authorize user refresh or removal")
    func projectMarketplaceDoesNotAuthorizeUserManagement() throws {
        let fixture = try Self.codex(projects: ["project"])
        try fixture.tree.file(
            "project/.codex/config.toml",
            contents:
                "[marketplaces.project-only]\nsource_type = \"git\"\nsource = \"https://example.test/repo\"\n"
        )
        for action in ["marketplace-refresh", "marketplace-remove"] {
            let result = try fixture.plan([fixture.request(action, "project-only")])
            #expect(result.exitCode != 0)
        }
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Claude-format local catalog remains readable when a different catalog is malformed")
    func alternateCatalogAndInspectionError() throws {
        let fixture = try Self.codex()
        try fixture.tree.file(
            "lab/.claude-plugin/marketplace.json",
            contents:
                #"{"name":"lab","plugins":[{"name":"local","source":"./local","description":"Local listing"}]}"#
        )
        try fixture.tree.file(
            "home/.codex/.tmp/marketplaces/team/.agents/plugins/marketplace.json", contents: "{")
        let result = try CLIRunner.run(["scan"], environment: fixture.environment)
        let inventory = try #require(try result.jsonObject()?["pluginInventory"] as? [String: Any])
        let markets = try #require(inventory["marketplaces"] as? [[String: Any]])
        let lab = try #require(markets.first { $0["name"] as? String == "lab" })
        let entries = try #require(lab["plugins"] as? [[String: Any]])
        #expect(entries.first?["summary"] as? String == "Local listing")
        let issues = try #require(inventory["issues"] as? [[String: Any]])
        #expect(issues.contains { ($0["path"] as? String)?.contains("team") == true })
        #expect(fixture.invocations.isEmpty)
    }
}
