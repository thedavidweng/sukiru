import Foundation
import Testing

struct CursorPluginCLIIntegrationTests {
    @Test("Unreadable Cursor component directories report an inspection Problem")
    func unreadableComponents() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.cursor/plugins/local/demo/.cursor-plugin/plugin.json",
            contents: "{\"name\":\"demo\"}")
        let commands = try tree.dir("home/.cursor/plugins/local/demo/commands")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: commands)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: commands)
        }
        let result = try CLIRunner.run(
            ["plugins", "health", "--host", "cursor"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        let json = try #require(try result.jsonObject())
        let issues = try #require(json["issues"] as? [[String: Any]])
        #expect(
            issues.contains {
                $0["path"] as? String == commands && $0["kind"] as? String == "plugin-config"
            })
    }

    @Test(
        "Cursor root skills load only without a skills directory or declaration",
        arguments: ["root", "directory", "declared"])
    func rootSkillDiscovery(mode: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let declaration = mode == "declared" ? ",\"skills\":\"custom\"" : ""
        try tree.file(
            "home/.cursor/plugins/local/demo/.cursor-plugin/plugin.json",
            contents: "{\"name\":\"demo\"\(declaration)}")
        try tree.file("home/.cursor/plugins/local/demo/SKILL.md", contents: "Root skill")
        if mode == "directory" { try tree.dir("home/.cursor/plugins/local/demo/skills") }
        let result = try CLIRunner.run(
            ["plugins", "list", "--host", "cursor"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        let plugins = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        let components = try #require(plugins.first?["components"] as? [[String: Any]])
        #expect(
            components.filter { $0["kind"] as? String == "skills" }.count
                == (mode == "root" ? 1 : 0))
    }

    @Test("Cursor local plugins expose both formats without executing the host")
    func localInventory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.cursor/plugins/local/portable/plugin.json",
            contents: "{\"name\":\"portable\",\"version\":\"1.0.0\"}")
        try tree.file(
            "home/.cursor/plugins/local/native/.cursor-plugin/plugin.json",
            contents:
                """
                {"name":"native","variables":{"type":"object","properties":{
                  "TOKEN":{"type":"string","default":"private-value"}}}}
                """
        )
        try tree.file(
            "home/.cursor/plugins/local/native/rules/style.mdc",
            contents: "---\ndescription: Style\n---\nUse Swift")
        try tree.file(
            "home/.cursor/plugins/local/portable/skills/review/SKILL.md", contents: "Review")
        let marker = tree.path + "/invoked"
        try tree.executable("bin/agent", contents: "#!/bin/sh\ntouch '\(marker)'\nexit 91\n")
        let result = try CLIRunner.run(
            ["plugins", "list", "--host", "cursor", "--json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let plugins = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        #expect(plugins.count == 2)
        #expect(
            plugins.allSatisfy {
                $0["enablement"] as? String == "unknown" && $0["loadStatus"] as? String == "unknown"
                    && $0["installationStatus"] as? String == "discovered"
            })
        let native = try #require(plugins.first { $0["identifier"] as? String == "native" })
        let components = try #require(native["components"] as? [[String: Any]])
        #expect(
            components.contains {
                $0["kind"] as? String == "rules" && $0["name"] as? String == "style.mdc"
            })
        #expect(
            components.contains {
                $0["kind"] as? String == "variables" && $0["name"] as? String == "TOKEN"
            })
        #expect(String(bytes: result.stdout, encoding: .utf8)?.contains("private-value") == false)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Cursor cache never proves enablement and local symlinks obey containment")
    func cacheAndContainment() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let external = try tree.dir("external")
        try tree.file("external/plugin.json", contents: "{\"name\":\"external\"}")
        try tree.file(
            "home/.cursor/plugins/local/demo/plugin.json", contents: "{\"name\":\"demo\"}")
        try tree.file(
            "home/.cursor/plugins/local/broken/.cursor-plugin/plugin.json", contents: "{broken")
        try tree.file(
            "home/.cursor/plugins/cache/cursor-public/demo/one/plugin.json",
            contents: "{\"name\":\"demo\"}")
        try tree.file(
            "home/.cursor/plugins/cache/cursor-public/demo/two/plugin.json",
            contents: "{\"name\":\"demo\"}")
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.cursor/plugins/local/outside", withDestinationPath: external)
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.cursor/plugins/local/alias", withDestinationPath: "demo")
        let result = try CLIRunner.run(
            ["plugins", "health", "--host", "cursor"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        let plugins = try #require(json["installations"] as? [[String: Any]])
        #expect(plugins.count == 4)
        #expect(Set(plugins.compactMap { $0["id"] as? String }).count == 4)
        #expect(plugins.filter { $0["installationStatus"] as? String == "cached" }.count == 2)
        #expect(plugins.allSatisfy { $0["enablement"] as? String == "unknown" })
        let issues = try #require(json["issues"] as? [[String: Any]])
        #expect(issues.contains { $0["kind"] as? String == "plugin-containment" })
        #expect(
            issues.contains {
                $0["path"] as? String == home
                    + "/.cursor/plugins/local/broken/.cursor-plugin/plugin.json"
            })
    }

    @Test("Cursor marketplace catalog files are passive cache evidence")
    func marketplaceInventory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.cursor/plugins/marketplaces/example.com/team/repo/one/.cursor-plugin/marketplace.json",
            contents:
                """
                {"name":"personal","plugins":[
                  {"name":"demo","source":"./plugins/demo","version":"1"},
                  {"name":"native","source":{"path":"./plugins/native"},"version":"2"}]}
                """
        )
        let result = try CLIRunner.run(
            ["plugins", "marketplaces", "list", "--host", "cursor"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 0)
        let catalogs = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        #expect(catalogs.count == 1)
        #expect(catalogs.first?["name"] as? String == "personal")
        #expect(catalogs.first?["evidence"] as? String == "cached-catalog")
        #expect(
            (catalogs.first?["plugins"] as? [[String: Any]])?.first?["name"] as? String == "demo")
        let entries = try #require(catalogs.first?["plugins"] as? [[String: Any]])
        #expect(
            entries.contains {
                $0["name"] as? String == "native" && $0["source"] as? String == "./plugins/native"
            })
    }

    @Test("Cursor explicit skill directories and mixed MCP declarations are inspected")
    func declaredComponents() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.cursor/plugins/local/demo/.cursor-plugin/plugin.json",
            contents: """
                {"name":"demo","skills":"custom/review","rules":"custom/style.mdc",
                 "mcpServers":[{"inline":{"command":"never-run"}},"custom/mcp.json"],
                 "hooks":{"hooks":{"afterFileEdit":[{"command":"never-run"}]}}}
                """)
        try tree.file("home/.cursor/plugins/local/demo/custom/review/SKILL.md", contents: "Review")
        try tree.file("home/.cursor/plugins/local/demo/custom/style.mdc", contents: "Style")
        try tree.file(
            "home/.cursor/plugins/local/demo/custom/mcp.json",
            contents: "{\"mcpServers\":{\"external\":{\"command\":\"never-run\"}}}")
        let result = try CLIRunner.run(
            ["plugins", "list", "--host", "cursor"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        let plugins = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        let components = try #require(plugins.first?["components"] as? [[String: Any]])
        #expect(
            components.contains {
                $0["kind"] as? String == "skills" && $0["name"] as? String == "review"
            })
        #expect(
            components.contains {
                $0["kind"] as? String == "rules" && $0["name"] as? String == "style.mdc"
            })
        #expect(components.filter { $0["kind"] as? String == "mcpServers" }.count == 2)
        #expect(
            components.contains {
                $0["kind"] as? String == "mcpServers" && $0["name"] as? String == "inline"
            })
        #expect(
            components.contains {
                $0["kind"] as? String == "hooks" && $0["name"] as? String == "afterFileEdit"
            })
    }

}
