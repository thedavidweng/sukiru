import Foundation
import Testing

@Suite("OpenCode plugin lifecycle CLI")
struct OpenCodeLifecycleCLIIntegrationTests {
    static func opencode(
        version: String, projects: [String] = [], onRun: String = ""
    ) throws -> PluginHostFixture {
        let fixture = try PluginHostFixture(
            host: "opencode", version: version, help: "add remove --global --force",
            projects: projects, onRun: onRun)
        try fixture.tree.file(
            "home/.config/opencode/opencode.json",
            contents: #"{"plugins":["demo@1.0.0","@scope/other@2.0.0"]}"#)
        try fixture.tree.file(
            "home/.config/opencode/plugins/old.ts",
            contents: "export const Old = async () => ({})\n")
        return fixture
    }

    @Test(
        "v2 add and remove dispatch native argv, keep their diff and roll back",
        arguments: [["install", "plugin add fresh"], ["remove", "plugin remove demo@1.0.0"]])
    func v2RoundTrip(values: [String]) throws {
        let fixture = try Self.opencode(
            version: "v2.0.22",
            onRun: "printf '{\"plugins\":[]}' > \"$HOME/.config/opencode/opencode.json\"")
        let target = values[0] == "install" ? "fresh" : "demo@1.0.0"
        let config = fixture.home + "/.config/opencode/opencode.json"
        let original = try String(contentsOfFile: config, encoding: .utf8)
        let plan = try fixture.plan([fixture.request(values[0], target)])
        let argv = try #require(try plan.plannedCommands().first?["argv"] as? [String])
        #expect(argv.joined(separator: " ") == "opencode " + values[1])

        let result = try fixture.execute([fixture.request(values[0], target)])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(fixture.invocations == [values[1]])
        #expect(try String(contentsOfFile: config, encoding: .utf8) != original)
        #expect(try fixture.rollback(result).exitCode == 0)
        #expect(try String(contentsOfFile: config, encoding: .utf8) == original)
    }

    @Test("v2 add and remove stay global; project scope gets the host's limit")
    func v2ProjectScope() throws {
        let fixture = try Self.opencode(version: "v2.0.22", projects: ["project"])
        let project = try #require(fixture.roots.first)
        for action in ["install", "remove"] {
            let result = try fixture.plan([
                fixture.request(action, "demo", scope: "project", root: project)
            ])
            #expect(
                try result.instructions().first?.contains("global package configuration") == true)
        }
    }

    @Test("Removing an auto-discovered file never becomes a package configuration removal")
    func discoveredRemoval() throws {
        let fixture = try Self.opencode(version: "v2.0.22")
        let result = try fixture.execute([fixture.request("remove", "old.ts")])
        #expect(result.exitCode == 1)
        #expect(try result.instructions().first?.contains("auto-discovered local file") == true)
        #expect(fixture.invocations.isEmpty)
    }

    @Test("v1 force replacement names the configured version it replaces")
    func v1ReplaceImpact() throws {
        let fixture = try Self.opencode(version: "v1.18.34")
        try fixture.tree.file(
            "home/.config/opencode/opencode.json",
            contents: #"{"plugin":["demo@1.0.0","@scope/other@2.0.0"]}"#)
        let result = try fixture.plan([fixture.request("replace", "demo@2.0.0")])
        let warning = try #require(try result.plannedCommands().first?["warning"] as? String)
        #expect(warning.contains("Configured versions replaced: demo@1.0.0"))
        #expect(!warning.contains("@scope/other"))

        let scoped = try fixture.plan([fixture.request("replace", "@scope/other@3.0.0")])
        let scopedWarning = try #require(
            try scoped.plannedCommands().first?["warning"] as? String)
        #expect(scopedWarning.contains("@scope/other@2.0.0"))
    }

    @Test("v1 refuses local paths, and newer v1 releases keep the v1 interface")
    func v1Contract() throws {
        let fixture = try Self.opencode(version: "v1.19.2")
        let local = try fixture.plan([fixture.request("install", "./plugin.ts")])
        #expect(try local.instructions().first?.contains("npm package specs") == true)
        let package = try fixture.plan([fixture.request("install", "demo@2.0.0")])
        let argv = try #require(try package.plannedCommands().first?["argv"] as? [String])
        #expect(argv == ["opencode", "plugin", "demo@2.0.0", "--global"])
    }

    @Test("Runtime-wide operations enumerate the configured packages they affect")
    func wildcardImpact() throws {
        let fixture = try Self.opencode(version: "v2.1.0")
        let result = try fixture.plan([fixture.request("update", "*")])
        let warning = try #require(try result.plannedCommands().first?["warning"] as? String)
        #expect(warning.contains("demo@1.0.0"))
        #expect(warning.contains("@scope/other@2.0.0"))
        #expect(!warning.contains("old.ts"))
    }

    @Test("The product CLI disables an incompatible local file and rolls it back")
    func disableLocalCommand() throws {
        let fixture = try Self.opencode(version: "v2.0.22")
        let file = fixture.home + "/.config/opencode/plugins/old.ts"
        let result = try CLIRunner.run(
            [
                "plugins", "disable-local", file, "--host", "opencode", "--scope", "user",
                "--yes", "--confirm-dangerous", "--json"
            ], environment: fixture.environment)
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try fixture.rollback(result).exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: file))
    }
}
