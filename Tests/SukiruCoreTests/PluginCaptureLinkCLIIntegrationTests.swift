import Foundation
import Testing

@Suite("Plugin capture through links")
struct PluginCaptureLinkCLIIntegrationTests {
    @Test("Retargeted ancestor links require a choice and preserve the new target")
    func ancestorLinkConflict() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let external = try tree.dir("external")
        let newTarget = try tree.dir("new-target")
        let original = try tree.file("external/plugins/demo", contents: "original")
        let unrelated = try tree.file("external/unrelated", contents: "untouched")
        let newFile = try tree.file("new-target/plugins/demo", contents: "new target bytes")
        let link = home + "/.agents"
        try tree.symlink("home/.agents", to: external)
        try codexStub(in: tree)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"codex","action":"remove","target":"demo@team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let execute = try CLIRunner.run(
            [
                "plugins", "execute", "--requests", tree.path + "/requests.json", "--yes",
                "--confirm-dangerous"
            ], environment: env)
        #expect(
            execute.exitCode == 0)
        let record = try #require(try execute.jsonObject())
        let batchID = try #require(record["batchID"] as? String)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: newTarget)
        try "later unrelated edit".write(toFile: unrelated, atomically: true, encoding: .utf8)
        let refused = try CLIRunner.run(["rollback", "--yes", "--batch", batchID], environment: env)
        #expect(refused.exitCode != 0)
        #expect(try String(contentsOfFile: newFile, encoding: .utf8) == "new target bytes")
        let rollback = try CLIRunner.run(
            [
                "rollback", "--yes", "--batch", batchID, "--preserve", link, "--preserve",
                link + "/plugins/demo"
            ], environment: env)
        #expect(
            rollback.exitCode == 0)
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "original")
        #expect(try String(contentsOfFile: newFile, encoding: .utf8) == "new target bytes")
        #expect(try String(contentsOfFile: unrelated, encoding: .utf8) == "later unrelated edit")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == newTarget)
    }

    @Test(
        "Native writes through root and config links have byte exact rollback",
        arguments: ["root", "file"])
    func linkedCapture(kind: String) throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let external = try tree.dir("external")
        let original = #"{"enabledPlugins":{"demo@team":true}}"#
        let settings = try tree.file("external/settings.json", contents: original)
        if kind == "root" {
            try tree.symlink("home/.claude", to: external)
        } else {
            try tree.symlink("home/.claude/settings.json", to: settings)
        }
        try tree.executable(
            "bin/claude",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 2.1.288;;
                *--help*) echo '--scope --json';;
                *) printf '{}' > "$HOME/.claude/settings.json"; echo '{}';;
                esac
                """)
        try tree.file(
            "requests.json",
            contents: """
                [{"host":"claude","action":"disable","target":"demo@team","scope":"user","scopeRoot":"\(home)"}]
                """)
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        let execute = try CLIRunner.run(
            ["plugins", "execute", "--requests", tree.path + "/requests.json", "--yes"],
            environment: env)
        #expect(
            execute.exitCode == 0)
        let record = try #require(try execute.jsonObject())
        let batchID = try #require(record["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID], environment: env)
        #expect(
            rollback.exitCode == 0)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == original)
        let link = kind == "root" ? home + "/.claude" : home + "/.claude/settings.json"
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link)
                == (kind == "root" ? external : settings))
    }
    private func codexStub(in tree: TempTree) throws {
        try tree.executable(
            "bin/codex",
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo 'codex-cli 0.160.0';;
                *--help*) echo '--json';;
                *) printf changed > "$HOME/.agents/plugins/demo"; echo '{}';;
                esac
                """)
    }

}
