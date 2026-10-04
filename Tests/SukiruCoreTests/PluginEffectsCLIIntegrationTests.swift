import Foundation
import Testing

@Suite("Confirmed plugin effects")
struct PluginEffectsCLIIntegrationTests {
    @Test(
        "OpenCode v1 installs and replaces in verified scopes only after effects consent",
        arguments: ["user", "project", "local"])
    func v1Installation(scope: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let root = scope == "user" ? home : project
        let marker = root + (scope == "user" ? "/.config/opencode/mutation" : "/.opencode/mutation")
        try installShim(tree: tree, marker: marker)
        let env = CLIRunner.fixtureEnvironment(
            home: home, roots: [project], path: tree.path + "/bin:/usr/bin:/bin")
        for action in ["install", "replace"] {
            let request = try tree.file(
                "requests.json",
                contents: """
                    [{"host":"opencode","action":"\(action)","target":"demo@2.0.0",
                      "scope":"\(scope)","scopeRoot":"\(root)"}]
                    """)
            let plan = try CLIRunner.run(
                ["plugins", "plan", "--requests", request], environment: env)
            #expect(plan.exitCode == 0)
            let planned = try #require(try plan.jsonObject())
            let batch = try #require(planned["batch"] as? [String: Any])
            let command = try #require((batch["commands"] as? [[String: Any]])?.first)
            var expected = ["opencode", "plugin", "demo@2.0.0"]
            if scope == "user" { expected.append("--global") }
            if action == "replace" { expected.append("--force") }
            #expect(command["argv"] as? [String] == expected)
            #expect((command["warning"] as? String)?.contains("outside captured roots") == true)
            let refused = try CLIRunner.run(
                ["plugins", "execute", "--requests", request, "--reviewed"], environment: env)
            #expect(refused.exitCode == 1)
            #expect(!FileManager.default.fileExists(atPath: marker))
            let execute = try CLIRunner.run(
                ["plugins", "execute", "--requests", request, "--reviewed", "--confirm-dangerous"],
                environment: env)
            #expect(execute.exitCode == 0)
            let record = try #require(try execute.jsonObject())
            #expect((record["unrestorableEffects"] as? [String])?.isEmpty == false)
            #expect(
                try String(contentsOfFile: marker, encoding: .utf8)
                    == expected.dropFirst().joined(separator: " "))
            let id = try #require(record["batchID"] as? String)
            let rollback = try CLIRunner.run(["rollback", "--batch", id], environment: env)
            #expect(rollback.exitCode == 0)
            #expect(!FileManager.default.fileExists(atPath: marker))
        }
    }

    private func installShim(tree: TempTree, marker: String) throws {
        try tree.executable(
            "bin/opencode",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo v1.18.34;;
                *--help*) echo 'plugin <module> --global --force';;
                *) mkdir -p '\(URL(fileURLWithPath: marker).deletingLastPathComponent().path)'
                   printf '%s' "$*" > '\(marker)';;
                esac
                """)
    }

    @Test("OpenCode v1 Git subdirectory captures and restores the actual worktree config")
    func gitSubdirectory() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let repository = try tree.dir("repository")
        let project = try tree.dir("repository/packages/app")
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--quiet", repository]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0)
        let marker = try tree.file("repository/.opencode/opencode.json", contents: "original")
        try installShim(tree: tree, marker: marker)
        let request = try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"install","target":"demo@2.0.0",
                  "scope":"project","scopeRoot":"\(project)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(
            home: home, roots: [project], path: tree.path + "/bin:/usr/bin:/bin")
        let plan = try CLIRunner.run(["plugins", "plan", "--requests", request], environment: env)
        let planned = try #require(try plan.jsonObject())
        let batch = try #require(planned["batch"] as? [String: Any])
        let command = try #require((batch["commands"] as? [[String: Any]])?.first)
        let physicalRoot =
            URL(fileURLWithPath: repository).resolvingSymlinksInPath().path + "/.opencode"
        #expect((command["captureRoots"] as? [String])?.contains(physicalRoot) == true)
        #expect((command["warning"] as? String)?.contains(physicalRoot) == true)
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "original")
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", request, "--reviewed", "--confirm-dangerous"],
            environment: env)
        #expect(result.exitCode == 0)
        let record = try #require(try result.jsonObject())
        let id = try #require(record["batchID"] as? String)
        #expect(try CLIRunner.run(["rollback", "--batch", id], environment: env).exitCode == 0)
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "original")
    }

    @Test("OpenCode v1 replacement refuses missing force capability before execution")
    func missingForce() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/mutation"
        try tree.executable(
            "bin/opencode",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo v1.18.34;;
                *--help*) echo '--global';;
                *) touch '\(marker)';;
                esac
                """)
        let request = try tree.file(
            "requests.json",
            contents: """
                [{"host":"opencode","action":"replace","target":"demo@2.0.0",
                  "scope":"user","scopeRoot":"\(home)"}]
                """)
        let result = try CLIRunner.run(
            ["plugins", "execute", "--requests", request, "--reviewed", "--confirm-dangerous"],
            environment: CLIRunner.fixtureEnvironment(
                home: home, path: tree.path + "/bin:/usr/bin:/bin"))
        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
