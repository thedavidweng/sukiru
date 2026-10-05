import Foundation
import Testing

@Suite("Product CLI guards")
struct ProductCLIGuardTests {
    @Test("Health and plugin health start no subprocess, even with every host on PATH")
    func passiveHealth() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let marker = tree.path + "/spawned"
        for tool in ["npx", "npm", "node", "gh", "git", "claude", "codex", "opencode", "agent"] {
            try tree.executable("bin/" + tool, contents: "#!/bin/sh\necho \"$0\" >> '\(marker)'\n")
        }
        try tree.file(
            "home/.agents/skills/orphan/SKILL.md",
            contents: "---\nname: orphan\ndescription: Local skill\n---\nLocal skill")
        try tree.file(
            "home/.config/opencode/plugins/old.ts",
            contents: "export const Old = async () => ({})\n")
        let env = CLIRunner.fixtureEnvironment(home: home, path: tree.path + "/bin:/usr/bin:/bin")
        for arguments in [["health", "--json"], ["plugins", "health", "--json"]] {
            let result = try CLIRunner.run(arguments, environment: env)
            #expect(result.exitCode == 0, "\(result.stderrText)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Fix skips repairs that need npx skills when Node is missing, as the app does")
    func fixWithoutNode() throws {
        let tree = try TempTree()
        let copy = tree.path + "/fixture"
        try FileManager.default.copyItem(
            atPath: FixturePaths.tree("FIX-LOCK-NO-FILES"), toPath: copy)
        let home = FixturePaths.homeAndRoots(atPath: copy).home
        let result = try CLIRunner.run(
            ["clean", "--yes", "--confirm-dangerous"],
            environment: CLIRunner.fixtureEnvironment(home: home))
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(result.stderrText.contains("needs npx skills"))
        #expect(
            !FileManager.default.fileExists(atPath: home + "/Library/Application Support/Sukiru"))
    }

    @Test("Plugin diagnostics follow --host selection")
    func hostFilteredIssues() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file("home/.codex/config.toml", contents: "[plugins.\"demo@team\"\nbroken")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let other = try CLIRunner.run(
            ["plugins", "list", "--host", "claude-code"], environment: env)
        #expect(!other.stderrText.contains("TOML"))
        let codex = try CLIRunner.run(["plugins", "list", "--host", "codex"], environment: env)
        #expect(codex.stderrText.contains("TOML"))
    }
}
