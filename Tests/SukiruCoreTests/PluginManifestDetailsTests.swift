import Foundation
import Testing

@testable import SukiruCore

@Suite("Plugin manifest details")
struct PluginManifestDetailsTests {
    @Test("Codex interface text and logo win, and a local logo resolves inside the plugin")
    func codexInterface() throws {
        let tree = try TempTree()
        let icon = try tree.file("plugin/assets/icon.svg", contents: "<svg/>")
        let details = PluginManifestDetails(
            [
                "description": "Long form",
                "interface": ["shortDescription": "Short", "logo": "./assets/icon.svg"]
            ],
            root: tree.path + "/plugin")
        #expect(details.summary == "Short")
        #expect(
            details.logo.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == URL(fileURLWithPath: icon).resolvingSymlinksInPath().path)
    }

    @Test("A logo outside the plugin or with another scheme is ignored")
    func rejectsEscapes() throws {
        let tree = try TempTree()
        try tree.file("outside.png", contents: "x")
        try tree.dir("plugin")
        let root = tree.path + "/plugin"
        #expect(PluginManifestDetails(["logo": "../outside.png"], root: root).logo == nil)
        #expect(PluginManifestDetails(["logo": "http://example.com/a.png"], root: root).logo == nil)
        let remote = PluginManifestDetails(
            ["description": "Plain", "logo": "https://example.com/a.png"], root: root)
        #expect(remote.logo == "https://example.com/a.png")
        #expect(remote.summary == "Plain")
    }
}
