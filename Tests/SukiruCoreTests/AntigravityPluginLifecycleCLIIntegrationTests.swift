import Foundation
import Testing

struct AntigravityPluginLifecycleTests {
    private let help = """
        Usage: agy plugin
          list [--json]
          import [source]
          install <target>
          uninstall <name>
          enable <name>
          disable <name>
          validate [path] [--strict] [--json]
          link <mp> <target>
        """

    @Test("Antigravity plans every native verb using directory targets and safe help probes")
    func nativeArguments() throws {
        let fixture = try PluginHostFixture(
            host: "antigravity", version: "1.4.7", help: help, helpOnStderr: true)
        var requests = [
            fixture.request("install", "demo@antigravity-plugins-official"),
            fixture.request("remove", "-123"), fixture.request("enable", "-123"),
            fixture.request("disable", "-123"), fixture.request("list", "*"),
            fixture.request("import", "*"), fixture.request("import", "gemini"),
            fixture.request("link", "demo")
        ]
        requests[7]["marketplace"] = "test-marketplace"
        let result = try fixture.plan(requests)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let commands = try result.plannedCommands()
        #expect(
            commands.compactMap { $0["argv"] as? [String] } == [
                ["agy", "plugin", "install", "demo@antigravity-plugins-official"],
                ["agy", "plugin", "uninstall", "-123"], ["agy", "plugin", "enable", "-123"],
                ["agy", "plugin", "disable", "-123"], ["agy", "plugin", "list", "--json"],
                ["agy", "plugin", "import"], ["agy", "plugin", "import", "gemini"],
                ["agy", "plugin", "link", "test-marketplace", "demo"]
            ])
        #expect(commands.allSatisfy { $0["owningCLI"] as? String == "antigravity" })
        #expect(fixture.invocations.isEmpty)
        #expect(!fixture.helpInvocations.isEmpty)
        #expect(
            fixture.helpInvocations.allSatisfy {
                ["plugin --help", "plugin validate --help"].contains($0)
            })
    }

    @Test("Install distinguishes marketplace, GitHub repository and local directory sources")
    func installSources() throws {
        let fixture = try PluginHostFixture(
            host: "antigravity", version: "1.4.7", help: help, helpOnStderr: true)
        let result = try fixture.plan([
            fixture.request("install", "stripe@antigravity-plugins-partners"),
            fixture.request("install", "git@github.com:stripe/ai.git"),
            fixture.request("install", "/tmp/demo-plugin")
        ])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let commands = try result.plannedCommands()
        #expect(
            commands.compactMap { $0["argv"] as? [String] } == [
                ["agy", "plugin", "install", "stripe@antigravity-plugins-partners"],
                ["agy", "plugin", "install", "https://github.com/stripe/ai"],
                ["agy", "plugin", "install", "/tmp/demo-plugin"]
            ])
        let intents = commands.compactMap { $0["intent"] as? String }
        #expect(
            intents[0].contains("from the Antigravity marketplace antigravity-plugins-partners"))
        #expect(
            intents[1].contains("not from a marketplace") && intents[1].contains("default branch"))
        #expect(intents[2].contains("local directory"))
        for target in ["stripe", "https://gitlab.com/owner/repo"] {
            let refused = try fixture.plan([fixture.request("install", target)])
            #expect(refused.exitCode != 0)
        }
        #expect(fixture.invocations.isEmpty)
    }
    @Test("Public CLI exposes import, validate, link, inspection and signed directory targets")
    func commandSurface() throws {
        let fixture = try PluginHostFixture(
            host: "antigravity", version: "1.4.7", help: help, helpOnStderr: true)
        for (arguments, expected) in [
            (["import"], ["import"]),
            (["validate", "--strict"], ["validate", ".", "--json", "--strict"]),
            (["link", "demo", "--marketplace", "test"], ["link", "test", "demo"]),
            (["inspect", "--host", "antigravity-cli"], ["list", "--json"]),
            (
                [
                    "disable", "--host", "antigravity", "--json", "--scope", "user", "--dry-run",
                    "--", "-123"
                ], ["disable", "-123"]
            )
        ] {
            let hasTerminator = arguments.contains("--")
            let options = hasTerminator ? [] : ["--scope", "user", "--dry-run", "--json"]
            let result = try CLIRunner.run(
                ["plugins"] + arguments + options,
                environment: fixture.environment)
            #expect(result.exitCode == 0, "\(result.stderrText)")
            let command = try #require(try result.plannedCommands().first)
            #expect(command["argv"] as? [String] == ["agy", "plugin"] + expected)
        }
        #expect(fixture.invocations.isEmpty)
        #expect(!fixture.helpInvocations.isEmpty)
        #expect(
            fixture.helpInvocations.allSatisfy {
                ["plugin --help", "plugin validate --help"].contains($0)
            })
    }

    @Test(
        "Unverified versions, unsupported operations and project installs return host instructions")
    func capabilityLimits() throws {
        let fixture = try PluginHostFixture(
            host: "antigravity", version: "1.4.7", help: help,
            projects: ["project"])
        for action in [
            "update", "replace", "check", "marketplace-add", "marketplace-refresh",
            "marketplace-remove"
        ] {
            let result = try fixture.plan([fixture.request(action, "demo")])
            #expect(result.exitCode == 0)
            #expect(try result.instructions().first?.contains("Customizations") == true)
            #expect(try result.jsonObject()?["batch"] == nil)
        }
        let project = try #require(fixture.roots.first)
        let scoped = try fixture.plan([
            fixture.request("install", "demo", scope: "project", root: project)
        ])
        #expect(try scoped.instructions().first?.contains("user plugins only") == true)
        let unknown = try PluginHostFixture(host: "antigravity", version: "2.0.0", help: help)
        #expect(
            try unknown.plan([unknown.request("enable", "demo")]).instructions().first?.contains(
                "no verified") == true)
        #expect(fixture.invocations.isEmpty && unknown.invocations.isEmpty)
    }

    @Test(
        "User-scoped CLI enablement previews matching project plugins and captures ancestor discovery"
    )
    func sharedScopeImpact() throws {
        let fixture = try PluginHostFixture(
            host: "antigravity", version: "1.4.7", help: help,
            projects: ["repo/sub"])
        try fixture.tree.dir("repo/.git")
        try fixture.tree.file("repo/.agents/plugins/demo/plugin.json", contents: "{}")
        try fixture.tree.file("home/.gemini/config/plugins/demo/plugin.json", contents: "{}")
        let result = try CLIRunner.run(
            ["plugins", "disable", "demo", "--host", "antigravity", "--scope", "user", "--dry-run"],
            environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let command = try #require(try result.plannedCommands().first)
        let intent = try #require(command["intent"] as? String)
        #expect(intent.contains("user:") && intent.contains("project:"))
        let roots = try #require(command["captureRoots"] as? [String])
        #expect(roots.contains(fixture.tree.path + "/repo/.agents"))
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Built-in and external payloads cannot be removed through user uninstall")
    func externalRemoval() throws {
        let fixture = try PluginHostFixture(host: "antigravity", version: "1.4.7", help: help)
        try fixture.tree.file(
            "home/.gemini/antigravity-cli/builtin/plugins/demo/plugin.json", contents: "{}")
        let result = try fixture.plan([fixture.request("remove", "demo")])
        #expect(try result.instructions().first?.contains("cannot delete") == true)
        #expect(fixture.invocations.isEmpty)
    }

    @Test(
        "Native mutations capture payloads, preferences, import records and catalogs for rollback")
    func rollback() throws {
        let fixture = try PluginHostFixture(
            host: "antigravity", version: "1.4.7", help: help,
            onRun: """
                mkdir -p "$HOME/.gemini/config/plugins/demo"
                echo '{"version":"new"}' > "$HOME/.gemini/config/plugins/demo/plugin.json"
                echo '{"plugins":{"demo":{"enabled":false}}}' > "$HOME/.gemini/config/config.json"
                echo '{"imports":[{"name":"demo"}]}' > "$HOME/.gemini/config/import_manifest.json"
                mkdir -p "$HOME/.gemini/antigravity-cli/cache/marketplaces/new"
                echo '{"name":"new","plugins":[]}' > \\
                  "$HOME/.gemini/antigravity-cli/cache/marketplaces/new/marketplace.json"
                """)
        let manifest = try fixture.tree.file(
            "home/.gemini/config/plugins/demo/plugin.json", contents: "{\"version\":\"old\"}")
        let settings = try fixture.tree.file(
            "home/.gemini/config/config.json", contents: "{\"plugins\":{}}")
        let result = try fixture.execute([fixture.request("disable", "demo")])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(fixture.invocations == ["plugin disable demo"])
        #expect(try String(contentsOfFile: settings, encoding: .utf8).contains("false"))
        let restored = try fixture.rollback(result)
        #expect(restored.exitCode == 0, "\(restored.stderrText)")
        #expect(try String(contentsOfFile: manifest, encoding: .utf8) == "{\"version\":\"old\"}")
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == "{\"plugins\":{}}")
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home + "/.gemini/config/import_manifest.json"))
        #expect(!FileManager.default.fileExists(atPath: fixture.home + "/.gemini/antigravity-cli"))
    }
}
