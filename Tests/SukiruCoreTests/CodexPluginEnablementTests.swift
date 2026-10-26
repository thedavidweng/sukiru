import Foundation
import Testing

@testable import SukiruCore

@Suite("Codex plugin enablement edit")
struct CodexPluginEnablementTests {
    private func edit(_ text: String, enabled: Bool = false) throws -> String {
        let data = try CodexPluginEnablement.edit(
            Data(text.utf8), identifier: "demo@team", enabled: enabled, path: "config.toml")
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test("Only the enabled value changes; comments, spacing and other tables stay")
    func replacesValue() throws {
        let text = """
            # top
            model = "x"

            [plugins."demo@team"]  # mine
            enabled   =  true # keep

            [plugins."other@team"]
            enabled = true

            """
        let expected = text.replacingOccurrences(
            of: "enabled   =  true", with: "enabled   =  false")
        #expect(try edit(text) == expected)
        #expect(try edit(expected, enabled: true) == text)
    }

    @Test("A missing key is inserted after the header with the header's line ending")
    func insertsAfterHeader() throws {
        #expect(
            try edit("[plugins.\"demo@team\"]\r\n# note\r\n")
                == "[plugins.\"demo@team\"]\r\nenabled = false\r\n# note\r\n")
        let unterminated = "a = 1\n[plugins.\"demo@team\"]"
        #expect(try edit(unterminated) == unterminated + "\nenabled = false")
    }

    @Test("Header-like lines inside multi-line strings and arrays are not tables")
    func skipsMultilineValues() throws {
        let text = """
            notes = \"\"\"
            [plugins."demo@team"]
            enabled = false
            tail = 1 \"\"\"
            list = [
              ["nested"],
            ]
            [plugins."demo@team"]
            enabled = true

            """
        #expect(try edit(text).hasSuffix("[plugins.\"demo@team\"]\nenabled = false\n"))
    }

    @Test(
        "Unsupported or ambiguous representations are refused",
        arguments: [
            "[plugins.\"demo@team\"]\nenabled = true\n[plugins.\"demo@team\"]\nenabled = true\n",
            "plugins.\"demo@team\".enabled = true\n[plugins.\"demo@team\"]\n",
            "[plugins]\n\"demo@team\" = { enabled = true }\n",
            "[plugins.\"demo@team\"]\nenabled = \"true\"\n",
            "[plugins.\"demo@team\"]\nenabled = [\n  true,\n]\n",
            "[plugins.\"demo@team\"]\nenabled = true\nenabled = true\n",
            "[[plugins.\"demo@team\"]]\nenabled = true\n",
            "[plugins.\"other@team\"]\nenabled = true\n",
            "[plugins.\"demo@team\"]\nenabled = false\n"
        ])
    func refusals(text: String) {
        #expect(throws: PluginLifecycleError.self) { try edit(text) }
    }

    @Test("Non-UTF-8 bytes are refused")
    func unreadable() {
        #expect(throws: PluginLifecycleError.self) {
            try CodexPluginEnablement.edit(
                Data([0x5B, 0xFF, 0x5D]), identifier: "demo@team", enabled: false, path: "x")
        }
    }

    @Test("The file operation argv round-trips and rejects a non-boolean value")
    func argv() {
        let operation = FileOperation.replaceConfigSource(
            path: "/c.toml", hash: "h", contents: "YQ==", pluginID: "demo@team", enabled: false)
        #expect(FileOperation(argv: operation.argv) == operation)
        #expect(operation.paths == ["/c.toml"])
        var argv = operation.argv
        argv[6] = "maybe"
        #expect(FileOperation(argv: argv) == nil)
    }
}
