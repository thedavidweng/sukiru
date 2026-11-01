import XCTest

@MainActor
final class MarketplaceLayoutUITests: XCTestCase {
    func testCodexLongSourceDoesNotOverlapListing() throws {
        try checkPopulatedMarketplace(host: "codex")
    }

    func testDroidLongSourceDoesNotOverlapListing() throws {
        try checkPopulatedMarketplace(host: "droid")
    }

    func testCodexUnverifiedCatalogKeepsManagementAvailable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "[marketplaces.team]\nsource_type = \"git\"\nsource = \"https://example.com/team.git\"\n",
            to: root.appendingPathComponent(".codex/config.toml"))
        let app = launch(root: root, host: "codex")
        defer { app.terminate() }
        let message = app.staticTexts["Refresh Marketplace to verify the cached source."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let actions = checkMetadata(app, host: "codex", firstRow: message)
        actions.click()
        XCTAssertTrue(actions.menuItems["Refresh Marketplace"].exists)
        XCTAssertTrue(actions.menuItems["Remove Marketplace"].exists)
    }

    func testDroidEmptyCatalogKeepsActionsVisible() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"example/team"}}}}"#,
            to: root.appendingPathComponent(".factory/settings.json"))
        let app = launch(root: root, host: "droid")
        defer { app.terminate() }
        let empty = app.staticTexts["Not fetched by Droid yet"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        let actions = checkMetadata(app, host: "droid", firstRow: empty)
        actions.click()
        XCTAssertTrue(actions.menuItems["Refresh Marketplace"].exists)
        XCTAssertTrue(actions.menuItems["Remove Marketplace"].exists)
    }

    private func checkPopulatedMarketplace(host: String) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent(
            "a-very-long-marketplace-source-path-to-exercise-truncation/catalog")
        if host == "codex" {
            try write(
                "[marketplaces.team]\nsource_type = \"local\"\nsource = \"\(catalog.path)\"\n",
                to: root.appendingPathComponent(".codex/config.toml"))
            try write(
                #"{"name":"team","plugins":[{"name":"demo","source":{"source":"local","path":"./demo"}}]}"#,
                to: catalog.appendingPathComponent(".agents/plugins/marketplace.json"))
        } else {
            try write(
                "{\"extraKnownMarketplaces\":{\"team\":{\"source\":{\"source\":\"local\","
                    + "\"path\":\"\(catalog.path)\"}}}}",
                to: root.appendingPathComponent(".factory/settings.json"))
            try write(
                #"{"name":"team","plugins":[{"name":"demo","source":"./demo"}]}"#,
                to: catalog.appendingPathComponent(".factory-plugin/marketplace.json"))
        }
        let app = launch(root: root, host: host)
        defer { app.terminate() }
        let row = app.descendants(matching: .any)["sukiru.plugins.marketplace.row.demo"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let actions = checkMetadata(app, host: host, firstRow: row)
        actions.click()
        XCTAssertTrue(actions.menuItems["Refresh Marketplace"].exists)
    }

    private func launch(root: URL, host: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = root.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let destination = app.descendants(matching: .any)["sukiru.sidebar.plugins.\(host)"]
            .firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        app.outlines["Sidebar"].scroll(byDeltaX: 0, deltaY: -500)
        destination.click()
        let marketplace = app.radioButtons["Marketplace"]
        XCTAssertTrue(marketplace.waitForExistence(timeout: 10))
        marketplace.click()
        return app
    }

    private func checkMetadata(
        _ app: XCUIApplication, host: String, firstRow: XCUIElement
    ) -> XCUIElement {
        let source = app.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "sukiru.plugins.marketplace.source.\(host):")
        ).firstMatch
        let actions = app.menuButtons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "sukiru.plugins.marketplace.actions.\(host):")
        ).firstMatch
        let scope = app.descendants(matching: .any)["sukiru.plugins.marketplace.list"].firstMatch
            .staticTexts["User Library"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Marketplace metadata - \(host)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(scope.exists)
        XCTAssertTrue(actions.isHittable)
        XCTAssertLessThanOrEqual(source.frame.maxX, actions.frame.minX)
        XCTAssertLessThanOrEqual(source.frame.maxY, firstRow.frame.minY)
        XCTAssertLessThanOrEqual(scope.frame.maxY, firstRow.frame.minY)
        XCTAssertLessThanOrEqual(actions.frame.maxY, firstRow.frame.minY)
        return actions
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-marketplace-layout-\(UUID().uuidString)")
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
