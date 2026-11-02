import XCTest

/// The window toolbar is split into sections that track the split view's
/// columns. When one column's items need more room than the column has, the
/// toolbar section grows past the column instead, and its divider no longer
/// lines up with the one below. Each surface is checked at its narrowest.
@MainActor
final class ToolbarAlignmentUITests: XCTestCase {
    func testContentToolbarStaysOverNarrowestColumn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-toolbar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog")
        try write(
            "{\"extraKnownMarketplaces\":{\"team\":{\"source\":{\"source\":\"local\","
                + "\"path\":\"\(catalog.path)\"}}}}",
            to: root.appendingPathComponent(".factory/settings.json"))
        try write(
            #"{"name":"team","plugins":[{"name":"demo","source":"./demo"}]}"#,
            to: catalog.appendingPathComponent(".factory-plugin/marketplace.json"))
        try write(
            "---\nname: demo-skill\ndescription: demo\n---\n",
            to: root.appendingPathComponent(".agents/skills/demo-skill/SKILL.md"))

        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = root.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }

        let allSkills = app.staticTexts["All Skills"].firstMatch
        XCTAssertTrue(allSkills.waitForExistence(timeout: 15))
        narrowContentColumn(app)

        allSkills.click()
        check(app, "Library", items: ["line.3.horizontal.decrease.circle"])

        app.outlines.firstMatch.staticTexts["Health"].click()
        check(app, "Health", items: ["sukiru.health.fixAll"])

        let plugins = app.descendants(matching: .any)["sukiru.sidebar.plugins.droid"].firstMatch
        XCTAssertTrue(plugins.waitForExistence(timeout: 10))
        plugins.click()
        check(app, "Plugins", items: ["sukiru.plugins.add"])

        app.radioButtons["Marketplace"].firstMatch.click()
        check(app, "Marketplace", items: ["sukiru.plugins.add"])
    }

    /// Drags the content/detail divider toward the sidebar, so the content
    /// column sits at its minimum width.
    private func narrowContentColumn(_ app: XCUIApplication) {
        let divider = contentDivider(app)
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: -600, dy: 0)))
    }

    private func contentDivider(_ app: XCUIApplication) -> XCUIElement {
        let splitters = app.windows.firstMatch.splitters.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(splitters.count, 2)
        return splitters.max { $0.frame.minX < $1.frame.minX }!
    }

    private func check(_ app: XCUIApplication, _ surface: String, items: [String]) {
        let window = app.windows.firstMatch
        // In the toolbar, `axButtonToken` surfaces as the value (with an
        // optional ".disabled" suffix); a menu without an identifier takes its
        // symbol name.
        func item(_ token: String) -> XCUIElement {
            window.toolbars.firstMatch.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@ OR value BEGINSWITH %@", token, token)
            ).firstMatch
        }
        let refresh = item("sukiru.toolbar.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), surface)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = surface
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let edge = contentDivider(app).frame.minX
        for token in ["sukiru.toolbar.refresh"] + items {
            let element = item(token)
            XCTAssertTrue(element.exists, "\(surface): \(token)")
            XCTAssertLessThanOrEqual(element.frame.maxX, edge, "\(surface): \(token)")
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
