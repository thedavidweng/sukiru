import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test("Orca leftovers across every agent layout are inventoried and removed together")
    func orcaAgentLeftovers() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let helper = try writeOrcaAgentFixture(tree: tree, home: home)
        let env = CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin")

        let scan = try CLIRunner.run(["hooks", "inventory"], environment: env)
        let report = try JSONDecoder().decode(ScanReport.self, from: scan.stdout)
        let inventory = try #require(report.hookInventory)
        #expect(inventory.issues.isEmpty)
        let orcaHooks = inventory.hooks.filter { $0.attribution.producer == "Orca" }
        #expect(
            Set(orcaHooks.map(\.source.host))
                == [
                    .cursor, .gemini, .codex, .kimi, .jcode, .zcode, .antigravity, .kiro, .copilot,
                    .dsh, .muse
                ])
        #expect(orcaHooks.count == 12)
        #expect(orcaHooks.allSatisfy { $0.health == .leftover && $0.canRemove })

        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0, "\(String(bytes: preview.stderr, encoding: .utf8)!)")
        let plan = try JSONDecoder().decode(HookCleanupPlan.self, from: preview.stdout)
        #expect(plan.hooks.count == 12)
        #expect(plan.helperPaths == [helper])
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        let result = try executePlan(tree.path + "/plan.json", environment: env)
        #expect(result.exitCode == 0, "\(String(bytes: result.stderr, encoding: .utf8)!)")
        #expect(!FileManager.default.fileExists(atPath: helper))
        try expectOrcaAgentsCleaned(home: home)

        let after = try CLIRunner.run(["hooks", "inventory"], environment: env)
        let rescanned = try #require(
            try JSONDecoder().decode(ScanReport.self, from: after.stdout).hookInventory)
        #expect(rescanned.issues.isEmpty)
        #expect(!rescanned.hooks.contains { $0.attribution.producer == "Orca" })
        #expect(rescanned.hooks.count == 4)
    }

    private func expectOrcaAgentsCleaned(home: String) throws {
        func read(_ path: String) throws -> String {
            try String(contentsOfFile: home + "/" + path, encoding: .utf8)
        }
        for path in [
            ".cursor/hooks.json", ".gemini/settings.json", ".codex/hooks.json",
            ".kimi-code/config.toml", ".jcode/config.toml", ".zcode/cli/config.json",
            ".gemini/config/hooks.json", ".kiro/hooks/orca-agent-status.json",
            ".copilot/hooks/orca.json", ".orca/agent-hooks/dsh-hooks.json",
            ".orca/agent-hooks/muse-hooks.json"
        ] {
            #expect(try !read(path).contains("agent-hooks/"), "\(path)")
        }
        #expect(try read(".cursor/hooks.json").contains("/usr/bin/true"))
        #expect(try read(".gemini/settings.json").contains("\"theme\":\"keep\""))
        #expect(try read(".kimi-code/config.toml").contains("command = \"/usr/bin/true\""))
        #expect(try read(".kimi-code/config.toml").hasPrefix("default_model = \"keep\""))
        #expect(
            try read(".jcode/config.toml")
                == "[hooks]\npre_tool = [\"/usr/bin/true\"] # gates first\npre_tool_timeout_ms = 500"
        )
        #expect(try read(".zcode/cli/config.json").contains("\"enabled\":true"))
        #expect(try read(".gemini/config/hooks.json").contains("\"mine\""))
    }

    /// One Orca leftover per agent layout, beside user hooks that must survive. Returns the helper.
    private func writeOrcaAgentFixture(tree: TempTree, home: String) throws -> String {
        let helper = try tree.file(
            "home/.orca/agent-hooks/cursor-hook.sh", contents: "#!/bin/sh\nexit 0")
        func orca(_ script: String) -> String {
            let path = home + "/.orca/agent-hooks/" + script + ".sh"
            return "if [ -f '\(path)' ] && [ -x '\(path)' ]; then /bin/sh '\(path)'; fi"
        }
        let runtime =
            ": orca-agent-hook-form=1; if [ -f \\\"${HOME-}/.orca/agent-hooks/codex-hook.sh\\\" ]; "
            + "then /bin/sh \\\"${HOME-}/.orca/agent-hooks/codex-hook.sh\\\" || :; fi"
        try tree.file(
            "home/.cursor/hooks.json",
            contents: """
                {"version":1,"hooks":{"stop":[{"command":"\(orca("cursor-hook"))","timeout":10},
                  {"command":"/usr/bin/true"}]}}
                """)
        try tree.file(
            "home/.gemini/settings.json",
            contents: """
                {"theme":"keep","hooks":{"AfterAgent":[{"hooks":[
                  {"type":"command","command":"\(orca("gemini-hook"))"}]}]}}
                """)
        try tree.file(
            "home/.codex/hooks.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(runtime)"}]}]}}
                """)
        try writeOrcaOtherLayouts(tree: tree, orca: orca)
        try tree.file(
            "home/.kiro/hooks/orca-agent-status.json",
            contents: """
                {"version":"v1","hooks":[{"name":"orca-agent-status-stop","trigger":"stop",
                  "action":{"type":"command","command":"\(orca("kiro-hook"))"}}]}
                """)
        try tree.file(
            "home/.copilot/hooks/orca.json",
            contents: """
                {"version":1,"hooks":{"Stop":[{"type":"command","bash":"\(orca("copilot-hook"))",
                  "timeoutSec":5}]}}
                """)
        let claudeShaped = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(orca("dsh-hook"))"}]}]}}
            """
        try tree.file("home/.orca/agent-hooks/dsh-hooks.json", contents: claudeShaped)
        try tree.file("home/.orca/agent-hooks/muse-hooks.json", contents: claudeShaped)
        try tree.file(
            "home/.config/muse/settings.json",
            contents: #"{"managed_hooks_path":"\#(home)/.orca/agent-hooks/muse-hooks.json"}"#)
        try tree.file(
            "requests.json", contents: #"[{"action":"remove-leftovers","producer":"Orca"}]"#)
        return helper
    }

    private func writeOrcaOtherLayouts(tree: TempTree, orca: (String) -> String) throws {
        try tree.file(
            "home/.zcode/cli/config.json",
            contents: """
                {"hooks":{"enabled":true,"events":{"Stop":[{"hooks":[
                  {"type":"command","command":"\(orca("zcode-hook"))"}]}]}}}
                """)
        try tree.file(
            "home/.gemini/config/hooks.json",
            contents: """
                {"orca-status":{"Stop":[{"type":"command","command":"\(orca("antigravity-hook"))"}]},
                 "mine":{"Stop":[{"type":"command","command":"/usr/bin/true"}]}}
                """)
        try tree.file(
            "home/.kimi-code/config.toml",
            contents: """
                default_model = "keep"
                # >>> orca-managed-kimi-hooks >>>
                [[hooks]]
                event = "Stop"
                command = "\(orca("kimi-hook"))"
                timeout = 10
                # <<< orca-managed-kimi-hooks <<<
                [[hooks]]
                event = "Stop"
                command = "/usr/bin/true"
                """)
        try tree.file(
            "home/.jcode/config.toml",
            contents: """
                [hooks]
                pre_tool = ["/usr/bin/true", "\(orca("jcode-hook"))"] # gates first
                stop = "\(orca("jcode-hook"))"
                pre_tool_timeout_ms = 500
                """)
    }

    @Test("Codex hook trust state tables are not hook definitions")
    func codexTrustState() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.codex/config.toml",
            contents: """
                [hooks.state]
                [hooks.state."/x/hooks.json:stop:0:0"]
                trusted_hash = "sha256:abc"
                """)
        let result = try CLIRunner.run(
            ["hooks", "inventory"], environment: CLIRunner.fixtureEnvironment(home: home))
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        #expect(result.exitCode == 0)
        #expect(report.hookInventory?.isEmpty ?? true)
    }
}
