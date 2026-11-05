import XCTest

/// The Library's move between the installer ledgers: each skill a single
/// ledger owns offers one move, and the queued change names the ledger it
/// moves to. Both installers are "available" through the bundled probes.
@MainActor
final class MigrationUITests: XCTestCase {
    func testMoveNamesTheDestinationLedger() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sukiru-migration-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Vercel-owned: a global lock entry whose source is a GitHub repo.
        try write(
            """
            {
              "version": 3,
              "skills": {
                "vercel-tool": {
                  "source": "owner/repo",
                  "sourceType": "github",
                  "sourceUrl": "https://github.com/owner/repo.git",
                  "skillPath": "tools/vercel-tool/SKILL.md",
                  "skillFolderHash": "9999999999999999999999999999999999999999",
                  "installedAt": "2026-06-15T23:27:24.742Z",
                  "updatedAt": "2026-06-15T23:27:24.742Z"
                }
              },
              "dismissed": {}
            }
            """,
            to: root.appendingPathComponent(".agents/.skill-lock.json"))
        try write(
            "---\nname: vercel-tool\ndescription: The vercel-tool skill.\n---\nBody.\n",
            to: root.appendingPathComponent(".agents/skills/vercel-tool/SKILL.md"))
        // GitHub-owned: frontmatter provenance only.
        try write(
            """
            ---
            name: gh-tool
            description: The gh-tool skill.
            metadata:
              github-repo: https://github.com/owner/repo
              github-path: tools/gh-tool
              github-ref: refs/heads/main
              github-tree-sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            ---
            Body.
            """,
            to: root.appendingPathComponent(".claude/skills/gh-tool/SKILL.md"))

        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = root.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/installers/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }

        let vercelRow = app.staticTexts["vercel-tool"].firstMatch
        XCTAssertTrue(vercelRow.waitForExistence(timeout: 15))
        vercelRow.click()
        let moveToGitHub = app.buttons["sukiru.library.detail.migrate"].firstMatch
        XCTAssertTrue(moveToGitHub.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library detail: move to the other installer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        moveToGitHub.click()
        XCTAssertTrue(
            label("Move to gh skill", in: app).waitForExistence(timeout: 5),
            "the queued change names the destination ledger")
        XCTAssertFalse(
            app.buttons["sukiru.library.detail.migrate"].exists,
            "the button becomes the queued change")

        let githubRow = app.staticTexts["gh-tool"].firstMatch
        XCTAssertTrue(githubRow.waitForExistence(timeout: 5))
        githubRow.click()
        let moveToVercel = app.buttons["sukiru.library.detail.migrate"].firstMatch
        XCTAssertTrue(moveToVercel.waitForExistence(timeout: 10))
        moveToVercel.click()
        XCTAssertTrue(
            label("Move to npx skills", in: app).waitForExistence(timeout: 5),
            "the reverse move names the Vercel ledger's installer")
    }

    /// Writes a file, creating its folders.
    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Any element carrying the visible text, whatever its accessibility role.
    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", text))
            .firstMatch
    }
}
