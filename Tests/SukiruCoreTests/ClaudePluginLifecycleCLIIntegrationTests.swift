import Foundation
import Testing

@Suite("Claude Code plugin lifecycle CLI")
struct ClaudePluginLifecycleCLIIntegrationTests {
    static let help = "--json --scope"

    /// A configured `team` marketplace whose catalog lists `demo`, and a
    /// user-scope `demo@team` installation with persistent data.
    static func claude(
        version: String = "2.1.288", help: String = help, projects: [String] = [],
        catalogEntry: String = #"{"name":"demo","source":"./demo"}"#, onRun: String = ""
    ) throws -> PluginHostFixture {
        let fixture = try PluginHostFixture(
            host: "claude", version: version, help: help, projects: projects, onRun: onRun)
        let catalog = try fixture.tree.dir("catalog")
        try fixture.tree.file(
            "home/.claude/plugins/known_marketplaces.json",
            contents: """
                {"team":{"source":{"source":"github","repo":"example/team"},"installLocation":"\(catalog)"}}
                """)
        try fixture.tree.file(
            "catalog/.claude-plugin/marketplace.json",
            contents: #"{"name":"team","plugins":[\#(catalogEntry)]}"#)
        let payload = try fixture.tree.dir("home/.claude/plugins/cache/team/demo/1.0.0")
        try fixture.tree.file(
            "home/.claude/plugins/installed_plugins.json",
            contents: """
                {"version":2,"plugins":{"demo@team":[{"scope":"user","installPath":"\(payload)","version":"1.0.0"}]}}
                """)
        try fixture.tree.file("home/.claude/plugins/data/demo-team/options", contents: "saved\n")
        try fixture.tree.file(
            "home/.claude/settings.json",
            contents:
                #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"example/team"}}}}"#
        )
        return fixture
    }

    @Test(
        "Native routes dispatch the host's own argv and scope",
        arguments: [
            ["install", "demo@team", "plugin install demo@team --scope user --json"],
            ["update", "demo@team", "plugin update demo@team --scope user --json"],
            ["remove", "demo@team", "plugin remove demo@team --scope user --json"],
            ["enable", "demo@team", "plugin enable demo@team --scope user --json"],
            ["disable", "demo@team", "plugin disable demo@team --scope user --json"],
            [
                "marketplace-add", "example/other",
                "plugin marketplace add example/other --scope user --json"
            ],
            ["marketplace-refresh", "team", "plugin marketplace update team --json"],
            ["marketplace-remove", "team", "plugin marketplace remove team --scope user --json"]
        ])
    func nativeRoutes(values: [String]) throws {
        let fixture = try Self.claude()
        let result = try fixture.plan([fixture.request(values[0], values[1])])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let command = try #require(try result.plannedCommands().first)
        #expect((command["argv"] as? [String])?.joined(separator: " ") == "claude " + values[2])
        #expect(fixture.invocations.isEmpty)
    }

    @Test(
        "Every native route runs once, keeps its diff, and rolls back settings byte for byte",
        arguments: [
            ["install", "demo@team"], ["update", "demo@team"], ["remove", "demo@team"],
            ["enable", "demo@team"], ["marketplace-add", "example/other"],
            ["marketplace-refresh", "team"], ["marketplace-remove", "team"]
        ])
    func roundTrip(values: [String]) throws {
        let fixture = try Self.claude(onRun: "printf '{}' > \"$HOME/.claude/settings.json\"")
        let settings = fixture.home + "/.claude/settings.json"
        let original = try String(contentsOfFile: settings, encoding: .utf8)
        let result = try fixture.execute([fixture.request(values[0], values[1])])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(fixture.invocations.count == 1)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == "{}")
        let rollback = try fixture.rollback(result)
        #expect(rollback.exitCode == 0, "\(rollback.stderrText)")
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == original)
    }
}

extension ClaudePluginLifecycleCLIIntegrationTests {
    @Test(
        "Claude's main configuration is restored after a native marketplace command",
        arguments: [false, true])
    func mainConfigurationRollback(preexisting: Bool) throws {
        let fixture = try Self.claude(onRun: "printf '%s' changed > \"$HOME/.claude.json\"")
        let config = fixture.home + "/.claude.json"
        if preexisting {
            try fixture.tree.file("home/.claude.json", contents: "original bytes\n")
        }
        let result = try fixture.execute([fixture.request("marketplace-add", "example/other")])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == "changed")
        let rollback = try fixture.rollback(result)
        #expect(rollback.exitCode == 0)
        if preexisting {
            #expect(try String(contentsOfFile: config, encoding: .utf8) == "original bytes\n")
        } else {
            #expect(!FileManager.default.fileExists(atPath: config))
        }
    }

    @Test(
        "Retargeted settings links require a choice and protect both targets",
        arguments: [false, true])
    func terminalLinkRollback(preserve: Bool) throws {
        let fixture = try Self.claude(onRun: "printf '{}' > \"$HOME/.claude/settings.json\"")
        let settings = fixture.home + "/.claude/settings.json"
        try FileManager.default.removeItem(atPath: settings)
        let original = try fixture.tree.file(
            "external/original.json", contents: #"{"original":true}"#)
        let replacement = try fixture.tree.file(
            "external/replacement.json", contents: #"{"later":true}"#)
        let link = try fixture.tree.symlink("home/.claude/settings.json", to: original)
        let executed = try fixture.execute([fixture.request("marketplace-add", "example/other")])
        #expect(executed.exitCode == 0, "\(executed.stderrText)")
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "{}")
        let record = try #require(try executed.jsonObject())
        let batch = try #require(record["batchID"] as? String)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: replacement)
        let preview = try CLIRunner.run(
            ["rollback", "--batch", batch, "--dry-run"], environment: fixture.environment)
        let conflicts = try #require(try preview.jsonObject()?["conflicts"] as? [[String: Any]])
        #expect(conflicts.contains { $0["path"] as? String == link })
        let refused = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batch], environment: fixture.environment)
        #expect(refused.exitCode != 0)
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "{}")
        #expect(try String(contentsOfFile: replacement, encoding: .utf8) == #"{"later":true}"#)
        let rollback = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batch, preserve ? "--preserve" : "--restore", link],
            environment: fixture.environment)
        #expect(rollback.exitCode == 0, "\(rollback.stderrText)")
        let items = try #require(try rollback.jsonObject()?["items"] as? [[String: Any]])
        #expect(!items.contains { $0["category"] as? String == "unrestorable-with-reason" })
        #expect(try String(contentsOfFile: original, encoding: .utf8) == #"{"original":true}"#)
        #expect(try String(contentsOfFile: replacement, encoding: .utf8) == #"{"later":true}"#)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link)
                == (preserve ? replacement : original))
    }
}

extension ClaudePluginLifecycleCLIIntegrationTests {
    @Test("Uninstall discloses data deletion and the installations that stay in other scopes")
    func removeImpact() throws {
        let fixture = try Self.claude(projects: ["project"])
        let project = try #require(fixture.roots.first)
        let payload = fixture.home + "/.claude/plugins/cache/team/demo/1.0.0"
        try fixture.tree.file(
            "home/.claude/plugins/installed_plugins.json",
            contents: """
                {"version":2,"plugins":{"demo@team":[
                  {"scope":"user","installPath":"\(payload)","version":"1.0.0"},
                  {"scope":"project","projectPath":"\(project)","installPath":"\(payload)","version":"1.0.0"}]}}
                """)
        let result = try fixture.plan([fixture.request("remove", "demo@team")])
        let warning = try #require(try result.plannedCommands().first?["warning"] as? String)
        #expect(warning.contains("--keep-data"))
        #expect(warning.contains("saved options and secrets"))
        #expect(warning.contains("project: \(project)"))
        #expect(warning.contains("same payload path"))
        #expect(try result.plannedCommands().first?["dangerFlags"] as? [String] != [])
    }

    @Test("A version-locked catalog entry refuses update instead of editing the lock")
    func versionLock() throws {
        let fixture = try Self.claude(
            catalogEntry:
                #"{"name":"demo","source":{"source":"github","repo":"example/demo","sha":"abc"}}"#)
        let result = try fixture.plan([fixture.request("update", "demo@team")])
        #expect(result.exitCode != 0)
        #expect(result.stderrText.contains("version-locked"))
        #expect(fixture.invocations.isEmpty)
    }

    @Test("Install accepts only plugins from a configured host marketplace")
    func unconfiguredMarketplace() throws {
        let fixture = try Self.claude()
        for target in ["demo@elsewhere", "missing@team", "demo"] {
            let result = try fixture.plan([fixture.request("install", target)])
            #expect(result.exitCode != 0)
            #expect(result.stderrText.contains("configured host marketplace"))
        }
    }

    @Test("Newer releases run once help exposes the flags; older ones get instructions")
    func versionContract() throws {
        let newer = try Self.claude(version: "2.3.0 (Claude Code)")
        #expect(
            try newer.plan([newer.request("update", "demo@team")]).plannedCommands().count == 1)

        let changed = try Self.claude(version: "2.3.0", help: "--scope")
        let refused = try changed.plan([changed.request("update", "demo@team")])
        #expect(refused.exitCode != 0)
        #expect(refused.stderrText.contains("required operation flags"))

        let older = try Self.claude(version: "2.1.287")
        let instructions = try older.plan([older.request("update", "demo@team")]).instructions()
        #expect(instructions.first?.contains("2.1.288+") == true)
    }

    @Test("Managed installations accept update only")
    func managedScope() throws {
        let fixture = try Self.claude()
        let update = try fixture.plan([fixture.request("update", "demo@team", scope: "managed")])
        let argv = try #require(try update.plannedCommands().first?["argv"] as? [String])
        #expect(argv.suffix(3) == ["--scope", "managed", "--json"])
        let remove = try fixture.plan([fixture.request("remove", "demo@team", scope: "managed")])
        #expect(remove.exitCode != 0)
    }

    @Test("Marketplace scopes stay distinct; removal from a non-final scope does not cascade")
    func marketplaceScopes() throws {
        let fixture = try Self.claude(projects: ["project"])
        let project = try #require(fixture.roots.first)
        let declaration =
            #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"example/team"}}}}"#
        try fixture.tree.file("project/.claude/settings.local.json", contents: declaration)
        try fixture.tree.file("home/.claude/settings.json", contents: declaration)

        let list = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--json"], environment: fixture.environment)
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: list.stdout) as? [[String: Any]])
        let scopes = catalogs.filter { $0["name"] as? String == "team" }
            .compactMap { $0["scope"] as? String }.sorted()
        #expect(scopes == ["local", "user"])

        let local = try fixture.plan([
            fixture.request("marketplace-remove", "team", scope: "local", root: project)
        ])
        let command = try #require(try local.plannedCommands().first)
        #expect((command["argv"] as? [String])?.suffix(3) == ["--scope", "local", "--json"])
        #expect((command["warning"] as? String)?.contains("not its final scope") == true)

        let undeclared = try fixture.plan([
            fixture.request("marketplace-remove", "team", scope: "project", root: project)
        ])
        #expect(undeclared.exitCode != 0)
        #expect(undeclared.stderrText.contains("not declared in project scope"))
    }

    @Test("A registry cache is not another declaration when removing the final project scope")
    func finalProjectMarketplaceRemoval() throws {
        let fixture = try Self.claude(projects: ["project"])
        try fixture.tree.file("home/.claude/settings.json", contents: "{}")
        let project = try #require(fixture.roots.first)
        try fixture.tree.file(
            "project/.claude/settings.json",
            contents:
                #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"example/team"}}}}"#
        )
        let result = try fixture.plan([
            fixture.request("marketplace-remove", "team", scope: "project", root: project)
        ])
        let warning = try #require(try result.plannedCommands().first?["warning"] as? String)
        #expect(warning.contains("may be the final scope"))
        #expect(warning.contains("demo@team"))
        #expect(warning.contains("secrets and data may be deleted"))
    }

    @Test("Catalog entries with typed sources keep their source instead of 'inline'")
    func typedCatalogSource() throws {
        let fixture = try Self.claude(
            catalogEntry: #"{"name":"demo","source":{"source":"github","repo":"example/demo"}}"#)
        let list = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--json"], environment: fixture.environment)
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: list.stdout) as? [[String: Any]])
        let entry = try #require((catalogs.first?["plugins"] as? [[String: Any]])?.first)
        #expect(entry["source"] as? String == "github:example/demo")
    }

    @Test("The product CLI reaches Claude's local settings scope")
    func settingsScopeShortcut() throws {
        let fixture = try Self.claude(projects: ["project"])
        let project = try #require(fixture.roots.first)
        let result = try CLIRunner.run(
            [
                "plugins", "disable", "demo@team", "--host", "claude-code", "--scope", "project",
                "--root", project, "--settings-scope", "local", "--dry-run", "--json"
            ], environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        let argv = try #require(try result.plannedCommands().first?["argv"] as? [String])
        #expect(argv.suffix(3) == ["--scope", "local", "--json"])
    }

    @Test("A failing first plugin command stops the batch before the next one runs")
    func firstErrorStops() throws {
        let fixture = try Self.claude(onRun: "exit 1")
        let result = try fixture.execute([
            fixture.request("disable", "demo@team"), fixture.request("update", "demo@team")
        ])
        #expect(result.exitCode != 0)
        #expect(fixture.invocations == ["plugin disable demo@team --scope user --json"])
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "failed")
        #expect(record["diff"] != nil)
    }
}
