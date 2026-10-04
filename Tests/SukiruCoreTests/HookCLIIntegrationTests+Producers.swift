import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test(
        "Verified Orca runtime-home wrappers are attributed without resolving runtime targets",
        arguments: [false, true])
    func orcaRuntimeWrapper(installed: Bool) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        if installed { try tree.dir("home/Applications/Orca.app") }
        let target = "\"${HOME-}/.orca/agent-hooks/claude-hook.sh\""
        let command =
            "if [ -z \"${HOME-}\" ]; then printf '{}'; else case \"${OSTYPE-}\" in "
            + "*) if [ -f \(target) ] && [ -r \(target) ] && [ -x \(target) ]; "
            + "then /bin/sh \(target); else printf '{}'; fi ;; esac; fi"
        let source = try tree.file("home/.claude/settings.json")
        try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": command]
                        ]
                    ]
                ]
            ]
        ]).write(to: URL(fileURLWithPath: source))
        let result = try CLIRunner.run(
            ["hooks", "inventory"],
            environment: CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin"))
        let report = try JSONDecoder().decode(ScanReport.self, from: result.stdout)
        let hook = try #require(report.hookInventory?.hooks.first)
        #expect(hook.attribution.producer == "Orca")
        #expect(!hook.attribution.evidence.isEmpty)
        #expect(hook.health == (installed ? .externallyManaged : .leftover))
        #expect(hook.targets.isEmpty)
        let planPath = try planFirstHook(
            tree: tree,
            environment: CLIRunner.fixtureEnvironment(home: home, path: "/usr/bin:/bin"))
        let plan = try JSONDecoder().decode(
            HookCleanupPlan.self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        #expect(plan.batch.commands.count == 1)
        #expect(plan.helperPaths.isEmpty)
    }

    @Test(
        "Producer evidence distinguishes leftovers, live integrations, unknown names, and shared helpers"
    )
    func producerCleanup() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let helper = try tree.file(
            "home/Library/Application Support/Muxy/hooks/notify.sh", contents: "#!/bin/sh\nexit 0")
        let unrelated = try tree.file(
            "home/Library/Application Support/Muxy/preferences.json", contents: "keep")
        let config = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh '\(helper)'"}]}]}}
            """
        try tree.file("home/.claude/settings.json", contents: config)
        try tree.file("project/.codex/hooks.json", contents: config)
        let env = CLIRunner.fixtureEnvironment(home: home, roots: [project])
        let scan = try CLIRunner.run(["scan", "--format", "json"], environment: env)
        let report = try JSONDecoder().decode(ScanReport.self, from: scan.stdout)
        let hooks = try #require(report.hookInventory?.hooks)
        #expect(hooks.count == 2)
        #expect(hooks.allSatisfy { $0.health == .leftover && $0.attribution.producer == "Muxy" })
        let first = try planFirstHook(tree: tree, environment: env)
        let firstPlan = try JSONDecoder().decode(
            HookCleanupPlan.self, from: Data(contentsOf: URL(fileURLWithPath: first)))
        #expect(firstPlan.helperPaths.isEmpty)
        #expect(try executePlan(first, environment: env).exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: helper))
        let next = try planFirstHook(tree: tree, environment: env)
        let nextPlan = try JSONDecoder().decode(
            HookCleanupPlan.self, from: Data(contentsOf: URL(fileURLWithPath: next)))
        #expect(nextPlan.helperPaths == [helper])
        #expect(try executePlan(next, environment: env).exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: helper))
        #expect(try String(contentsOfFile: unrelated, encoding: .utf8) == "keep")
    }

    @Test(
        "Grouped producer cleanup discloses every hook and helper, leaving application data alone")
    func groupedLeftovers() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let helper = try tree.file(
            "home/.orca/agent-hooks/claude-hook.sh", contents: "#!/bin/sh\nexit 0")
        try tree.file("home/.orca/keep.json", contents: "keep")
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh '\(helper)'"}]}],
                  "SessionStart":[{"hooks":[{"type":"command","command":"/bin/sh '\(helper)'"}]}]}, "keep": 1}
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"action":"remove-leftovers","producer":"Orca"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0)
        let plan = try JSONDecoder().decode(HookCleanupPlan.self, from: preview.stdout)
        #expect(plan.hooks.count == 2)
        #expect(plan.helperPaths == [helper])
        #expect(plan.batch.commands.count == 2)
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        #expect(try executePlan(tree.path + "/plan.json", environment: env).exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: helper))
        #expect(try String(contentsOfFile: home + "/.orca/keep.json", encoding: .utf8) == "keep")
    }

    @Test("Installed Orca prefers its supported disable interface and captures partial failure")
    func orcaDisable() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let helper = try tree.file(
            "home/.orca/agent-hooks/claude-hook.sh", contents: "#!/bin/sh\nexit 0")
        let marker = tree.path + "/producer-called"
        try tree.file(
            "home/.claude/settings.json",
            contents: """
                {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh '\(helper)'"}]}]}}
                """)
        try tree.executable(
            "bin/orca",
            contents: """
                #!/bin/sh
                test "$*" = 'agent hooks off --json' || exit 90
                touch '\(marker)'
                printf '{"keep":true}' > '\(home)/.claude/settings.json'
                exit 17
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let first = try planFirstHook(tree: tree, environment: env)
        let refused = try JSONDecoder().decode(
            HookCleanupPlan.self, from: Data(contentsOf: URL(fileURLWithPath: first)))
        #expect(refused.batch.commands.isEmpty)
        #expect(!refused.instructions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker))
        try tree.file(
            "requests.json",
            contents: """
                [{"action":"disable-producer","producer":"Orca"}]
                """)
        let preview = try CLIRunner.run(
            ["hooks", "plan", "--requests", tree.path + "/requests.json"], environment: env)
        #expect(preview.exitCode == 0)
        let plan = try JSONDecoder().decode(HookCleanupPlan.self, from: preview.stdout)
        #expect(plan.batch.commands.first?.argv == ["orca", "agent", "hooks", "off", "--json"])
        try preview.stdout.write(to: URL(fileURLWithPath: tree.path + "/plan.json"))
        let result = try executePlan(tree.path + "/plan.json", environment: env)
        #expect(result.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: marker))
        let record = try #require(try result.jsonObject())
        #expect(record["batchStatus"] as? String == "failed")
        let diff = try #require(record["diff"] as? [String: Any])
        #expect((diff["entries"] as? [[String: Any]])?.isEmpty == false)
        let id = try #require(record["batchID"] as? String)
        #expect(try CLIRunner.run(["rollback", "--batch", id], environment: env).exitCode == 0)
    }
}
