import Darwin
import Foundation
import Testing

@Suite("Native plugin lifecycle CLI")
struct PluginLifecycleCLIIntegrationTests {
    @Test("Author commands are instructions and never accepted by Sukiru")
    func authorCommand() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let catalog = try tree.dir("catalog")
        let marker = tree.path + "/author-command"
        try tree.file(
            "home/.claude/plugins/known_marketplaces.json",
            contents: """
                {"team":{"source":{"source":"directory","path":"\(catalog)"},"installLocation":"\(catalog)"}}
                """)
        try tree.file(
            "catalog/.claude-plugin/marketplace.json",
            contents: """
                {"name":"team","plugins":[{"name":"demo","source":{"source":"command","command":"touch '\(marker)'"}}]}
                """)
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo 'install --json --scope';;
                *) touch '\(marker)';;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"install","target":"demo@team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", tree.path + "/requests.json", "--reviewed"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        let record = try #require(try result.jsonObject())
        #expect((record["instructions"] as? [String])?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Claude removal preview includes every recorded project in the cascade and capture")
    func marketplaceCascade() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let unadded = try tree.dir("unadded-project")
        let payload = try tree.dir("external-payload")
        try tree.file(
            "home/.claude/plugins/known_marketplaces.json",
            contents: """
                {"team":{"source":{"source":"github","repo":"example/team"}}}
                """)
        try tree.file(
            "home/.claude/plugins/installed_plugins.json",
            contents: """
                {"version":2,"plugins":{"demo@team":[{"scope":"project","projectPath":"\(unadded)",
                  "installPath":"\(payload)","version":"1.2.3"}]}}
                """)
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo 'remove --json --scope';;
                *) exit 91;;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"marketplace-remove","target":"team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "plan", "--requests", tree.path + "/requests.json"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let record = try #require(try result.jsonObject())
        let batch = try #require(record["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        let capture = try #require(command["captureRoots"] as? [String])
        #expect(capture.contains(unadded + "/.claude"))
        #expect(capture.contains(payload))
        #expect((command["warning"] as? String)?.contains(unadded) == true)
        #expect((command["warning"] as? String)?.contains("1.2.3") == true)
    }

    @Test(
        "Unsupported native operations remain instructions only",
        arguments: [
            ["opencode", "v1.18.34", "remove", "demo"],
            ["opencode", "v2.0.22", "update", "./local.ts"],
            ["opencode", "v2.0.23", "install", "demo"],
            ["codex", "codex-cli 0.160.0", "enable", "demo@team"]
        ])
    func instructionsOnly(values: [String]) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try tree.executable(
            "bin/" + values[0],
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo '\(values[1])';;
                *--help*) echo '--json --scope';;
                *) touch '\(marker)';;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"\(values[0])","action":"\(values[2])","target":"\(values[3])",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", tree.path + "/requests.json", "--reviewed"],
            environment: env)
        #expect(result.exitCode == 1)
        let record = try #require(try result.jsonObject())
        #expect((record["instructions"] as? [String])?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(
        "Incomplete capture refuses the subprocess even with effects consent",
        arguments: [
            ["claude", "2.1.288", "disable", ".claude"],
            ["opencode", "v1.18.34", "replace", ".config/opencode"],
            ["opencode", "v2.0.22", "update", ".config/opencode"]
        ])
    func captureFailure(values: [String]) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.dir("home/" + values[3])
        let fifo = home + "/" + values[3] + "/unbounded-fifo"
        #expect(mkfifo(fifo, 0o600) == 0)
        let marker = tree.path + "/mutation"
        try tree.executable(
            "bin/" + values[0],
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo '\(values[1])';;
                *--help*) echo '--json --scope --global --force';;
                *) touch '\(marker)';;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"\(values[0])","action":"\(values[2])","target":"demo@team",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            [
                "plugins", "execute", "--requests", tree.path + "/requests.json", "--reviewed",
                "--confirm-dangerous"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(
        "Success and approval refusal both retain file diffs and byte exact rollback",
        arguments: [0, 3])
    func executionRoundTrip(exitCode: Int) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let originalText = "saved options and secrets\n"
        let original = Data(originalText.utf8)
        let payload = try tree.file(
            "home/.claude/plugins/data/demo/options",
            contents: originalText)
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo '2.1.288 (Claude Code)';;
                *--help*) echo 'disable --scope --json';;
                'plugin disable demo@team --scope user --json')
                  printf changed > '\(payload)'
                  printf '{"result":"partial"}\n'
                  echo 'host approval required' >&2
                  exit \(exitCode);;
                *) exit 91;;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"disable","target":"demo@team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", tree.path + "/requests.json", "--reviewed"],
            environment: env)
        #expect(
            result.exitCode == (exitCode == 0 ? 0 : 1),
            "\(String(bytes: result.stderr, encoding: .utf8) ?? "non-UTF8 stderr")")
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == (exitCode == 0 ? "succeeded" : "failed"))
        let batchID = try #require(record["batchID"] as? String)
        let diff = try #require(record["diff"] as? [String: Any])
        #expect(
            (diff["entries"] as? [[String: Any]])?.contains { $0["path"] as? String == payload }
                == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: payload)) == Data("changed".utf8))
        let rollback = try CLIRunner.run(["rollback", "--batch", batchID], environment: env)
        #expect(
            rollback.exitCode == 0,
            "\(String(bytes: rollback.stderr, encoding: .utf8) ?? "non-UTF8 stderr")")
        #expect(try Data(contentsOf: URL(fileURLWithPath: payload)) == original)
    }

}
