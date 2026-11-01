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

        app.radioButtons["Marketplace"].click()
        XCTAssertTrue(
            app.staticTexts["Git ref: refs/heads/main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["cached-demo"].exists)
        XCTAssertFalse(app.staticTexts["Same name installed"].exists)
        app.staticTexts["remote-demo"].click()
        XCTAssertTrue(app.staticTexts["A cached listing"].firstMatch.waitForExistence(timeout: 5))
        let filter = app.searchFields.firstMatch
        filter.click()
        filter.typeText("no-such-listing")
        filter.typeKey(.return, modifierFlags: [])
        let remoteRow = app.descendants(matching: .any)[
            "sukiru.plugins.marketplace.row.remote-demo"]
        XCTAssertTrue(remoteRow.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["A cached listing"].exists)
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["remote-demo"].waitForExistence(timeout: 5))
        app.staticTexts["remote-demo"].click()
        XCTAssertTrue(app.buttons["sukiru.plugins.marketplace.install"].exists)
        app.buttons["sukiru.plugins.marketplace.install"].click()
        let instructions = app.staticTexts["sukiru.plugins.cursor.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        XCTAssertTrue((instructions.value as? String ?? "").contains("remote-demo@personal"))
        XCTAssertFalse(app.buttons["sukiru.plugins.operation.preview"].exists)
        app.buttons["sukiru.plugins.operation.cancel"].click()

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

    func testCursorMarketplaceInstructionsUseSelectedProject() throws {
        let project = fixture.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = project.path
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let cursor = app.descendants(matching: .any)["sukiru.sidebar.plugins.cursor"].firstMatch
        XCTAssertTrue(cursor.waitForExistence(timeout: 15))
        cursor.click()
        app.radioButtons["Marketplace"].click()
        XCTAssertTrue(app.staticTexts["remote-demo"].waitForExistence(timeout: 10))
        app.staticTexts["remote-demo"].click()
        app.buttons["sukiru.plugins.marketplace.install"].click()
        app.popUpButtons["sukiru.plugins.operation.scope"].click()
        app.menuItems.matching(NSPredicate(format: "title == %@", project.path)).firstMatch.click()
        XCTAssertTrue(
            (app.staticTexts["sukiru.plugins.cursor.instructions"].value as? String ?? "")
                .contains(project.path))
        app.terminate()
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

    func testDroidUnfetchedMarketplaceActionsStayInItsBrowser() throws {
        try write(
            #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"example/team","ref":"main"}}}}"#,
            to: home.appendingPathComponent(".factory/settings.json"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["SUKIRU_UI_PROBE_LOG"] =
            fixture.appendingPathComponent("probes.log").path
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()

        let droid = app.descendants(matching: .any)["sukiru.sidebar.plugins.droid"].firstMatch
        XCTAssertTrue(droid.waitForExistence(timeout: 15))
        app.outlines["Sidebar"].scroll(byDeltaX: 0, deltaY: -500)
        droid.click()
        app.radioButtons["Marketplace"].click()
        XCTAssertTrue(app.staticTexts["Not fetched by Droid yet"].waitForExistence(timeout: 10))
        app.menuButtons["sukiru.plugins.add"].click()
        XCTAssertFalse(app.menuItems["Marketplaces…"].exists)
        app.typeKey(.escape, modifierFlags: [])
        let id = "sukiru.plugins.marketplace.actions.droid:\(home.path):team"
        let actions = app.menuButtons.matching(
            NSPredicate(format: "identifier == %@", id)
        ).firstMatch
        XCTAssertTrue(actions.exists)
        actions.click()
        actions.menuItems["Refresh Marketplace"].click()
        app.buttons["sukiru.plugins.operation.preview"].click()
        XCTAssertTrue(
            app.staticTexts["sukiru.plugins.operation.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Review Changes"].exists)
        app.buttons["sukiru.plugins.operation.cancel"].click()
        actions.click()
        actions.menuItems["Remove Marketplace"].click()
        XCTAssertEqual(app.textFields["sukiru.plugins.operation.target"].value as? String, "team")
        app.buttons["sukiru.plugins.operation.preview"].click()
        XCTAssertTrue(app.staticTexts["Review Changes"].waitForExistence(timeout: 10))
        app.buttons["sukiru.confirm.cancel"].click()
        app.terminate()
    }

    func testMarketplaceSelectionClearsWhenChangingHosts() throws {
        try write(
            #"{"extraKnownMarketplaces":{"team":{"source":{"source":"github","repo":"example/team"}}}}"#,
            to: home.appendingPathComponent(".factory/settings.json"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let cursor = app.descendants(matching: .any)["sukiru.sidebar.plugins.cursor"].firstMatch
        XCTAssertTrue(cursor.waitForExistence(timeout: 15))
        cursor.click()
        app.radioButtons["Marketplace"].click()
        XCTAssertTrue(app.staticTexts["remote-demo"].waitForExistence(timeout: 10))
        app.staticTexts["remote-demo"].click()
        XCTAssertTrue(app.staticTexts["A cached listing"].firstMatch.exists)
        app.outlines["Sidebar"].scroll(byDeltaX: 0, deltaY: -500)
        app.descendants(matching: .any)["sukiru.sidebar.plugins.droid"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Not fetched by Droid yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["A cached listing"].exists)
        XCTAssertFalse(app.buttons["sukiru.plugins.marketplace.install"].isEnabled)
        app.terminate()
    }

    func testDroidOrganizationMarketplaceCannotBeRemoved() throws {
        try write(
            #"{"managedSettings":{"extraKnownMarketplaces":{"corp":{"source":{"source":"github","repo":"example/corp"}}}}}"#,
            to: home.appendingPathComponent(".factory/org-managed-settings.cache.json"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let droid = app.descendants(matching: .any)["sukiru.sidebar.plugins.droid"].firstMatch
        XCTAssertTrue(droid.waitForExistence(timeout: 15))
        app.outlines["Sidebar"].scroll(byDeltaX: 0, deltaY: -500)
        droid.click()
        app.radioButtons["Marketplace"].click()
        XCTAssertTrue(
            app.staticTexts["Organization settings manage this marketplace."].waitForExistence(
                timeout: 10))
        let id = "sukiru.plugins.marketplace.actions.droid:\(home.path):corp:org"
        let actions = app.menuButtons.matching(
            NSPredicate(format: "identifier == %@", id)
        ).firstMatch
        actions.click()
        XCTAssertTrue(actions.menuItems["Refresh Marketplace"].exists)
        XCTAssertFalse(actions.menuItems["Remove Marketplace"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    func testFilteredCatalogKeepsInspectionIssuesAccessible() throws {
        try write(
            "{invalid",
            to: home.appendingPathComponent(
                ".cursor/plugins/marketplaces/broken/.cursor-plugin/marketplace.json"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let cursor = app.descendants(matching: .any)["sukiru.sidebar.plugins.cursor"].firstMatch
        XCTAssertTrue(cursor.waitForExistence(timeout: 15))
        cursor.click()
        app.radioButtons["Marketplace"].click()
        XCTAssertTrue(app.staticTexts["remote-demo"].waitForExistence(timeout: 10))
        app.searchFields.firstMatch.click()
        app.searchFields.firstMatch.typeText("no-such-listing")
        app.searchFields.firstMatch.typeKey(.return, modifierFlags: [])
        let row = app.descendants(matching: .any)["sukiru.plugins.marketplace.row.remote-demo"]
        XCTAssertTrue(row.firstMatch.waitForNonExistence(timeout: 5))
        let issues = app.descendants(matching: .any)["sukiru.plugins.inspectionIssues"].firstMatch
        XCTAssertTrue(issues.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testClaudeMarketplaceListingPreview() throws {
        let catalog = home.appendingPathComponent(".claude/plugins/marketplaces/team")
        try write(
            "{\"team\":{\"source\":{\"source\":\"github\",\"repo\":\"example/team\"},"
                + "\"installLocation\":\"\(catalog.path)\"}}",
            to: home.appendingPathComponent(".claude/plugins/known_marketplaces.json"))
        try write(
            "{\"name\":\"team\",\"plugins\":[{\"name\":\"demo\",\"source\":\"./demo\","
                + "\"description\":\"Fixture description\",\"author\":{\"name\":\"Example\"}}]}",
            to: catalog.appendingPathComponent(".claude-plugin/marketplace.json"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        let probes = fixture.appendingPathComponent("probes.log")
        app.launchEnvironment["SUKIRU_UI_PROBE_LOG"] = probes.path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let claude = app.descendants(matching: .any)["sukiru.sidebar.plugins.claude"].firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 15))
        claude.click()
        app.radioButtons["Marketplace"].firstMatch.click()
        let row = app.descendants(matching: .any)["sukiru.plugins.marketplace.row.demo"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Cached catalog; registration scope unknown"].exists)
        let actions = app.menuButtons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "sukiru.plugins.marketplace.actions.claude:")
        ).firstMatch
        actions.click()
        XCTAssertTrue(actions.menuItems["Refresh Marketplace"].exists)
        XCTAssertFalse(actions.menuItems["Remove Marketplace"].exists)
        app.typeKey(.escape, modifierFlags: [])
        row.click()
        XCTAssertTrue(app.staticTexts["Fixture description"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Example"].firstMatch.exists)
        app.buttons["sukiru.plugins.marketplace.install"].click()
        XCTAssertEqual(
            app.textFields["sukiru.plugins.operation.target"].value as? String, "demo@team")
        app.buttons["sukiru.plugins.operation.preview"].click()
        XCTAssertTrue(app.staticTexts["Review Changes"].waitForExistence(timeout: 10))
        app.buttons["sukiru.confirm.cancel"].click()
        app.terminate()
        let recorded = try String(contentsOf: probes, encoding: .utf8)
        XCTAssertFalse(recorded.contains("plugin install demo@team"))
    }

    func testCodexMarketplaceListingAndPreview() throws {
        try write(
            "[marketplaces.team]\nsource_type = \"local\"\nsource = \"\(fixture.path)/catalog\"\n"
                + "[plugins.\"sample@team\"]\nenabled = true\n",
            to: home.appendingPathComponent(".codex/config.toml"))
        try write(
            #"{"name":"team","plugins":[{"name":"sample","source":{"source":"local","path":"./sample"},"description":"Searchable description 12345"}]}"#,
            to: fixture.appendingPathComponent("catalog/.agents/plugins/marketplace.json"))
        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures/bin").path
        app.launchEnvironment["SUKIRU_UI_PROBE_LOG"] =
            fixture.appendingPathComponent("probes.log").path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let codex = app.descendants(matching: .any)["sukiru.sidebar.plugins.codex"].firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 15))
        codex.click()
        app.radioButtons["Marketplace"].click()
        let row = app.descendants(matching: .any)["sukiru.plugins.marketplace.row.sample"]
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Configured reference"].exists)
        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("12345")
        XCTAssertEqual(search.value as? String, "12345")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.staticTexts["Searchable description 12345"].firstMatch.exists)
        app.buttons["sukiru.plugins.marketplace.install"].click()
        XCTAssertEqual(
            app.textFields["sukiru.plugins.operation.target"].value as? String, "sample@team")
        app.buttons["sukiru.plugins.operation.preview"].click()
        XCTAssertTrue(app.staticTexts["Review Changes"].waitForExistence(timeout: 10))
        app.buttons["sukiru.confirm.cancel"].click()
        app.terminate()
        let probes =
            (try? String(contentsOf: fixture.appendingPathComponent("probes.log"), encoding: .utf8))
            ?? ""
        XCTAssertFalse(probes.contains("plugin add sample@team"))
    }

    func testFiveMarketplaceBrowsersInEnglish() throws {
        try exerciseMarketplaces(language: "en", marketplaceTitle: "Marketplace")
    }

    func testFiveMarketplaceBrowsersInSimplifiedChinese() throws {
        try exerciseMarketplaces(language: "zh-Hans", marketplaceTitle: "市场")
    }

    private func exerciseMarketplaces(language: String, marketplaceTitle: String) throws {
        let claudeCatalog = home.appendingPathComponent(".claude/plugins/marketplaces/team")
        try write(
            "{\"team\":{\"source\":{\"source\":\"github\",\"repo\":\"example/team\"},"
                + "\"installLocation\":\"\(claudeCatalog.path)\"}}",
            to: home.appendingPathComponent(".claude/plugins/known_marketplaces.json"))
        try write(
            #"{"name":"team","plugins":[{"name":"claude-only","source":"./claude-only"}]}"#,
            to: claudeCatalog.appendingPathComponent(".claude-plugin/marketplace.json"))
        try write(
            "[marketplaces.team]\nsource_type = \"local\"\nsource = \"\(fixture.path)/codex-catalog\"\n",
            to: home.appendingPathComponent(".codex/config.toml"))
        try write(
            #"{"name":"team","plugins":[{"name":"codex-only","source":{"source":"local","path":"./codex-only"}}]}"#,
            to: fixture.appendingPathComponent("codex-catalog/.agents/plugins/marketplace.json"))
        let droidCatalog = fixture.appendingPathComponent("droid-catalog")
        try write(
            "{\"extraKnownMarketplaces\":{\"team\":{\"source\":{\"source\":\"local\","
                + "\"path\":\"\(droidCatalog.path)\"}}}}",
            to: home.appendingPathComponent(".factory/settings.json"))
        try write(
            #"{"name":"team","plugins":[{"name":"droid-only","source":"./droid-only"}]}"#,
            to: droidCatalog.appendingPathComponent(".factory-plugin/marketplace.json"))
        try write(
            #"{"name":"official","plugins":[{"name":"antigravity-only","source":"./antigravity-only"}]}"#,
            to: home.appendingPathComponent(
                ".gemini/antigravity-cli/cache/marketplaces/official/marketplace.json"))
        let launcher = home.appendingPathComponent(".local/bin/agy")
        try write("", to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let app = XCUIApplication()
        app.launchEnvironment["SUKIRU_HOME"] = home.path
        app.launchEnvironment["SUKIRU_ROOTS"] = ""
        app.launchEnvironment["PATH"] =
            Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/bin").path
        app.launchArguments = ["-AppleLanguages", "(\(language))"]
        app.launch()

        let hosts = [
            ("claude", "claude-only"), ("codex", "codex-only"), ("cursor", "remote-demo"),
            ("droid", "droid-only"), ("antigravity", "antigravity-only")
        ]
        let sidebar = app.outlines.firstMatch
        for (host, listing) in hosts {
            let destination = app.descendants(matching: .any)["sukiru.sidebar.plugins.\(host)"]
                .firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 15), host)
            sidebar.scroll(byDeltaX: 0, deltaY: -1000)
            destination.click()
            let marketplace = app.radioButtons[marketplaceTitle].firstMatch
            XCTAssertTrue(marketplace.waitForExistence(timeout: 10), host)
            XCTAssertFalse(marketplace.label.isEmpty, host)
            marketplace.click()
            let row = app.descendants(matching: .any)["sukiru.plugins.marketplace.row.\(listing)"]
                .firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), host)
            for (_, other) in hosts where other != listing {
                XCTAssertFalse(
                    app.descendants(matching: .any)["sukiru.plugins.marketplace.row.\(other)"]
                        .exists,
                    "\(other) appeared in \(host)")
            }
            row.click()
            let install = app.buttons["sukiru.plugins.marketplace.install"]
            XCTAssertTrue(install.waitForExistence(timeout: 5), host)
            XCTAssertFalse(install.label.isEmpty, host)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(host)-\(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.typeKey("i", modifierFlags: [.command, .control])
            XCTAssertTrue(
                app.buttons["sukiru.plugins.operation.cancel"].waitForExistence(timeout: 5), host)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(
                app.buttons["sukiru.plugins.operation.cancel"].waitForNonExistence(timeout: 5), host
            )
        }

        let window = app.windows.firstMatch
        let original = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
        let smaller = corner.withOffset(CGVector(dx: -200, dy: -150))
        corner.click(forDuration: 0.2, thenDragTo: smaller)
        XCTAssertLessThan(window.frame.width, original.width)
        XCTAssertTrue(app.buttons["sukiru.plugins.marketplace.install"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "resized-\(language)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
                + "\"version\":\"1\",\"description\":\"A cached listing\"},"
                + "{\"name\":\"cached-demo\",\"source\":\"./cached-demo\"}]}",
            to: marketplace.appendingPathComponent("marketplace.json"))

    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
