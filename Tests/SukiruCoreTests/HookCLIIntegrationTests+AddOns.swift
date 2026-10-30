import Foundation
import SukiruCore
import Testing

private enum AgentExtensionRoutesLimit {
    static let dsh =
        "DSH enables and disables bundle plugins in its plugin panel (Settings → Plugins)."
}

extension HookCLIIntegrationTests {
    /// Plans one request per matching add-on and executes the batch.
    private func run(
        _ changes: [(String, (AgentExtension) -> Bool)], tree: TempTree, env: [String: String],
        execute: Bool = true
    ) throws -> (plan: HookCleanupPlan, result: CLIRunner.Result?) {
        let scan = try CLIRunner.run(["scan", "--json"], environment: env)
        let found =
            try JSONDecoder().decode(ScanReport.self, from: scan.stdout)
            .extensionInventory?.extensions ?? []
        let requests = try changes.map { action, match in
            HookCleanupRequest(
                action: action + "-extension",
                extensionID: try #require(found.first(where: match)).id)
        }
        try JSONEncoder().encode(requests).write(
            to: URL(fileURLWithPath: tree.path + "/requests.json"))
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0, "\(String(bytes: preview.stderr, encoding: .utf8)!)")
        let plan = try JSONDecoder().decode(HookCleanupPlan.self, from: preview.stdout)
        guard execute else { return (plan, nil) }
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        let result = try executePlan(tree.path + "/plan.json", environment: env)
        #expect(
            result.exitCode == 0,
            "\(String(bytes: result.stdout + result.stderr, encoding: .utf8)!)")
        return (plan, result)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// One add-on of each documented switch: file path by host name, before any change.
    private func addOnFixture(_ tree: TempTree) throws -> [String: String] {
        try tree.file("home/.pi/agent/extensions/rtk.ts", contents: "// rtk")
        try tree.file("home/.omp/agent/extensions/rtk.ts", contents: "// rtk")
        try tree.dir("home/.hermes/plugins/spotify")
        let files = [
            "pi": (
                "home/.pi/agent/settings.json",
                "{\n  \"theme\": \"dark\",\n  \"packages\": [\"npm:@acme/pi-tools\"]\n}\n"
            ),
            "omp": ("home/.omp/agent/config.yml", "theme:\n  dark: titanium\n"),
            "hermes": (
                "home/.hermes/config.yaml",
                """
                plugins:
                  enabled:
                    - spotify
                  disabled: []
                mcp_servers:
                  notion:
                    command: npx

                """
            ),
            "codex": (
                "home/.codex/config.toml",
                """
                model = "x"

                [mcp_servers.rea]
                command = "npx"

                [mcp_servers.rea.env]
                A = "1"

                [mcp_servers.web]
                url = "https://x"

                """
            ),
            "droid": (
                "home/.factory/mcp.json", "{\"mcpServers\": {\"rea\": {\"command\": \"npx\"}}}\n"
            ),
            "gemini": (
                "home/.gemini/settings.json",
                "{\n  \"mcpServers\": {\n    \"rea\": {\"command\": \"npx\"}\n  }\n}\n"
            ),
            "amp": ("home/.config/amp/plugins/status.ts", "// amp")
        ]
        return try files.mapValues { try tree.file($0.0, contents: $0.1) }
    }

    private func expectSwitched(_ files: [String: String], home: String) throws {
        #expect(try read(files["pi"]!).contains("\"-extensions/rtk.ts\""))
        #expect(try read(files["pi"]!).contains("\"theme\": \"dark\""))
        #expect(
            try read(files["omp"]!)
                == "theme:\n  dark: titanium\ndisabledExtensions:\n  - extension-module:rtk\n")
        #expect(
            try read(files["hermes"]!) == """
                plugins:
                  enabled: []
                  disabled:
                    - spotify
                mcp_servers:
                  notion:
                    enabled: false
                    command: npx

                """)
        #expect(
            try read(files["codex"]!) == """
                model = "x"

                [mcp_servers.rea]
                enabled = false
                command = "npx"

                [mcp_servers.rea.env]
                A = "1"

                """)
        #expect(try read(files["droid"]!).contains("\"disabled\": true"))
        #expect(try read(files["gemini"]!).contains("\"excluded\""))
        #expect(!FileManager.default.fileExists(atPath: files["amp"]!))
        #expect(
            FileManager.default.fileExists(
                atPath: home + "/.config/amp/disabled-extensions/status.ts"))
    }

    @Test("Documented switches disable add-ons without their CLIs, keep other bytes, and roll back")
    func addOnConfigSwitches() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let files = try addOnFixture(tree)
        let edited = ["pi", "omp", "hermes", "codex", "droid", "gemini"].map { files[$0]! }
        let env = CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin")
        let originals = try edited.map(read)

        let (plan, result) = try run(
            [
                ("disable", { $0.host == .pi && $0.name == "rtk.ts" }),
                ("disable", { $0.host == .pi && $0.category == .package }),
                ("disable", { $0.host == .omp && $0.name == "rtk.ts" }),
                ("disable", { $0.host == .hermes && $0.name == "spotify" }),
                ("disable", { $0.host == .hermes && $0.name == "notion" }),
                ("disable", { $0.host == .codex && $0.name == "rea" }),
                ("remove", { $0.host == .codex && $0.name == "web" }),
                ("disable", { $0.host == .droid && $0.name == "rea" }),
                ("disable", { $0.host == .gemini && $0.name == "rea" }),
                ("disable", { $0.host == .amp })
            ], tree: tree, env: env)
        #expect(plan.batch.commands.allSatisfy { $0.owningCLI == .file })

        try expectSwitched(files, home: home)

        let rescan = try CLIRunner.run(["scan", "--json"], environment: env)
        let after =
            try JSONDecoder().decode(ScanReport.self, from: rescan.stdout).extensionInventory?
            .extensions ?? []
        #expect(
            after.filter { [.pi, .omp, .hermes, .droid, .gemini, .amp].contains($0.host) }
                .allSatisfy { $0.enabled == false })

        let id = try #require(try result?.jsonObject()?["batchID"] as? String)
        let rollback = try CLIRunner.run(["rollback", "--yes", "--batch", id], environment: env)
        #expect(rollback.exitCode == 0, "\(String(bytes: rollback.stderr, encoding: .utf8)!)")
        #expect(try edited.map(read) == originals)
        #expect(FileManager.default.fileExists(atPath: files["amp"]!))
    }

    @Test("An installed host CLI runs instead of a file edit; DSH toggles stay instructions")
    func addOnNativeCommands() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let log = tree.path + "/grok.log"
        let grok = try tree.file(
            "bin/grok",
            contents:
                "#!/bin/sh\ncase \"$*\" in *--help*)\n"
                + "printf 'Commands:\\n  disable <name>\\n  enable <name>\\n  remove\\n';;\n"
                + "*) echo \"$*\" >> '\(log)';; esac\n")
        _ = chmod(grok, 0o755)
        let config = try tree.file(
            "home/.grok/config.toml", contents: "[mcp_servers.rea]\ncommand = \"npx\"\n")
        try tree.file(
            "home/.dsh/profiles/web/package.json",
            contents:
                "{\"dependencies\": {\"@deepseek-ai/dsh-base\": \"1\", \"dsh-session-search\": \"github:x/y\"}}"
        )
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")

        let dsh = try run([("disable", { $0.host == .dsh })], tree: tree, env: env, execute: false)
            .plan
        #expect(dsh.batch.commands.isEmpty)
        #expect(dsh.instructions == ["dsh-session-search: " + AgentExtensionRoutesLimit.dsh])
        let plan = try run(
            [("disable", { $0.host == .grok && $0.name == "rea" })], tree: tree, env: env
        ).plan
        #expect(plan.batch.commands.map(\.argv) == [["grok", "mcp", "disable", "rea"]])
        #expect(try read(log) == "mcp disable rea\n")
        #expect(try read(config) == "[mcp_servers.rea]\ncommand = \"npx\"\n")
    }
}
