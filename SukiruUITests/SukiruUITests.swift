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
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    func testCursorPluginInventoryAndMarketplacePreviewStayHostOwned() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] = fixture.appendingPathComponent("bin").path
        app.launch()

        let cursor = app.descendants(matching: .any)["sukiru.sidebar.plugins.cursor"].firstMatch
        XCTAssertTrue(cursor.waitForExistence(timeout: 15))
        cursor.click()

        XCTAssertTrue(app.staticTexts["local-demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["cached-demo"].waitForExistence(timeout: 10))

        app.staticTexts["cached-demo"].click()
        XCTAssertTrue(
            app.staticTexts["Cached payload; installation unknown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unknown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not Checked"].waitForExistence(timeout: 5))

        app.buttons["sukiru.plugins.add"].click()
        let marketplaces = app.menuItems["Marketplaces…"].firstMatch
        XCTAssertTrue(marketplaces.waitForExistence(timeout: 5))
        marketplaces.click()
        XCTAssertTrue(
            app.staticTexts["Git ref: refs/heads/main"].waitForExistence(timeout: 5))
        app.buttons["sukiru.plugins.catalog.done"].click()

        app.buttons["sukiru.plugins.add"].click()
        app.menuItems["Install Plugin…"].firstMatch.click()
        app.buttons["sukiru.plugins.operation.action"].click()
        app.menuItems["Add Marketplace"].click()
        app.textFields["sukiru.plugins.operation.target"].click()
        app.textFields["sukiru.plugins.operation.target"].typeText("https://example.com/new.git")
        app.textFields["sukiru.plugins.operation.git-ref"].click()
        app.textFields["sukiru.plugins.operation.git-ref"].typeText("feature/marketplace")
        app.buttons["sukiru.plugins.operation.preview"].click()

        XCTAssertTrue(app.staticTexts["Review Changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Git ref feature/marketplace"].waitForExistence(timeout: 5))
        app.buttons["sukiru.confirm.cancel"].click()
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
            "{\"name\":\"local-demo\",\"version\":\"1\",\"skills\":\"skills\"}",
            to: local.appendingPathComponent("plugin.json"))
        try write("# Local demo\n", to: local.appendingPathComponent("skills/SKILL.md"))
        try write(
            "{\"name\":\"cached-demo\",\"version\":\"2\",\"skills\":\"skills\"}",
            to: cached.appendingPathComponent("plugin.json"))
        try write("# Cached demo\n", to: cached.appendingPathComponent("skills/SKILL.md"))
        try write(
            "{\"name\":\"personal\",\"gitRef\":\"refs/heads/main\","
                + "\"plugins\":[{\"name\":\"remote-demo\",\"source\":\"./plugins/remote-demo\","
                + "\"version\":\"1\"}]}",
            to: marketplace.appendingPathComponent("marketplace.json"))

        let bin = fixture.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = """
            #!/bin/sh
            case "$*" in
              "--version") echo "agent 2026.10.16-e3cb207" ;;
              *"plugin marketplace"*"--help") echo "Usage: agent plugin marketplace --format json --git-ref <ref>" ;;
              *"plugin marketplace list --format json") echo '[]' ;;
              *) echo "Usage: agent plugin marketplace" ;;
            esac
            """
        let agent = bin.appendingPathComponent("agent")
        try write(shim, to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: agent.path)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
