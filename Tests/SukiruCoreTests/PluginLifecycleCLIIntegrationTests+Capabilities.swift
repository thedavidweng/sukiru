import Foundation
import Testing

extension PluginLifecycleCLIIntegrationTests {
    @Test("OpenCode capture includes temporary state and configured npm cache and logs")
    func openCodeCapturePaths() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let cache = try tree.dir("npm-cache")
        let logs = try tree.dir("npm-logs")
        try tree.file("home/.npmrc", contents: "cache=\(cache)\nlogs-dir=\(logs)\n")
        try tree.executable(
            "bin/opencode",
            contents:
                "#!/bin/sh\ncase \"$*\" in\n--version) echo v2.0.22;;\n*--help*) echo add;;\n*) exit 91;;\nesac\n"
        )
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"install","target":"demo@1.2.3",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "plan", "--requests", tree.path + "/requests.json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        let batch = try #require(json["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        let roots = try #require(command["captureRoots"] as? [String])
        #expect(roots.contains(home + "/opencode"))
        #expect(roots.contains(home + "/.local/share/opencode"))
        #expect(roots.contains(cache))
        #expect(roots.contains(logs))
    }

    @Test("Malformed Claude records refuse a capture plan")
    func malformedClaudeRecords() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try tree.file("home/.claude/plugins/installed_plugins.json", contents: "{\"plugins\":[]}")
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo 'disable --scope --json';;
                *) touch '\(marker)';;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"disable","target":"demo@team",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", tree.path + "/requests.json", "--reviewed"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Missing installed-version flags prevent dispatch")
    func missingScopeFlag() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo disable;;
                *) touch '\(marker)';;
                esac

                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"disable","target":"demo@team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", tree.path + "/requests.json", "--reviewed"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Claude disable previews official scope and complete host roots")
    func disablePlan() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo 'disable --scope --json';;
                *) exit 99;;
                esac

                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"disable","target":"demo@team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "plan", "--requests", tree.path + "/requests.json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        let batch = try #require(json["batch"] as? [String: Any])
        let commands = try #require(batch["commands"] as? [[String: Any]])
        #expect(
            commands.first?["argv"] as? [String] == [
                "claude", "plugin", "disable", "demo@team", "--scope", "user", "--json"
            ])
        #expect((commands.first?["captureRoots"] as? [String])?.contains(home + "/.claude") == true)
    }

    @Test("OpenCode runtime checks produce instructions without starting a session")
    func runtimeCheck() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/session"
        try tree.executable(
            "bin/opencode",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo v2.0.22;;
                *--help*) echo check;;
                *) touch '\(marker)'; exit 99;;
                esac

                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"check","target":"demo","scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "plan", "--requests", tree.path + "/requests.json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        #expect((json["instructions"] as? [String])?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
