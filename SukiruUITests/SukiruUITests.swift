import XCTest

final class SukiruUITests: XCTestCase {
    private var fixture: URL!
    private var home: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-ui-\(UUID().uuidString)", isDirectory: true)
        home = fixture.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try makeCursorFixture()
    }

    override func tearDownWithError() throws {
        let probes = fixture.appendingPathComponent("probes.log")
        if FileManager.default.fileExists(atPath: probes.path) {
            let attachment = try XCTAttachment(string: String(contentsOf: probes, encoding: .utf8))
            attachment.name = "Fixture CLI probes"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    func testCursorPluginInventoryAndMarketplacePreviewStayHostOwned() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        // The sandboxed runner refuses runtime-created executables; bundle the CLI fixture.
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        let probes = fixture.appendingPathComponent("probes.log")
        app.launchEnvironment["SUKIRU_UI_PROBE_LOG"] = probes.path
        let savedProject = fixture.appendingPathComponent("outside-fixture-project")
        try write(
            "---\nname: outside-fixture-skill\ndescription: must not be scanned\n---\n",
            to: savedProject.appendingPathComponent(".agents/skills/outside-fixture-skill/SKILL.md")
        )
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-projectRoots", "(\"\(savedProject.path)\")"
        ]
        app.launch()

        let cursor = app.descendants(matching: .any)["sukiru.sidebar.plugins.cursor"].firstMatch
        XCTAssertTrue(cursor.waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["sukiru.sidebar.hooks.devin"].exists)
        cursor.click()

        XCTAssertTrue(app.staticTexts["local-demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["cached-demo"].waitForExistence(timeout: 10))
        app.staticTexts["All Skills"].click()
        XCTAssertFalse(app.staticTexts["outside-fixture-skill"].exists)
        XCTAssertFalse(app.staticTexts["outside-fixture-project"].exists)
        cursor.click()

        app.staticTexts["local-demo"].click()
        XCTAssertFalse(app.buttons["sukiru.plugins.action.update"].isEnabled)
        XCTAssertFalse(app.switches.firstMatch.exists)
        app.disclosureTriangles["sukiru.plugins.locations"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Discovered local plugin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["style.mdc"].firstMatch.exists)

        app.staticTexts["cached-demo"].click()
        let locations = app.disclosureTriangles["sukiru.plugins.locations"]
        // macOS exposes the label and chevron as one element; only the chevron toggles it.
        if locations.value as? String == "0" {
            locations.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        }
        XCTAssertTrue(
            app.staticTexts["Cached payload; installation unknown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unknown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not Checked"].waitForExistence(timeout: 5))

        app.menuButtons["sukiru.plugins.add"].click()
        let marketplaces = app.menuItems["Marketplaces…"].firstMatch
        XCTAssertTrue(marketplaces.waitForExistence(timeout: 5))
        marketplaces.click()
        XCTAssertTrue(
            app.staticTexts["Git ref: refs/heads/main"].waitForExistence(timeout: 5))
        app.buttons["sukiru.plugins.catalog.done"].click()

        app.menuButtons["sukiru.plugins.add"].click()
        app.menuItems["Install Plugin…"].firstMatch.click()
        app.popUpButtons["sukiru.plugins.operation.action"].click()
        app.menuItems["Add Marketplace"].click()
        app.textFields["sukiru.plugins.operation.target"].click()
        app.textFields["sukiru.plugins.operation.target"].typeText("https://example.com/new.git")
        app.textFields["sukiru.plugins.operation.git-ref"].click()
        app.textFields["sukiru.plugins.operation.git-ref"].typeText("feature/marketplace")
        XCTAssertEqual(
            app.textFields["sukiru.plugins.operation.git-ref"].value as? String,
            "feature/marketplace")
        // Commit the native field editor before asking the default button to read the model.
        app.textFields["sukiru.plugins.operation.target"].click()
        app.buttons["sukiru.plugins.operation.preview"].click()

        XCTAssertTrue(app.staticTexts["Review Changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "Git ref feature/marketplace")
            ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["sukiru.confirm.pluginEffects"].exists)
        XCTAssertTrue(app.buttons["sukiru.confirm.apply.disabled"].exists)
        app.disclosureTriangles.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Show Commands")
        ).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS %@",
                    "agent plugin marketplace add https://example.com/new.git --git-ref feature/marketplace"
                )
            ).firstMatch.waitForExistence(timeout: 5))
        app.buttons["sukiru.confirm.cancel"].click()
        app.terminate()
        let recorded = try String(contentsOf: probes, encoding: .utf8)
        XCTAssertFalse(recorded.contains("plugin marketplace add https://"))
    }

    func testDetectedAgentWithoutHooksKeepsItsHooksRow() throws {
        let launcher = home.appendingPathComponent(".local/bin/devin")
        try write("", to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()

        let devin = app.descendants(matching: .any)["sukiru.sidebar.hooks.devin"].firstMatch
        XCTAssertTrue(devin.waitForExistence(timeout: 15))
        app.terminate()
    }

    func testAgentRowGroupsItsSkillsAndPlugins() throws {
        try write(
            "---\nname: cursor-only-skill\ndescription: read by Cursor\n---\n",
            to: home.appendingPathComponent(".cursor/skills/cursor-only-skill/SKILL.md"))
        try write(
            "---\nname: claude-only-skill\ndescription: read by Claude Code\n---\n",
            to: home.appendingPathComponent(".claude/skills/claude-only-skill/SKILL.md"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()

        let agent = app.descendants(matching: .any).matching(
            identifier: "sukiru.sidebar.agent.cursor")
        XCTAssertTrue(agent.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(agent.count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["sukiru.sidebar.plugins.cursor"].exists)

        app.descendants(matching: .any)["sukiru.sidebar.skills.cursor"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["cursor-only-skill"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["claude-only-skill"].exists)
        app.terminate()
    }

    private func makeCursorFixture() throws {
        let cursorRoot = home.appendingPathComponent(".cursor/plugins", isDirectory: true)
        let local = cursorRoot.appendingPathComponent("local/local-demo", isDirectory: true)
        let cached = cursorRoot.appendingPathComponent(
            "cache/example-repo/cached-demo/1.0", isDirectory: true)
        let marketplace = cursorRoot.appendingPathComponent(
            "marketplaces/personal/.cursor-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)

        try write(
            "{\"name\":\"local-demo\",\"version\":\"1\",\"skills\":\"skills\",\"rules\":\"rules/style.mdc\"}",
            to: local.appendingPathComponent(".cursor-plugin/plugin.json"))
        try write("# Local demo\n", to: local.appendingPathComponent("skills/SKILL.md"))
        try write("Use Swift.\n", to: local.appendingPathComponent("rules/style.mdc"))
        try write(
            "{\"name\":\"cached-demo\",\"version\":\"2\",\"skills\":\"skills\"}",
            to: cached.appendingPathComponent("plugin.json"))
        try write("# Cached demo\n", to: cached.appendingPathComponent("skills/SKILL.md"))
        try write(
            "{\"name\":\"personal\",\"gitRef\":\"refs/heads/main\","
                + "\"plugins\":[{\"name\":\"remote-demo\",\"source\":\"./plugins/remote-demo\","
                + "\"version\":\"1\"}]}",
            to: marketplace.appendingPathComponent("marketplace.json"))

    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
