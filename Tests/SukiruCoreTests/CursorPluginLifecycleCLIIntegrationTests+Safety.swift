import Darwin
import Foundation
import Testing

extension CursorPluginLifecycleCLIIntegrationTests {
    @Test(
        "Cursor local disable excludes cache payloads and symlink aliases",
        arguments: ["cache", "alias"])
    func localDisableBoundary(kind: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.cursor/plugins/local/demo/plugin.json", contents: "{\"name\":\"demo\"}")
        try tree.file(
            "home/.cursor/plugins/cache/personal/demo/one/plugin.json",
            contents: "{\"name\":\"demo\"}")
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.cursor/plugins/local/alias", withDestinationPath: "demo")
        let target =
            home
            + (kind == "cache"
                ? "/.cursor/plugins/cache/personal/demo/one" : "/.cursor/plugins/local/alias")
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"cursor","action":"disable-local","target":"\(target)",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            [
                "plugins", "execute", "--requests", tree.path + "/requests.json", "--yes",
                "--confirm-dangerous"
            ], environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test("Cursor project install instructions use the product CLI's selected root")
    func projectInstallInstructions() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let result = try CLIRunner.run(
            [
                "plugins", "install", "demo@personal", "--host", "cursor", "--scope", "project",
                "--root", project, "--dry-run"
            ], environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        #expect((json["instructions"] as? [String])?.first?.contains(project) == true)
        #expect(json["batch"] == nil)
    }

    @Test("Cursor capabilities follow help and reject a different agent product")
    func capabilitiesAndIdentity() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try cursorShim(
            tree, registrations: #"[{"name":"cursor-public","scope":"global","gitUrl":""}]"#,
            missingRemove: true)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let result = try CLIRunner.run(
            ["plugins", "capabilities", "--host", "cursor"], environment: env)
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        #expect(json["nativeCandidates"] as? [String] == ["marketplace-add", "marketplace-refresh"])
        let limits = try #require(json["limits"] as? [String: String])
        #expect(limits["install"]?.contains("Customize") == true)
        #expect(limits["marketplace-remove"] != nil)
        try cursorShim(
            tree, registrations: #"[{"name":"cursor-public","scope":"global","gitUrl":""}]"#,
            version: "grok 1.0.46")
        let rejected = try CLIRunner.run(
            ["plugins", "capabilities", "--host", "cursor"], environment: env)
        #expect(rejected.exitCode == 1)
        #expect(
            String(bytes: rejected.stderr, encoding: .utf8)?.contains(
                "does not identify a Cursor CLI") == true)
    }

    @Test(
        "Cursor refuses ambiguous and host-managed registrations",
        arguments: [
            """
            [{"name":"personal","scope":"user","gitUrl":"https://example.com/repo"},
             {"name":"personal","scope":"team","gitUrl":"https://example.com/team"}]
            """,
            """
            [{"name":"personal","scope":"user","gitUrl":"https://example.com/repo"},
             {"name":"other","scope":"user","gitUrl":"https://example.com/repo"}]
            """,
            #"[{"name":"personal","scope":"team","gitUrl":"https://example.com/repo"}]"#,
            #"[{"name":"personal","scope":"global","gitUrl":"https://example.com/repo"}]"#,
            #"[{"name":"personal","scope":"organization","gitUrl":"https://example.com/repo"}]"#
        ])
    func ambiguousRegistrations(registrations: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try cursorShim(tree, registrations: registrations, mutation: "touch '\(marker)'")
        let result = try CLIRunner.run(
            [
                "plugins", "marketplaces", "remove", "personal", "--host", "cursor", "--scope",
                "user",
                "--yes", "--confirm-dangerous"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(
        "Cursor marketplace add and remove expose exact argv and bounded capture",
        arguments: ["add", "remove"])
    func marketplaceRoutes(action: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try cursorShim(
            tree,
            registrations:
                #"[{"name":"personal","scope":"user","gitUrl":"https://example.com/repo"}]"#)
        let target = action == "add" ? "https://example.com/new" : "personal"
        let result = try CLIRunner.run(
            [
                "plugins", "marketplaces", action, target, "--host", "cursor", "--scope", "user",
                "--dry-run"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let json = try #require(try result.jsonObject())
        let batch = try #require(json["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        #expect(command["argv"] as? [String] == ["agent", "plugin", "marketplace", action, target])
        #expect(command["workingDirectory"] == nil)
        #expect((command["captureRoots"] as? [String])?.contains(home + "/.cursor") == true)
    }

    @Test(
        "Cursor capture and command failures preserve recoverable state", arguments: [false, true])
    func executionFailure(captureFails: Bool) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.dir("home/.cursor/plugins")
        let marker = tree.path + "/mutation"
        try cursorShim(
            tree,
            registrations:
                #"[{"name":"personal","scope":"user","gitUrl":"https://example.com/repo"}]"#,
            mutation: "touch '\(marker)'; exit 9")
        if captureFails { #expect(mkfifo(home + "/.cursor/plugins/fifo", 0o600) == 0) }
        let result = try CLIRunner.run(
            [
                "plugins", "marketplaces", "refresh", "personal", "--host", "cursor", "--scope",
                "user",
                "--yes", "--confirm-dangerous"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: marker) == !captureFails)
        if !captureFails {
            let record = try #require(try result.jsonObject())
            #expect(record["batchStatus"] as? String == "failed")
            #expect((record["commands"] as? [[String: Any]])?.first?["exitCode"] as? Int == 9)
            #expect(record["snapshotID"] is String)
        }
    }

    @Test(
        "Cursor rejects malformed or unknown structured output without a mutation",
        arguments: [
            "personal user https://example.com/repo", "{", "null", "{}",
            #"[{"name":"personal","scope":"user"}]"#,
            #"[{"name":"personal","scope":"organization","gitUrl":"https://example.com/repo"}]"#,
            #"[{"name":"","scope":"user","gitUrl":"https://example.com/repo"}]"#,
            #"[{"name":"personal","scope":"user","gitUrl":42}]"#
        ])
    func invalidStructuredOutput(registrations: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try cursorShim(tree, registrations: registrations, mutation: "touch '\(marker)'")
        let result = try CLIRunner.run(
            [
                "plugins", "marketplaces", "add", "https://example.com/new", "--host", "cursor",
                "--scope", "user", "--yes", "--confirm-dangerous"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(String(bytes: result.stderr, encoding: .utf8)?.contains("JSON") == true)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Cursor requires JSON capability even when text listing would work")
    func missingStructuredCapability() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try cursorShim(tree, registrations: "[]", missingFormat: true)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let capabilities = try CLIRunner.run(
            ["plugins", "capabilities", "--host", "cursor"], environment: env)
        let report = try #require(try capabilities.jsonObject())
        #expect((report["nativeCandidates"] as? [String])?.isEmpty == true)
        let plan = try CLIRunner.run(
            [
                "plugins", "marketplaces", "add", "https://example.com/new", "--host", "cursor",
                "--scope", "user", "--dry-run"
            ], environment: env)
        #expect(plan.exitCode == 1)
        #expect(
            String(bytes: plan.stderr, encoding: .utf8)?.contains("required operation flags")
                == true)
    }

    @Test(
        "Cursor JSON accepts an empty list and documented extra metadata",
        arguments: [
            "[]",
            """
            [{"name":"other","scope":"user","gitUrl":"https://example.com/other",
              "gitRef":"v1","lastIndexedAt":123,"displayName":"Other marketplace"}]
            """
        ])
    func structuredRegistrationMetadata(registrations: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try cursorShim(tree, registrations: registrations)
        let result = try CLIRunner.run(
            [
                "plugins", "marketplaces", "add", "https://example.com/new", "--host", "cursor",
                "--scope", "user", "--dry-run"
            ],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        #expect(try result.jsonObject()?["batch"] != nil)
    }

    private func cursorShim(
        _ tree: TempTree, registrations: String, mutation: String = "exit 91",
        missingRemove: Bool = false,
        missingFormat: Bool = false,
        version: String = "2026.08.25-3e8eec8"
    ) throws {
        let removeHelp = missingRemove ? "exit 1" : "echo 'Usage: agent plugin marketplace remove'"
        let listHelp =
            "Usage: agent plugin marketplace list" + (missingFormat ? "" : " --format text json")
        try tree.executable(
            "bin/agent",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo '\(version)';;
                'plugin marketplace remove --help') \(removeHelp);;
                'plugin marketplace list --help') echo '\(listHelp)';;
                *--help*) echo "Usage: agent $*";;
                'plugin marketplace list --format json') printf '%s\n' '\(registrations)';;
                *) \(mutation);;
                esac
                """)
    }
}
