import XCTest

/// M10: the system accessibility audit (`performAccessibilityAudit`, the same checks as
/// Accessibility Inspector) on each key screen, and smoke tests of F1 and F5 driven
/// only by the keyboard. Run with `xcodebuild test -scheme OpenNexus`.
final class OpenNexusUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// A clean launch: no restored windows, onboarding done unless asked.
    func launch(onboarded: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", "-onboarding.done",
                onboarded ? "YES" : "NO",
            ]
            + extra
        app.launch()
        app.activate()
        return app
    }

    /// Fails with every issue the audit finds (not just the first).
    func audit(_ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
        final class Found: @unchecked Sendable { var list: [String] = [] }
        let found = Found()
        try app.performAccessibilityAudit(for: .all) { @Sendable issue in
            found.list.append(
                "\(issue.auditType): \(issue.compactDescription) · \(issue.element?.debugDescription.prefix(160) ?? "")"
            )
            return true  // collected; reported below
        }
        let issues = found.list
        if !issues.isEmpty {
            XCTFail(
                "\(screen): \(issues.count) accessibility issues\n" + issues.joined(separator: "\n"), file: file,
                line: line)
        }
    }

    func testHomeAudit() throws {
        let app = launch(extra: ["-general.launch", "home"])
        XCTAssertTrue(app.windows["Home"].waitForExistence(timeout: 10))
        try audit(app, "Home")
    }

    func testSettingsAudit() throws {
        let app = launch(extra: ["-general.launch", "home"])
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for pane in [
            "General", "Editing", "Appearance", "Files & Backup", "AI", "Shortcuts", "Export", "Integrations",
            "Privacy & Data",
            "Accessibility",
        ] {
            let button = settings.buttons[pane].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), pane)
            button.click()
            try audit(app, "Settings › \(pane)")
        }
    }

    /// F1: 20 topics from the keyboard alone, then the canvas window's audit.
    func testF1TwentyTopicsKeyboardOnly() throws {
        let app = launch(extra: ["-general.launch", "new", "-editing.startInEdit", "YES"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let canvas = window.groups["canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        app.typeText("Launch plan\r")
        for i in 1...19 {
            app.typeKey(i == 1 ? "\t" : "\r", modifierFlags: [])
            app.typeText("Topic \(i)\r")
        }
        XCTAssertTrue(window.buttons["20 topics"].waitForExistence(timeout: 5), "the status bar counts 20 topics")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(window.buttons["19 topics"].waitForExistence(timeout: 5), "one undo removes one topic")
        try audit(app, "Document window")
    }

    /// F5: Welcome → role picker → the tour, with Return alone.
    func testF5TutorialStartsFromTheKeyboard() throws {
        let app = launch(onboarded: false)
        XCTAssertTrue(app.staticTexts["WELCOME TO OPENNEXUS"].waitForExistence(timeout: 10))
        try audit(app, "Welcome")
        app.typeKey("\r", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["What will you map first?"].waitForExistence(timeout: 5))
        try audit(app, "Role picker")
        app.typeKey("\r", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["1 · Type"].waitForExistence(timeout: 10), "lesson 1 is showing")
    }
}
