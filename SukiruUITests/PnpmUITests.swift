import XCTest

@MainActor
final class PnpmUITests: XCTestCase {
    func testPendingPermissionRefreshBecomesReadOnlyPackageInstallation() throws {
        let tree = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-pnpm-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        let home = tree.appendingPathComponent("home", isDirectory: true)
        let project = tree.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let selector = "@sukiru/ui-fixture@file:../fixture.tgz"
        let metadata = project.appendingPathComponent("node_modules/.modules.yaml")
        let prefix =
            "\"packageManager\":\"pnpm@12.11.0\",\"layoutVersion\":5,"
            + "\"nodeLinker\":\"isolated\",\"virtualStoreDir\":\".pnpm\""
        try write("{\(prefix),\"pendingSkills\":[\"\(selector)\"]}", to: metadata)
        try write(
            "{\"dependencies\":{\"@sukiru/ui-fixture\":\"file:../fixture.tgz\"}}",
            to: project.appendingPathComponent("package.json"))

        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = project.path
        app.launchEnvironment["PATH"] = "/usr/bin:/bin"
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let health = app.descendants(matching: .any)["sukiru.sidebar.health"].firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        let permissionRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sukiru.health.pnpm.")
        ).firstMatch
        XCTAssertTrue(permissionRow.waitForExistence(timeout: 10))
        wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Awaiting Approval"),
                    object: permissionRow)
            ],
            timeout: 10)
        XCTAssertFalse(app.staticTexts["Ownerless"].exists)
        attach(app, name: "pnpm pending permission, no installed Skill")
        try approveFixture(project: project, selector: selector, prefix: prefix, metadata: metadata)

        app.typeKey("r", modifierFlags: .command)
        wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Approved"), object: permissionRow
                )
            ],
            timeout: 10)
        app.typeKey("1", modifierFlags: .command)
        let row = app.staticTexts["ui-guide"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.staticTexts["Managed by pnpm"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pnpm-@sukiru+ui-fixture-guide"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Use Copies"].exists)
        XCTAssertFalse(app.buttons["Use Links"].exists)
        attach(app, name: "pnpm verified read-only Library details")
    }

    private func approveFixture(
        project: URL, selector: String, prefix: String, metadata: URL
    ) throws {
        let package = project.appendingPathComponent(
            "node_modules/.pnpm/@sukiru+ui-fixture@file+..+fixture.tgz/node_modules/@sukiru/ui-fixture"
        )
        try write(
            "{\"name\":\"@sukiru/ui-fixture\",\"version\":\"1.0.0\"}",
            to: package.appendingPathComponent("package.json"))
        try write(
            "---\nname: ui-guide\ndescription: Native read-only dependency\n---\nBody.\n",
            to: package.appendingPathComponent("skills/guide/SKILL.md"))
        let dependency = project.appendingPathComponent("node_modules/@sukiru/ui-fixture")
        try link(dependency, to: package.path)
        let relative = ".claude/skills/pnpm-@sukiru+ui-fixture-guide"
        try link(
            project.appendingPathComponent(relative),
            to: package.appendingPathComponent("skills/guide").path)
        try write("{\(prefix),\"linkedSkills\":[\"\(relative)\"]}", to: metadata)
        try write(
            "permissions:\n  '\(selector)':\n    skills: true\n",
            to: project.appendingPathComponent("pnpm-workspace.yaml"))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func link(_ url: URL, to destination: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: url.path, withDestinationPath: destination)
    }
}
