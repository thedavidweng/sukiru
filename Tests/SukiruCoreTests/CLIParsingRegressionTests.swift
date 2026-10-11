import Foundation
import Testing

@Suite("CLI parsing contracts")
struct CLIParsingRegressionTests {
    @Test(
        "Every command path exposes help without required arguments",
        arguments: [
            "", "health", "clean", "fix", "search", "install", "snapshots", "rollback",
            "capabilities", "scan", "batch", "skills", "skills list", "skills update",
            "skills uninstall", "skills pin", "skills unpin", "skills restore", "skills adopt",
            "skills mode", "skills check-updates", "hooks", "hooks inventory", "hooks plan",
            "hooks execute", "plugins", "plugins list", "plugins health", "plugins capabilities",
            "plugins install", "plugins update", "plugins enable", "plugins disable",
            "plugins disable-local", "plugins uninstall", "plugins plan", "plugins execute",
            "plugins marketplaces", "plugins marketplaces list", "plugins marketplaces add",
            "plugins marketplaces refresh", "plugins marketplaces remove"
        ])
    func help(path: String) throws {
        let result = try CLIRunner.run(
            path.split(separator: " ").map(String.init) + ["--help"], environment: [:])
        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(String(data: result.stdout, encoding: .utf8)?.contains("USAGE:") == true)
    }

    @Test(
        "Invalid arguments are usage errors before any execution",
        arguments: [
            ["scan", "--scope"], ["scan", "--scope=everything"], ["scan", "extra"],
            ["snapshots", "--root", "/tmp"], ["health", "--json=true"],
            ["search", "query", "--limit=oops"], ["search", "query", "--limit=0"],
            ["skills", "pin", "demo"], ["skills", "update", "demo", "--all"],
            ["skills", "uninstall", "--all"], ["batch", "--decisions=d.json", "--yes"],
            ["fix", "--command-timeout=nan"], ["fix", "--command-timeout=-1"],
            ["rollback", "--batch=b", "--restore=relative"],
            ["install", "repo", "--installer=invalid", "--skill=demo"],
            ["scan", "--scope=invalid", "--scope=user"],
            ["search", "query", "--limit=oops", "--limit=20"],
            ["scan", "--json=true", "--help"], ["scan", "--scope=invalid", "--help"]
        ])
    func invalid(arguments: [String]) throws {
        let result = try CLIRunner.run(arguments, environment: [:])
        #expect(result.exitCode == 64)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }

    @Test("Equals syntax and repeated scalar options match separate values")
    func optionValues() throws {
        let inputs = FixturePaths.homeAndRoots("scope-isolation")
        let environment = CLIRunner.fixtureEnvironment(home: inputs.home, roots: inputs.roots)
        let separate = try CLIRunner.run(["scan", "--scope", "user"], environment: environment)
        let equals = try CLIRunner.run(
            ["scan", "--scope=project", "--scope=user"], environment: environment)
        #expect(separate.exitCode == 0)
        #expect(equals.exitCode == 0)
        #expect(equals.stdout == separate.stdout)
    }

    @Test("Version and short help flags succeed without a configured home")
    func builtIns() throws {
        let version = try CLIRunner.run(["--version"], environment: [:])
        #expect(version.exitCode == 0)
        #expect(!version.stdout.isEmpty)
        let help = try CLIRunner.run(["skills", "pin", "-h"], environment: [:], json: false)
        #expect(help.exitCode == 0)
        #expect(String(data: help.stdout, encoding: .utf8)?.contains("--ref") == true)
    }

    @Test(
        "Shell completion scripts include commands and options", arguments: ["bash", "zsh", "fish"])
    func completions(shell: String) throws {
        let result = try CLIRunner.run(
            ["--generate-completion-script", shell], environment: [:], json: false)
        #expect(result.exitCode == 0)
        let script = try #require(String(data: result.stdout, encoding: .utf8))
        #expect(script.contains("confirm-dangerous"))
        #expect(script.contains("marketplaces"))
    }
}
