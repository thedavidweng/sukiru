import Foundation
import Testing

struct DroidPluginTests {
    private let help = """
        Usage: droid plugin install|i [options] <plugin>
        Usage: droid plugin uninstall|remove [options] <plugin>
        Usage: droid plugin update [options] [plugin]
        Usage: droid plugin marketplace add [options] <url>
        Usage: droid plugin marketplace remove [options] <name>
        Usage: droid plugin marketplace update [options] [name]
          -s, --scope <scope>  Installation scope (choices: "user", "project")
        """

    /// The layout `droid` 1.1.0 wrote in an isolated home: one record per installation,
    /// enablement in the installing level's settings, and a marketplace registry.
    private func seed(_ fixture: PluginHostFixture) throws -> (cache: String, catalog: String) {
        let tree = fixture.tree
        let catalog = try tree.dir("mkt")
        try tree.file(
            "mkt/.factory-plugin/marketplace.json",
            contents: """
                {"name":"probe","plugins":[
                  {"name":"hello","description":"Says hello","source":"./hello",
                   "category":"test","tags":["greet"]},
                  {"name":"@scope/tool","source":{"source":"npm","package":"@scope/tool"}}]}
                """)
        let cache = try tree.dir("home/.factory/plugins/cache/mkt-1/hello-2/v1")
        try tree.file(
            "home/.factory/plugins/cache/mkt-1/hello-2/v1/.factory-plugin/plugin.json",
            contents: #"{"name":"hello","description":"Hello plugin"}"#)
        for file in [
            "skills/group/hi/SKILL.md", "droids/reviewer.md", "output-styles/notes.md",
            "commands/greet.md"
        ] {
            try tree.file("home/.factory/plugins/cache/mkt-1/hello-2/v1/" + file, contents: "x")
        }
        try tree.file(
            "home/.factory/plugins/cache/mkt-1/hello-2/v1/mcp.json",
            contents: #"{"mcpServers":{"api":{"command":"npx"}}}"#)
        for (name, scope) in [("hello-mkt-user", "user"), ("hello-mkt-project", "project")] {
            try tree.file(
                "home/.factory/plugins/installed_plugins/\(name).json",
                contents: """
                    {"schemaVersion":1,"pluginId":"hello@mkt","entry":{"scope":"\(scope)",
                     "installPath":"\(cache)","version":"v1","source":"mkt"}}
                    """)
        }
        try tree.file(
            "home/.factory/plugins/installed_plugins/org.json",
            contents: """
                {"schemaVersion":1,"pluginId":"core@corp","entry":{"scope":"org",
                 "installPath":"\(cache)","version":"v9","source":"corp"}}
                """)
        try seedSettings(fixture, catalog: catalog)
        return (cache, catalog)
    }

    private func seedSettings(_ fixture: PluginHostFixture, catalog: String) throws {
        let tree = fixture.tree
        try tree.file(
            "home/.factory/plugins/known_marketplaces/mkt-1.json",
            contents: """
                {"name":"mkt","entry":{"source":{"source":"local","path":"\(catalog)"},
                 "installLocation":"\(catalog)","lastUpdated":"2026-11-01T01:50:49Z"}}
                """)
        try tree.file(
            "home/.factory/settings.json",
            contents: """
                {"theme":"dark","extraKnownMarketplaces":{"mkt":{"source":{"source":"local","path":"\(catalog)"}}}}
                """)
        try tree.file(
            "home/.factory/org-managed-settings.cache.json",
            contents: """
                {"managedSettings":{"enabledPlugins":{"core@corp":true},"strictEnabledPlugins":true,
                 "extraKnownMarketplaces":{"corp":{"source":{"source":"github","repo":"corp/plugins","ref":"v2"}}}}}
                """)
        if let project = fixture.roots.first {
            try tree.file(
                String(project.dropFirst(tree.path.count + 1)) + "/.factory/settings.json",
                contents: """
                    {"enabledPlugins":{"hello@mkt":true},
                     "extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"team/plugins"}}}}
                    """)
        }
    }

    private func fixture(version: String = "1.1.0") throws -> PluginHostFixture {
        try PluginHostFixture(host: "droid", version: version, help: help, projects: ["project"])
    }

    @Test("Inventory reads Droid records, settings levels, org policy and fetched catalogs")
    func inventory() throws {
        let fixture = try fixture()
        _ = try seed(fixture)
        let project = try #require(fixture.roots.first)
        let result = try CLIRunner.run(["scan"], environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let inventory = try #require(
            try result.jsonObject()?["pluginInventory"] as? [String: Any])
        let plugins = try #require(inventory["installations"] as? [[String: Any]])
            .filter { $0["host"] as? String == "droid" }
        let state = Dictionary(
            uniqueKeysWithValues: plugins.map {
                ("\($0["identifier"]!)|\($0["scope"]!)", $0["enablement"] as? String)
            })
        #expect(
            state == [
                "hello@mkt|user": "disabled", "hello@mkt|project": "enabled",
                "core@corp|org": "enabled"
            ])
        let projectPlugin = try #require(plugins.first { $0["scope"] as? String == "project" })
        #expect(projectPlugin["scopeRoot"] as? String == project)
        let components = try #require(projectPlugin["components"] as? [[String: Any]])
        #expect(
            Set(components.map { "\($0["kind"]!):\($0["name"]!)" }) == [
                "skills:hi", "droids:reviewer.md", "outputStyles:notes.md", "commands:greet.md",
                "mcpServers:api"
            ])
        let marketplaces = try #require(inventory["marketplaces"] as? [[String: Any]])
            .filter { $0["host"] as? String == "droid" }
        let byName = Dictionary(
            uniqueKeysWithValues: marketplaces.map { ($0["name"] as? String ?? "", $0) })
        #expect(Set(byName.keys) == ["mkt", "corp", "team"])
        #expect(byName["corp"]?["scope"] as? String == "org")
        #expect(byName["corp"]?["evidence"] as? String == "org-managed")
        #expect(byName["corp"]?["ref"] as? String == "v2")
        #expect(byName["team"]?["scopeRoot"] as? String == project)
        #expect(byName["mkt"]?["updatedAt"] as? String == "2026-11-01T01:50:49Z")
        let listings = try #require(byName["mkt"]?["plugins"] as? [[String: Any]])
        #expect(listings.compactMap { $0["name"] as? String } == ["hello", "@scope/tool"])
        #expect(listings.first?["categories"] as? [String] == ["test"])
        #expect(listings.first?["keywords"] as? [String] == ["greet"])
        #expect(fixture.invocations.isEmpty && fixture.helpInvocations.isEmpty)
    }

    @Test("Native commands carry their scope and run in the scope's directory")
    func nativeCommands() throws {
        let fixture = try fixture()
        _ = try seed(fixture)
        let project = try #require(fixture.roots.first)
        let result = try fixture.plan([
            fixture.request("install", "hello@mkt"),
            fixture.request("install", "@scope/tool@mkt", scope: "project", root: project),
            fixture.request("update", "hello@mkt"),
            fixture.request("remove", "hello@mkt", scope: "project", root: project),
            fixture.request("marketplace-add", "Factory-AI/factory-plugins#v1.2.0"),
            fixture.request("marketplace-refresh", "mkt"),
            fixture.request("marketplace-remove", "mkt")
        ])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let commands = try result.plannedCommands()
        #expect(
            commands.compactMap { $0["argv"] as? [String] } == [
                ["droid", "plugin", "install", "hello@mkt", "--scope", "user"],
                ["droid", "plugin", "install", "@scope/tool@mkt", "--scope", "project"],
                ["droid", "plugin", "update", "hello@mkt", "--scope", "user"],
                ["droid", "plugin", "uninstall", "hello@mkt", "--scope", "project"],
                ["droid", "plugin", "marketplace", "add", "Factory-AI/factory-plugins#v1.2.0"],
                ["droid", "plugin", "marketplace", "update", "mkt"],
                ["droid", "plugin", "marketplace", "remove", "mkt"]
            ])
        #expect(commands.allSatisfy { $0["owningCLI"] as? String == "droid" })
        #expect(commands[1]["workingDirectory"] as? String == project)
        let roots = try #require(commands[0]["captureRoots"] as? [String])
        #expect(roots.contains(fixture.home + "/.factory/plugins"))
        #expect(roots.contains(fixture.home + "/.factory/settings.json"))
        #expect(roots.contains(project + "/.factory/settings.json"))
        let intents = commands.compactMap { $0["intent"] as? String }
        #expect(intents[0].contains("strictEnabledPlugins"))
        #expect(intents[6].contains("does not uninstall") && intents[6].contains("hello@mkt"))
        #expect(fixture.invocations.isEmpty)
        #expect(fixture.helpInvocations.contains("plugin marketplace update --help"))
    }

    @Test("Enablement and project marketplace declarations are reviewed settings edits")
    func settingsEdits() throws {
        let fixture = try fixture()
        _ = try seed(fixture)
        let project = try #require(fixture.roots.first)
        let settings = fixture.home + "/.factory/settings.json"
        let projectSettings = project + "/.factory/settings.json"
        let originals = try [settings, projectSettings].map {
            try String(contentsOfFile: $0, encoding: .utf8)
        }
        let result = try fixture.execute([
            fixture.request("enable", "hello@mkt"),
            fixture.request("disable", "hello@mkt", scope: "project", root: project),
            fixture.request("marketplace-remove", "team", scope: "project", root: project)
        ])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(fixture.invocations.isEmpty)
        let user =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: settings))) as? [String: Any]
        #expect((user?["enabledPlugins"] as? [String: Bool]) == ["hello@mkt": true])
        #expect(user?["theme"] as? String == "dark")
        let shared =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: projectSettings))) as? [String: Any]
        #expect((shared?["enabledPlugins"] as? [String: Bool]) == ["hello@mkt": false])
        #expect((shared?["extraKnownMarketplaces"] as? [String: Any])?.isEmpty == true)
        let restored = try fixture.rollback(result)
        #expect(restored.exitCode == 0, "\(restored.stderrText)")
        #expect(
            try [settings, projectSettings].map { try String(contentsOfFile: $0, encoding: .utf8) }
                == originals)
    }

    @Test("Unsupported routes return instructions; unlisted targets are refused")
    func limits() throws {
        let fixture = try fixture()
        _ = try seed(fixture)
        let project = try #require(fixture.roots.first)
        for (request, text) in [
            (fixture.request("check", "hello@mkt"), "no native check"),
            (
                fixture.request("marketplace-add", "team/x", scope: "project", root: project),
                "extraKnownMarketplaces"
            ),
            (fixture.request("marketplace-remove", "corp"), "org settings")
        ] {
            let result = try fixture.plan([request])
            #expect(result.exitCode == 0, "\(result.stderrText)")
            #expect(try result.instructions().first?.contains(text) == true)
        }
        for request in [
            fixture.request("install", "missing@mkt"),
            fixture.request("remove", "core@corp"),
            fixture.request("install", "hello@team")
        ] {
            #expect(try fixture.plan([request]).exitCode != 0)
        }
        let unknown = try self.fixture(version: "2.0.0")
        #expect(
            try unknown.plan([unknown.request("update", "hello@mkt")]).instructions().first?
                .contains("no verified") == true)
        #expect(fixture.invocations.isEmpty && unknown.invocations.isEmpty)
    }

    @Test("A native install captures Droid's plugin state for rollback")
    func rollback() throws {
        let fixture = try PluginHostFixture(
            host: "droid", version: "1.1.0", help: help,
            onRun: """
                mkdir -p "$HOME/.factory/plugins/installed_plugins"
                echo '{}' > "$HOME/.factory/plugins/installed_plugins/new.json"
                echo '{"enabledPlugins":{"hello@mkt":true}}' > "$HOME/.factory/settings.json"
                """)
        _ = try seed(fixture)
        let settings = fixture.home + "/.factory/settings.json"
        let original = try String(contentsOfFile: settings, encoding: .utf8)
        let result = try fixture.execute([fixture.request("install", "hello@mkt")])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(fixture.invocations == ["plugin install hello@mkt --scope user"])
        let restored = try fixture.rollback(result)
        #expect(restored.exitCode == 0, "\(restored.stderrText)")
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == original)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home + "/.factory/plugins/installed_plugins/new.json"))
    }
}
