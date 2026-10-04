import Foundation
import Testing

struct CursorPluginLifecycleCLIIntegrationTests {
    @Test("Cursor single-plugin operations return scoped host instructions without a CLI")
    func unsupportedOperations() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        for action in ["install", "remove", "enable", "disable", "update"] {
            try tree.file(
                "requests.json",
                contents: """
                    [{"host":"cursor","action":"\(action)","target":"demo@team",
                      "scope":"project","scopeRoot":"\(project)"}]
                    """)
            let result = try CLIRunner.run(
                ["plugins", "plan", "--requests", tree.path + "/requests.json"],
                environment: CLIRunner.fixtureEnvironment(home: home, roots: [project]))
            #expect(result.exitCode == 0)
            let json = try #require(try result.jsonObject())
            #expect(json["batch"] == nil)
            let instruction = try #require((json["instructions"] as? [String])?.first)
            #expect(
                instruction.contains("Customize") && instruction.contains("/plugin")
                    && instruction.contains(project) && instruction.contains("refresh Sukiru"))
        }
    }

    @Test("Cursor marketplace plans use agent and disclose external effects")
    func marketplacePlan() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try tree.executable(
            "bin/agent",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2026.08.25-3e8eec8;;
                *--help*) echo "Usage: agent $*";;
                'plugin marketplace list') echo 'personal user https://example.com/plugins.git';;
                *) touch '\(marker)'; exit 92;;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"cursor","action":"marketplace-refresh","target":"personal",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "plan", "--requests", tree.path + "/requests.json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        let command = try #require(
            ((json["batch"] as? [String: Any])?["commands"] as? [[String: Any]])?.first)
        #expect(
            command["argv"] as? [String] == ["agent", "plugin", "marketplace", "update", "personal"]
        )
        #expect((command["dangerFlags"] as? [String])?.contains("backend-state-change") == true)
        #expect((command["warning"] as? String)?.contains("account sync") == true)
        #expect((command["captureRoots"] as? [String])?.contains(home + "/.cursor") == true)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(
        "Cursor local disable is snapshot protected and can be rolled back",
        arguments: [false, true])
    func localDisableRoundTrip(laterEdit: Bool) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let plugin = home + "/.cursor/plugins/local/demo"
        try tree.file(
            "home/.cursor/plugins/local/demo/plugin.json", contents: "{\"name\":\"demo\"}")
        try tree.file("home/.cursor/plugins/local/demo/skills/review/SKILL.md", contents: "Review")
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"cursor","action":"disable-local","target":"\(plugin)","scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let executed = try CLIRunner.run(
            [
                "plugins", "execute", "--requests", tree.path + "/requests.json", "--yes",
                "--confirm-dangerous"
            ], environment: env)
        #expect(executed.exitCode == 0)
        let record = try #require(try executed.jsonObject())
        #expect(record["batchStatus"] as? String == "succeeded")
        #expect(!FileManager.default.fileExists(atPath: plugin))
        let batchID = try #require(record["batchID"] as? String)
        var rollbackArgs = ["rollback", "--batch", batchID, "--yes"]
        if laterEdit {
            let command = try #require((record["commands"] as? [[String: Any]])?.first)
            let argv = try #require(command["argv"] as? [String])
            let edited = argv[3] + "/skills/review/SKILL.md"
            try "Later edit".write(toFile: edited, atomically: true, encoding: .utf8)
            let conflict = try CLIRunner.run(rollbackArgs, environment: env)
            #expect(conflict.exitCode == 1)
            rollbackArgs += ["--restore", edited]
        }
        let rollback = try CLIRunner.run(rollbackArgs, environment: env)
        #expect(rollback.exitCode == 0)
        #expect(
            try String(contentsOfFile: plugin + "/skills/review/SKILL.md", encoding: .utf8)
                == "Review")
    }

    @Test(
        "Cursor marketplace refresh reports observations rather than trusting exit zero",
        arguments: [false, true])
    func refreshObservation(changes: Bool) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let manifest = try tree.file(
            "home/.cursor/plugins/cache/personal/demo/one/plugin.json",
            contents: "{\"name\":\"demo\",\"version\":\"1\"}")
        let mutation =
            changes ? "echo '{\"name\":\"demo\",\"version\":\"2\"}' > '\(manifest)'" : ":"
        try tree.executable(
            "bin/agent",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2026.08.25-3e8eec8;;
                *--help*) echo "Usage: agent $*";;
                'plugin marketplace list') echo 'personal user https://example.com/plugins.git';;
                'plugin marketplace update personal') \(mutation); echo 'Updated: 0 plugins indexed';;
                *) exit 91;;
                esac
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let args = [
            "plugins", "marketplaces", "refresh", "personal", "--host", "cursor", "--scope", "user",
            "--yes"
        ]
        let refused = try CLIRunner.run(args, environment: env)
        #expect(refused.exitCode == 1)
        let executed = try CLIRunner.run(args + ["--confirm-dangerous"], environment: env)
        #expect(executed.exitCode == 0)
        let record = try #require(try executed.jsonObject())
        let command = try #require((record["commands"] as? [[String: Any]])?.first)
        #expect(command["exitCode"] as? Int == 0)
        let diagnostics = try #require(command["diagnostics"] as? String)
        #expect(
            diagnostics.contains(
                changes
                    ? "Observed local catalog/payload changes"
                    : "No observable local catalog/payload change"))
        let stdout = try #require(command["stdoutFile"] as? String)
        #expect(try String(contentsOfFile: stdout, encoding: .utf8).contains("0 plugins indexed"))
        let id = try #require(record["batchID"] as? String)
        #expect(
            try CLIRunner.run(["rollback", "--batch", id, "--yes"], environment: env).exitCode == 0)
        #expect(
            try String(contentsOfFile: manifest, encoding: .utf8)
                == "{\"name\":\"demo\",\"version\":\"1\"}")
    }

    @Test("Cursor add refuses duplicate source registrations")
    func duplicateMarketplaceAdd() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.executable(
            "bin/agent",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2026.08.25-3e8eec8;;
                *--help*) echo "Usage: agent $*";;
                'plugin marketplace list') echo 'personal user https://example.com/plugins.git';;
                *) exit 91;;
                esac
                """)
        let result = try CLIRunner.run(
            [
                "plugins", "marketplaces", "add", "https://example.com/plugins.git", "--host",
                "cursor", "--scope", "user", "--dry-run"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(
            String(bytes: result.stderr, encoding: .utf8)?.contains("already registered") == true)
    }

}
