import XCTest

@MainActor
final class LibraryLayoutUITests: XCTestCase {
    func testLongDescriptionDoesNotOverlapOwnershipRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-description-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/long-description/SKILL.md")
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        let description = (1...14).map { index in
            "  Line \(index) explains a long multi-line skill description with enough content to wrap in the inspector."
        }.joined(separator: "\n")
        try "---\nname: long-description\ndescription: |\n\(description)\n---\nBody.\n"
            .write(to: skill, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = root.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] = "/usr/bin:/bin"
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let row = app.staticTexts["long-description"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        let descriptionView = app.staticTexts["sukiru.library.detail.description"]
        XCTAssertTrue(descriptionView.waitForExistence(timeout: 10))
        let owner = app.staticTexts["Owner"].firstMatch
        let scope = app.staticTexts["Scope"].firstMatch
        XCTAssertTrue(owner.exists)
        XCTAssertTrue(scope.exists)
        XCTAssertLessThanOrEqual(descriptionView.frame.maxY, owner.frame.minY)
        XCTAssertLessThan(owner.frame.maxY, scope.frame.minY)
        XCTAssertLessThan(descriptionView.frame.height, 100)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Long description is bounded above Owner and Scope"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
