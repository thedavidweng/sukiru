import Foundation
import Testing

@Suite("Product CLI", .serialized)
struct ProductCLIIntegrationTests {
    private static func text(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    @Test("Health is human by default, passive, and check mode distinguishes Problems")
    func healthContract() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let environment = CLIRunner.fixtureEnvironment(home: home)
        let before = try TreeChecksum.manifest(root: home)
        let healthy = try CLIRunner.run(
            ["health", "--check"], environment: environment, json: false)
        #expect(healthy.exitCode == 0)
        #expect((try Self.text(healthy.stdout)).contains("Healthy"))
        #expect(try TreeChecksum.manifest(root: home) == before)

        try tree.file(
            "home/.agents/skills/orphan/SKILL.md",
            contents: "---\nname: orphan\ndescription: Local skill\n---\nLocal skill")
        let actionable = try CLIRunner.run(
            ["health", "--check", "--json"], environment: environment)
        #expect(actionable.exitCode == 1)
        #expect(try actionable.jsonObject()?["skills"] is [[String: Any]])
        let ordinary = try CLIRunner.run(["health", "--json"], environment: environment)
        #expect(ordinary.exitCode == 0)
        let failed = try CLIRunner.run(
            ["health", "--check", "--json"],
            environment: CLIRunner.fixtureEnvironment(home: home + "/missing"))
        #expect(failed.exitCode == 2)
        #expect(failed.stdout.isEmpty)
    }
    @Test("Health JSON respects the same host selection as human output")
    func selectedHost() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.agents/skills/alpha/SKILL.md",
            contents: "---\nname: alpha\ndescription: Alpha\n---\n")
        try tree.symlink("home/.claude/skills/alpha", to: home + "/.agents/skills/alpha")
        try tree.file(
            "home/.codex/skills/beta/SKILL.md",
            contents: "---\nname: beta\ndescription: Beta\n---\n")
        let result = try CLIRunner.run(
            ["health", "--host", "claude-code", "--json"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 0)
        let object = try #require(try result.jsonObject())
        let skills = try #require(object["skills"] as? [[String: Any]])
        #expect(skills.compactMap { $0["name"] as? String } == ["alpha"])
    }

    @Test("Project installs still guard the user Vercel ledger against GitHub companion writes")
    func projectInstallGuardsUserLedger() throws {
        let tree = try TempTree()
        let home = tree.path + "/home"
        try FileManager.default.copyItem(atPath: FixturePaths.tree("impostor-copy"), toPath: home)
        let inputs = FixturePaths.homeAndRoots(atPath: home)
        let project = try tree.dir("project")
        let result = try CLIRunner.run(
            [
                "install", "acme/skills", "--skill", "tool", "--installer", "github",
                "--host", "claude-code", "--scope", "project", "--root", project, "--dry-run"
            ],
            environment: CLIRunner.fixtureEnvironment(home: inputs.home))
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect((try Self.text(result.stderr)).contains("Vercel"))
    }

    @Test("Root command exposes product help, version, and generated shell completions")
    func discoverability() throws {
        let tree = try TempTree()
        let env = CLIRunner.fixtureEnvironment(home: tree.path)
        let help = try CLIRunner.run(["--help"], environment: env, json: false)
        let text = (try Self.text(help.stdout))
        #expect(help.exitCode == 0)
        for name in ["health", "clean", "fix", "skills", "plugins", "snapshots", "rollback"] {
            #expect(text.contains(name))
        }
        for shell in ["bash", "zsh", "fish"] {
            let result = try CLIRunner.run(
                ["--generate-completion-script", shell], environment: env, json: false)
            #expect(result.exitCode == 0)
            #expect((try Self.text(result.stdout)).contains("sukiru"))
        }
        let version = try CLIRunner.run(["--version"], environment: env, json: false)
        #expect(version.exitCode == 0)
        #expect(!version.stdout.isEmpty)
        let invalid = try CLIRunner.run(["health", "--unknown"], environment: env)
        #expect(invalid.exitCode == 64)
        #expect(invalid.stdout.isEmpty)
        #expect(!invalid.stderr.isEmpty)
    }

    @Test("Clean previews only cleanup; Fix relinks; neither guesses Adoption")
    func maintenanceSelection() throws {
        let tree = try TempTree()
        let copy = tree.path + "/fixture"
        try FileManager.default.copyItem(atPath: FixturePaths.tree("impostor-copy"), toPath: copy)
        let home = FixturePaths.homeAndRoots(atPath: copy).home
        try tree.file(
            "fixture/.agents/skills/orphan/SKILL.md",
            contents: "---\nname: orphan\ndescription: Local\n---\n")
        let before = try TreeChecksum.manifest(root: home)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let clean = try CLIRunner.run(["clean", "--dry-run"], environment: env)
        #expect(clean.exitCode == 0)
        #expect((try Self.text(clean.stdout)) == "null\n")
        let fix = try CLIRunner.run(["fix", "--dry-run"], environment: env)
        #expect(fix.exitCode == 0)
        let batch = try #require(try fix.jsonObject())
        let commands = try #require(batch["commands"] as? [[String: Any]])
        #expect(!commands.isEmpty)
        #expect(commands.allSatisfy { ($0["owningCLI"] as? String) == "file" })
        #expect(try TreeChecksum.manifest(root: home) == before)
        #expect((try Self.text(fix.stderr)).contains("explicit choice"))
    }

    @Test("High-level cleanup is protected, records differences, and can roll back")
    func cleanupRoundTrip() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let link = try tree.symlink("home/.agents/skills/dead", to: home + "/missing")
        try tree.file(
            "home/.agents/skills/orphan/SKILL.md",
            contents: "---\nname: orphan\ndescription: Local\n---\n")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let preview = try CLIRunner.run(["clean", "--dry-run"], environment: env)
        let plan = try #require(try preview.jsonObject())
        let planned = try #require(plan["commands"] as? [[String: Any]])
        let executed = try CLIRunner.run(
            ["clean", "--yes", "--confirm-dangerous"], environment: env)
        let executionDiagnostic = try Self.text(executed.stderr)
        #expect(executed.exitCode == 0, "\(executionDiagnostic)")
        let record = try #require(try executed.jsonObject())
        let commands = try #require(record["commands"] as? [[String: Any]])
        #expect(
            commands.compactMap { $0["argv"] as? [String] }
                == planned.compactMap { $0["argv"] as? [String] })
        #expect(record["batchStatus"] as? String == "succeeded")
        #expect(record["diff"] is [String: Any])
        #expect(!FileManager.default.fileExists(atPath: link))
        #expect(FileManager.default.fileExists(atPath: home + "/.agents/skills/orphan"))
        let snapshots = try CLIRunner.run(["snapshots"], environment: env)
        #expect(
            (try JSONSerialization.jsonObject(with: snapshots.stdout) as? [[String: Any]])?.count
                == 1)
        let batchID = try #require(record["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--batch", batchID, "--yes"], environment: env)
        let rollbackDiagnostic = try Self.text(rollback.stderr)
        #expect(rollback.exitCode == 0, "\(rollbackDiagnostic)")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link) == home + "/missing")
    }

    @Test("Normal confirmation cannot bypass danger, and snapshot failure blocks cleanup")
    func cleanupGates() throws {
        let tree = try TempTree()
        let copy = tree.path + "/fixture"
        try FileManager.default.copyItem(
            atPath: FixturePaths.tree("FIX-LOCK-NO-FILES"), toPath: copy)
        let home = FixturePaths.homeAndRoots(atPath: copy).home
        let env = CLIRunner.fixtureEnvironment(home: home)
        let refused = try CLIRunner.run(["clean", "--yes"], environment: env)
        #expect(refused.exitCode == 1)
        #expect(refused.stdout.isEmpty)
        #expect((try Self.text(refused.stderr)).contains("--confirm-dangerous"))
        #expect(
            !FileManager.default.fileExists(atPath: home + "/Library/Application Support/Sukiru"))

        let sandbox = try tree.dir("blocked")
        let link = try tree.symlink("blocked/.agents/skills/dead", to: sandbox + "/missing")
        try tree.file(
            "blocked/Library/Application Support/Sukiru/snapshots", contents: "not a directory")
        let failed = try CLIRunner.run(
            ["clean", "--yes", "--confirm-dangerous"],
            environment: CLIRunner.fixtureEnvironment(home: sandbox))
        #expect(failed.exitCode == 1)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link) == sandbox + "/missing")
    }

    @Test("Skill resource mutations delegate lifecycle and reject unsupported ownership")
    func skillLifecycle() throws {
        let inputs = FixturePaths.homeAndRoots("own-github")
        let env = CLIRunner.fixtureEnvironment(home: inputs.home)
        for arguments in [
            ["pin", "unpinned-tool", "--ref", "v1"],
            ["unpin", "pinned-tool"], ["restore", "unpinned-tool"],
            ["update", "unpinned-tool"], ["uninstall", "pinned-tool"]
        ] {
            let result = try CLIRunner.run(["skills"] + arguments + ["--dry-run"], environment: env)
            #expect(result.exitCode == 0)
            let batch = try #require(try result.jsonObject())
            #expect((batch["commands"] as? [[String: Any]])?.isEmpty == false)
        }
        let ownerless = FixturePaths.homeAndRoots("FIX-FILES-NO-LOCK")
        let refused = try CLIRunner.run(
            ["skills", "update", "orphan", "--dry-run"],
            environment: CLIRunner.fixtureEnvironment(home: ownerless.home))
        #expect(refused.exitCode == 1)
        #expect(refused.stdout.isEmpty)
    }

    @Test("Plugin resource commands and project roots map to the official host planner")
    func pluginResource() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo 'disable --json --scope';;
                *) exit 91;;
                esac
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let result = try CLIRunner.run(
            [
                "plugins", "disable", "demo@team", "--host", "claude-code", "--scope", "project",
                "--root", project, "--dry-run"
            ], environment: env)
        #expect(result.exitCode == 0)
        let plan = try #require(try result.jsonObject())
        let batch = try #require(plan["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        #expect(
            command["argv"] as? [String] == [
                "claude", "plugin", "disable", "demo@team", "--scope", "project", "--json"
            ])
        #expect(command["workingDirectory"] as? String == project)
        #expect(
            !FileManager.default.fileExists(atPath: home + "/Library/Application Support/Sukiru"))
    }

    @Test("Explicit search delegates to gh and produces undecorated normalized JSON")
    func searchContract() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.executable(
            "bin/gh",
            contents: """
                #!/bin/sh
                echo '[{"namespace":"acme","repo":"acme/skills","skillName":"demo","path":"demo/SKILL.md","stars":7}]'
                """)
        let result = try CLIRunner.run(
            ["search", "demo", "--backend", "github"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 0)
        let rows = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        #expect(rows.first?["repo"] as? String == "acme/skills")
        #expect(rows.first?["name"] as? String == "demo")
        #expect(result.stderr.isEmpty)
    }

}

extension ProductCLIIntegrationTests {
    @Test("Shared-store Agent Hosts retain their Skills and repair selections")
    func sharedStoreHostSelection() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file(
            "home/.agents/skills/demo/SKILL.md",
            contents: "---\nname: demo\ndescription: Demo\n---\n")
        let env = CLIRunner.fixtureEnvironment(home: home)
        for host in ["cline", "warp", "dexto", "zed"] {
            let listed = try CLIRunner.run(["skills", "list", "--host", host], environment: env)
            #expect(listed.exitCode == 0)
            let rows = try #require(
                try JSONSerialization.jsonObject(with: listed.stdout) as? [[String: Any]])
            #expect(rows.compactMap { $0["name"] as? String } == ["demo"])
        }
    }

    @Test("Health surfaces malformed host inventories and exits 2 for incomplete scans")
    func inventoryFailures() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file("home/.codex/hooks.json", contents: "{broken")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let result = try CLIRunner.run(["health", "--check"], environment: env, json: false)
        #expect(result.exitCode == 2)
        #expect(!(try Self.text(result.stdout)).contains("Healthy"))
        #expect(!result.stderr.isEmpty)
        let json = try CLIRunner.run(["health", "--check", "--json"], environment: env)
        #expect(json.exitCode == 2)
        #expect(try json.jsonObject()?["hookInventory"] is [String: Any])
    }

    @Test("Host selection preserves shared ownership ledger scan failures")
    func hostLedgerFailure() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file("home/.agents/.skill-lock.json", contents: "{broken")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let result = try CLIRunner.run(
            ["health", "--check", "--host", "cline"], environment: env)
        #expect(result.exitCode == 2)
        let report = try #require(try result.jsonObject())
        #expect((report["issues"] as? [[String: Any]])?.isEmpty == false)
    }

}
