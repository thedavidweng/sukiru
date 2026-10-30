import Foundation
import Testing

@testable import SukiruCore

struct AntigravityPluginInventoryTests {
    @Test("Shared preferences use directory identity across user and project scopes")
    func identityAndEnablement() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        try tree.file(
            "home/.gemini/config/config.json",
            contents: "{\"plugins\":{\"-123\":{\"enabled\":false}}}")
        for root in ["home/.gemini/config", "project/.agents"] {
            try tree.file(
                root + "/plugins/-123/plugin.json",
                contents: "{\"name\":\"Friendly\",\"disabled\":false}")
        }
        try tree.file(
            "home/.gemini/antigravity-cli/builtin/plugins/builtin/PLUGIN.JSON",
            contents: "{\"disabled\":true,}")
        let inventory = read(home, roots: [project])
        let twins = inventory.installations.filter { $0.identifier == "-123" }
        #expect(twins.count == 2)
        #expect(Set(twins.map(\.id)).count == 2)
        #expect(
            twins.allSatisfy {
                $0.name == "Friendly" && $0.enablement == .disabled && $0.loadStatus == "unknown"
            })
        #expect(
            inventory.installations.first { $0.identifier == "builtin" }?.enablement == .disabled)
        #expect(inventory.issues.isEmpty)
    }

    @Test("Cached catalogs keep listing details, string or list categories and the fetch date")
    func catalogDetails() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let cache = "home/.gemini/antigravity-cli/cache/marketplaces/"
        try tree.file(
            cache + "partners/marketplace.json",
            contents: """
                {"name":"antigravity-plugins-partners","plugins":[
                 {"name":"stripe","displayName":"Stripe","version":"0.0.1","description":"Payments",
                  "logo":"https://www.gstatic.com/s.svg",
                  "author":{"name":"Stripe"},"repository":"https://github.com/stripe/ai",
                  "category":"Developer Tools","keywords":["payments"],"suggestedPrompts":["List products"]},
                 {"name":"multi","category":["Security","Productivity"]}]}
                """)
        try tree.file(
            cache + "partners/meta.json", contents: "{\"lastModified\":\"Thu, 29 Oct 2026\"}")
        try tree.file(
            cache + "official/marketplace.json",
            contents:
                "{\"name\":\"antigravity-plugins-official\",\"plugins\":[{\"name\":\"firebase\"}]}")
        let marketplaces = read(home, roots: []).marketplaces
        let partners = try #require(
            marketplaces.first { $0.name == "antigravity-plugins-partners" })
        #expect(partners.updatedAt == "Thu, 29 Oct 2026")
        let stripe = try #require(partners.plugins.first { $0.name == "stripe" })
        #expect(stripe.displayName == "Stripe" && stripe.summary == "Payments")
        #expect(stripe.logo == "https://www.gstatic.com/s.svg")
        #expect(stripe.author == "Stripe" && stripe.repository == "https://github.com/stripe/ai")
        #expect(
            stripe.categories == ["Developer Tools"] && stripe.suggestedPrompts == ["List products"]
        )
        #expect(
            partners.plugins.first { $0.name == "multi" }?.categories == [
                "Security", "Productivity"
            ])
        let official = try #require(
            marketplaces.first { $0.name == "antigravity-plugins-official" })
        #expect(official.updatedAt == nil && official.plugins.first?.displayName == nil)
    }
    @Test("Native component inventory lists names and declaration files without exposing secrets")
    func components() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let root = "home/.gemini/config/plugins/demo/"
        try tree.file(
            root + "plugin.json",
            contents: """
                {"skills":["./extra","./skills/review"],
                 "extensions":{"com.google.antigravity":{
                   "contextProviders":{"drive":{"command":["secret-command"]}}
                 }}}
                """)
        for file in [
            "skills/review/SKILL.md", "extra/SKILL.md", "agents/reviewer.md", "rules/AGENTS.md"
        ] {
            try tree.file(root + file, contents: "private-content")
        }
        for file in ["skills.json", "rules.json", "agents.json", "sidecars.json"] {
            try tree.file(root + file, contents: "{\"entries\":[]}")
        }
        try tree.file(
            root + "mcp_config.json",
            contents: "{\"mcpServers\":{\"db\":{\"env\":{\"TOKEN\":\"secret-value\"}}}}")
        try tree.file(
            root + "hooks.json", contents: "{\"PreToolUse\":[{\"command\":\"secret-command\"}]}")
        try tree.file(
            root + "sidecars/worker/sidecar.json", contents: "{\"command\":\"secret-command\"}")
        try tree.file(root + "workflows/ignored.md", contents: "ignored")
        let inventory = read(home)
        let plugin = try #require(inventory.installations.first)
        for name in [
            "review", "extra", "reviewer.md", "AGENTS.md", "db", "PreToolUse", "worker", "drive",
            "skills.json", "rules.json", "agents.json", "sidecars.json"
        ] {
            #expect(plugin.components.contains { $0.name == name }, "Missing component: \(name)")
        }
        #expect(!plugin.components.contains { $0.name == "ignored.md" })
        #expect(plugin.components.filter { $0.name == "review" }.count == 1)
        let encoded = try #require(String(bytes: JSONEncoder().encode(inventory), encoding: .utf8))
        #expect(
            !encoded.contains("secret-command") && !encoded.contains("secret-value")
                && !encoded.contains("private-content"))
        #expect(inventory.issues.isEmpty)
    }

    @Test("Inherited configuration discovers candidates and reports unverified pattern membership")
    func configuration() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("repo/sub")
        try tree.dir("repo/.git")
        try tree.file(
            "repo/.agents/plugins.json",
            contents: "{\"inherits\":[{\"path\":\"shared/plugins.json\"}]}")
        try tree.file(
            "repo/shared/plugins.json",
            contents: """
                {"entries":[{"path":"\(tree.path)/repo/shared/pool",
                  "include_only":["nested/wanted"],"exclude":["experimental-.*"]}]}
                """)
        try tree.file("repo/shared/pool/nested/wanted/plugin.json", contents: "{}")
        try tree.file("repo/shared/pool/experimental-one/plugin.json", contents: "{}")
        let inventory = read(home, roots: [project])
        #expect(
            inventory.installations.contains {
                $0.identifier == "wanted" && $0.scopeRoot == project
            })
        #expect(
            inventory.issues.contains {
                $0.kind == "plugin-discovery" && $0.message.contains("patterns")
            })
    }

    @Test("Malformed enablement and escaped component symlinks remain visible issues")
    func invalidInputs() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        try tree.file("home/.gemini/config/config.json", contents: "{\"plugins\":[]}")
        let root = "home/.gemini/config/plugins/demo/"
        try tree.file(root + "plugin.json", contents: "{\"skills\":[\"\(tree.path)/private\"]}")
        let outside = try tree.file("private/SKILL.md", contents: "private-content")
        let skills = try tree.dir(root + "skills/escaped")
        try FileManager.default.createSymbolicLink(
            atPath: skills + "/SKILL.md", withDestinationPath: outside)
        let inventory = read(home)
        #expect(inventory.installations.first?.enablement == .unknown)
        #expect(inventory.installations.first?.components.isEmpty == true)
        #expect(inventory.issues.contains { $0.kind == "plugin-containment" })
        #expect(inventory.issues.contains { $0.kind == "plugin-config" })
    }

    private func read(_ home: String, roots: [String] = []) -> PluginInventory {
        PluginInventoryReader(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader([
                    "SUKIRU_HOME": home, "SUKIRU_ROOTS": roots.joined(separator: ":")
                ]))
        )
        .read(ScanRequest())
    }
}
