import XCTest

/// M47b on the iPad simulator: F1 (a 20-topic, 3-level map) with a hardware keyboard
/// only and again by touch only, the system accessibility audit on Home, the canvas and
/// Settings, and Dynamic Type. M47c on the iPhone: F1 by touch in the Outline, Quick
/// Capture, presenting, a comment, and the audits there, at the largest text size too.
/// Tests for one device skip on the other. Run with `scripts/test-ipad.sh` or
/// `xcodebuild test -project App/OpenNexusiOS.xcodeproj -scheme "OpenNexus iOS"`.
@MainActor
final class OpenNexusiOSUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// The iPhone's layout (compact width); the iPad's is regular.
    var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// A clean library in a temporary folder; `new` opens a blank mind map in Edit mode.
    func launch(new: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"] + (new ? ["-uitest-new"] : []) + extra
        app.launch()
        return app
    }

    /// Fails with every issue the audit finds (not just the first). With `visible` (a
    /// scroll view's area on screen), contrast and clipping are left out for elements in its
    /// column that it shows only part of or keeps just past its edge: the audit measures the
    /// pixels on screen, which there aren't the element's (a phone's row half under the bar
    /// read as clipped). `audit(_:_:scrolling:)` audits the screenful that shows them whole;
    /// a chip a sideways row cuts at the screen's side is left out (the row's others, the same
    /// style, are checked).
    ///
    /// Contrast is its own pass, first, and Dynamic Type its own, last: the text size check
    /// scrolls a pane as its rows grow and shrink, so issues found after it carry the moved
    /// frames, and element detection beside it reads text where no element is any more. The
    /// clipping check sizes the text too, and on a phone's narrow panes its reflow did the
    /// same, so it has its own pass before Dynamic Type's. Each call costs seconds whatever
    /// it checks, so the other checks share one pass; one that
    /// runs out of time is split into a pass per check, and a single check gets four tries.
    /// Each try that runs out of time leaves the simulator's `testmanagerd` busy on another
    /// core, and a check that runs out on a screenful keeps doing so there, so a scrolling
    /// screen's `nudge` moves the screenful a little first; other screens wait longer each
    /// time. (If they still run out, look at `testmanagerd`: it can spin on every core until
    /// the simulator restarts.) A lone glyph's contrast (a key's, a pane's) is measured again
    /// on its stroke (`strokeContrast`).
    func audit(
        _ app: XCUIApplication, _ screen: String, visible: CGRect? = nil, nudge: (() -> Void)? = nil,
        only: XCUIAccessibilityAuditType? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        final class Found {
            var list: [String] = []
            var glyphs: [(CGRect, String)] = []
        }
        // A view that changes during the audit (a notice fading) gets new accessibility nodes,
        // and its issues come back without an element.
        _ = settled()
        var passes: [XCUIAccessibilityAuditType] =
            only.map { [$0] } ?? [
                .contrast, XCUIAccessibilityAuditType.all.subtracting([.contrast, .textClipped, .dynamicType]),
                .textClipped, .dynamicType,
            ]
        var tries: [UInt64: Int] = [:]
        var all: [String] = []
        while !passes.isEmpty {
            let types = passes.removeFirst()
            let found = Found()
            do {
                try app.performAccessibilityAudit(for: types) { issue in
                    // One snapshot per issue, not a query per attribute: each query snapshots the
                    // app, and Shortcuts has 700 elements and a few key glyphs' issues a screenful.
                    let e = try? issue.element?.snapshot()
                    // WCAG 1.4.3 exempts inactive controls from contrast (a locked setting's control).
                    if issue.auditType == .contrast, e?.isEnabled == false { return true }
                    // Shown in part: cut by the bar or the foot in the view's column, or by the
                    // screen's side in a row that scrolls sideways (Home's chips on a phone).
                    if issue.auditType == .contrast || issue.auditType == .textClipped, let visible,
                        let f = e?.frame, !visible.insetBy(dx: -1, dy: -1).contains(f), f.maxX > visible.minX,
                        f.minX < visible.maxX
                    {
                        return true
                    }
                    let text =
                        "\(issue.auditType): \(issue.compactDescription) · \(issue.detailedDescription) · "
                        + (e.map { "type \($0.elementType.rawValue) '\($0.label)' \($0.identifier) \($0.frame)" } ?? "")
                    // A key's glyph, or a Settings pane's on its 22-point tile.
                    if issue.auditType == .contrast, let e, e.frame.width <= 22, Self.isKeyGlyph(e.label) {
                        found.glyphs.append((e.frame, text))
                    } else {
                        found.list.append(text)
                    }
                    return true  // collected; reported below
                }
            } catch let e as NSError
                where e.domain == "com.apple.xcode.xctest.accessibilityAudit" && e.code == -56
            {
                // "Audit failed to complete in time"
                print("\(screen): the \(types.rawValue) audit ran out of time")
                let single = Self.checks.filter { types.contains($0) }
                if single.count > 1 {
                    passes.insert(contentsOf: single, at: 0)
                    continue
                }
                tries[types.rawValue, default: 1] += 1
                if tries[types.rawValue]! <= 4 {
                    // Shortcuts' eighth screenful ran out every time until it moved.
                    if let nudge {
                        nudge()
                        _ = settled()
                    } else {
                        sleep(UInt32(10 * (tries[types.rawValue]! - 1)))
                    }
                    passes.insert(types, at: 0)
                } else {
                    all.append("\(types): didn't finish in time, four times")
                }
                continue
            }
            if !found.glyphs.isEmpty {
                let shot = app.screenshot().image
                let bounds = app.frame
                for (frame, text) in found.glyphs
                where (Self.strokeContrast(shot, frame, screen: bounds) ?? 0) < 4.5 {
                    found.list.append(text)
                }
            }
            all += found.list
        }
        if !all.isEmpty {
            XCTFail(
                "\(screen): \(all.count) accessibility issues\n" + all.joined(separator: "\n"), file: file, line: line)
        }
    }

    /// The checks iOS has (`.all` is every bit).
    static let checks: [XCUIAccessibilityAuditType] = [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped, .trait,
    ]

    /// What the screen shows once it's still (and a scroll indicator has faded). The screen,
    /// not an element: an element's screenshot finds the element first, and on Shortcuts
    /// (700 elements) each find takes about 11 seconds and keeps `testmanagerd` busy.
    func settled() -> Data {
        sleep(1)
        var shot = XCUIScreen.main.screenshot().pngRepresentation
        for _ in 0..<10 {
            usleep(300_000)
            let now = XCUIScreen.main.screenshot().pngRepresentation
            if now == shot { break }
            shot = now
        }
        return shot
    }

    /// A key's glyphs alone: one character (7, ⇥), or up to three with no letters or digits
    /// (⌘-, ⇧↩).
    nonisolated static func isKeyGlyph(_ label: String) -> Bool {
        label.count == 1 && label != " "
            || !label.isEmpty && label.count <= 3
                && label.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) && $0 != " " }
    }

    /// The contrast of the text in `frame` measured on its stroke: the pixel farthest in
    /// luminance from the most common one (the background) against it. A lone key glyph is
    /// a few pixels of antialiased stroke, which the audit's measure takes for its colour,
    /// so it fails such glyphs even bold, black on white; grey text still fails here.
    nonisolated static func strokeContrast(_ shot: UIImage, _ frame: CGRect, screen: CGRect) -> Double? {
        guard let cg = shot.cgImage else { return nil }
        let s = CGFloat(cg.width) / screen.width
        let r = CGRect(x: frame.minX * s, y: frame.minY * s, width: frame.width * s, height: frame.height * s)
            .integral
        guard let crop = cg.cropping(to: r), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (w, h) = (crop.width, crop.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, w * h > 0 else { return nil }
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        var lums: [Double] = []
        var counts: [Int: Int] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let l = 0.2126 * linear(px[i]) + 0.7152 * linear(px[i + 1]) + 0.0722 * linear(px[i + 2])
            lums.append(l)
            counts[Int(l * 1000), default: 0] += 1
        }
        guard let mode = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let background = Double(mode) / 1000
        let ink = lums.max { abs($0 - background) < abs($1 - background) }!
        return (max(background, ink) + 0.05) / (min(background, ink) + 0.05)
    }

    /// Audits a scrolling screen a screenful at a time, from the top: each drag scrolls
    /// two thirds of the view, so every row shorter than a third of it is whole in one of
    /// them. The navigation bar and the fade under it cover the view's top. The audit itself
    /// can scroll the view, so the end is where a drag brings back what the view showed
    /// before that screenful's audit.
    func audit(
        _ app: XCUIApplication, _ screen: String, scrolling scroll: XCUIElement,
        only: XCUIAccessibilityAuditType? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), screen, file: file, line: line)
        let frame = scroll.frame
        var visible = frame
        let top = app.navigationBars.firstMatch.frame.maxY + 24
        if top > visible.minY {
            visible = CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
        }
        // Dragged at the left margin, clear of switches and buttons, by the app's coordinates:
        // the scroll view's own find it again at every step of the drag.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = frame.minX + frame.width * 0.02
        let from = origin.withOffset(CGVector(dx: x, dy: frame.minY + frame.height * 0.85))
        let to = origin.withOffset(CGVector(dx: x, dy: frame.minY + frame.height * 0.2))
        // A tenth of the view, well inside the third each screenful shares with the next.
        func nudge() {
            origin.withOffset(CGVector(dx: x, dy: frame.minY + frame.height * 0.6)).press(
                forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: frame.minY + frame.height * 0.5)))
        }
        var shown = settled()
        for page in 1...24 {  // Shortcuts is the longest: about 16
            try audit(app, "\(screen) (\(page))", visible: visible, nudge: nudge, only: only, file: file, line: line)
            from.press(forDuration: 0.05, thenDragTo: to)
            let next = settled()
            if next == shown { break }
            shown = next
        }
    }

    /// A topic by its text. Its label is the spoken description, which starts with the text
    /// ("Topic 3. Main topic, level 2 of 2. …").
    func topic(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'topic-' AND label BEGINSWITH %@", text + ". ")
        ).firstMatch
    }

    func key(_ app: XCUIApplication, _ k: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(k, modifierFlags: flags)
    }

    /// The hardware Return key. On iOS `XCUIKeyboardKey.return` ("\r") never reaches the
    /// app; "\n" is sent as the Return key's own key press.
    func pressReturn(_ app: XCUIApplication) { app.typeKey("\n", modifierFlags: []) }

    // MARK: F1

    // XCTest runs these in name order, touch first: once a test types on the hardware keyboard,
    // the simulator keeps one attached for the rest of the run, and the on-screen keyboard
    // (and its shortcuts bar as the touch test uses it) no longer shows.

    /// F1 from a hardware keyboard alone: the root, then Tab for the first child, Return
    /// for each sibling, and two ⌘Zs that take back the last name and the last topic.
    func testF1bTwentyTopicsHardwareKeyboard() throws {
        try XCTSkipIf(phone, "the iPad's canvas; the iPhone's map starts in the Outline (testPhoneF1)")
        let app = launch(new: true)
        XCTAssertTrue(app.otherElements["canvas"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["node-editor"].waitForExistence(timeout: 5), "the root opens in Edit mode")
        app.typeText("Launch plan")
        pressReturn(app)
        for i in 1...19 {
            if i == 1 { key(app, XCUIKeyboardKey.tab.rawValue) } else { pressReturn(app) }
            app.typeText("Topic \(i)")
            pressReturn(app)
        }
        XCTAssertTrue(app.buttons["20 topics"].waitForExistence(timeout: 5), "the status bar counts 20 topics")
        XCTAssertTrue(topic(app, "Topic 19").exists)
        // A third level: Tab under Topic 19.
        key(app, XCUIKeyboardKey.tab.rawValue)
        app.typeText("Detail")
        pressReturn(app)
        XCTAssertTrue(app.buttons["21 topics"].waitForExistence(timeout: 5))
        // Naming a topic is its own undo step: ⌘Z reverts the name, then the topic.
        key(app, "z", .command)
        key(app, "z", .command)
        XCTAssertTrue(app.buttons["20 topics"].waitForExistence(timeout: 5), "two undos remove the last topic")
        try audit(app, "Canvas")
        // ⌘K opens the palette and ⌘. (Esc) closes it, from the keyboard. XCUITest's Esc
        // doesn't reach the app in the simulator; the hosted tests send Esc itself (D406).
        key(app, "k", .command)
        let palette = app.descendants(matching: .any)["Command palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K opens the command palette")
        key(app, ".", .command)
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5), "⌘. closes it")
    }

    /// F1 by touch: the on-screen keyboard types, its shortcuts bar adds the child and the
    /// siblings, a double-tap renames a topic and a long-press menu adds a third level.
    func testF1aTwentyTopicsTouchOnly() throws {
        try XCTSkipIf(phone, "the iPad's canvas; the iPhone's map starts in the Outline (testPhoneF1)")
        let app = launch(new: true)
        XCTAssertTrue(app.otherElements["canvas"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["node-editor"].waitForExistence(timeout: 5))
        app.typeText("Launch plan")
        let child = app.buttons["Add child topic"]
        let sibling = app.buttons["Add sibling topic"]
        XCTAssertTrue(child.waitForExistence(timeout: 5), "the keyboard's shortcuts bar adds topics")
        child.tap()
        app.typeText("Topic 1")
        for i in 2...19 {
            sibling.tap()
            app.typeText("Topic \(i)")
        }
        // Tapping the canvas commits the edit.
        app.otherElements["canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["20 topics"].waitForExistence(timeout: 5), "the status bar counts 20 topics")

        // Double-tap edits; the editor holds the topic's text.
        let t3 = topic(app, "Topic 3")
        XCTAssertTrue(t3.waitForExistence(timeout: 5))
        t3.doubleTap()
        let editor = app.textViews["node-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Topic 3")

        // Long-press opens the registry's menu; its Add Child makes the third level.
        app.otherElements["canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        topic(app, "Topic 5").press(forDuration: 1.0)
        let add = app.buttons["Add Child Topic"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the long-press menu lists Add Child Topic")
        add.tap()
        app.typeText("Detail")
        app.otherElements["canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["21 topics"].waitForExistence(timeout: 5))
        XCTAssertTrue(topic(app, "Detail").exists)
    }

    // MARK: Audits

    func testHomeAudit() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["New Mind Map"].waitForExistence(timeout: 15))
        // The iPhone's Home scrolls: a screenful at a time, as a Settings pane.
        if phone {
            try audit(app, "Home", scrolling: app.scrollViews["home.content"])
        } else {
            try audit(app, "Home")
        }
    }

    func testSettingsAudit() throws {
        try auditSettings(launch())
    }

    static let panes = [
        "General", "Editing", "Appearance", "Files & Backup", "AI", "Shortcuts", "Export", "Sharing", "Sync",
        "Integrations", "Privacy & Data", "Accessibility",
    ]

    /// Every pane of Settings. On the iPhone the list pushes each pane, and the test comes
    /// back to the list for the next.
    func auditSettings(
        _ app: XCUIApplication, only: XCUIAccessibilityAuditType? = nil, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(app.buttons["New Mind Map"].waitForExistence(timeout: 15), file: file, line: line)
        // ⌘, is iPadOS's (it opens the app's page in the Settings app, D405): the toolbar's gear.
        app.buttons["settings"].tap()
        XCTAssertTrue(
            app.buttons["General"].firstMatch.waitForExistence(timeout: 10), "the gear opens Settings", file: file,
            line: line)
        if phone { try audit(app, "Settings", only: only, file: file, line: line) }
        for pane in Self.panes {
            let button = app.buttons[pane].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), pane, file: file, line: line)
            button.tap()
            try audit(
                app, "Settings › \(pane)", scrolling: app.scrollViews["settings.content"], only: only, file: file,
                line: line)
            if phone {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.waitForExistence(timeout: 5), "\(pane): back", file: file, line: line)
                back.tap()
            }
        }
    }

    /// The chrome follows Dynamic Type: Home's text at an accessibility size is larger than
    /// at a small one (the audits check every size on each screen).
    func testDynamicTypeScalesTheChrome() throws {
        // The section header's height is its text's; the cards keep a 44-point minimum.
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        let new = app.staticTexts["New"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        let large = new.frame.height
        app.terminate()
        let small = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryS"])
        XCTAssertTrue(small.staticTexts["New"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(large, small.staticTexts["New"].firstMatch.frame.height * 1.5, "Home's text grows")
    }

    // MARK: iPhone (M47c)

    /// The rows of the Outline: each topic, note, link and comments line is a button
    /// labelled with its text.
    func row(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any)["outline"].buttons[text]
    }

    /// A button on the bar above the iPhone's keyboard, tapped where it shows: the keyboard's
    /// window covers the screen above the bar's, so XCUITest finds no hit point on it.
    func bar(_ app: XCUIApplication, _ label: String) {
        let b = app.toolbars.buttons[label].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5), label)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: b.frame.midX, dy: b.frame.midY)).tap()
    }

    /// Done on the bar above the keyboard: commits and puts the keyboard away.
    func done(_ app: XCUIApplication) { bar(app, "Done") }

    /// F1 on the iPhone by touch, in the Outline a mind map opens in: the bar above the
    /// keyboard adds the child and the siblings, a double-tap renames, and the bottom
    /// toolbar adds a third level.
    func testPhoneF1TwentyTopicsInTheOutline() throws {
        try XCTSkipUnless(phone, "the iPhone's Outline; the iPad's canvas is testF1a")
        let app = launch(new: true)
        XCTAssertTrue(app.descendants(matching: .any)["outline"].waitForExistence(timeout: 15), "the Outline first")
        let editor = app.textViews["node-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the central topic opens in Edit mode")
        app.typeText("Launch plan")
        XCTAssertTrue(
            app.toolbars.buttons["Add child topic"].waitForExistence(timeout: 5),
            "the bar above the keyboard adds topics")
        bar(app, "Add child topic")
        app.typeText("Topic 1")
        for i in 2...19 {
            bar(app, "Add sibling topic")
            app.typeText("Topic \(i)")
        }
        done(app)
        XCTAssertTrue(row(app, "Topic 19").waitForExistence(timeout: 5))
        let topics = app.descendants(matching: .any)["outline"].buttons.matching(
            NSPredicate(format: "label MATCHES 'Topic [0-9]+'"))
        XCTAssertEqual(
            topics.count, 19,
            app.descendants(matching: .any)["outline"].buttons.allElementsBoundByIndex.map(\.label).joined(
                separator: " | "))
        XCTAssertTrue(row(app, "Launch plan").exists)

        // Double-tap edits; the editor holds the topic's text.
        row(app, "Topic 3").doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Topic 3")
        done(app)

        // The bottom toolbar's Add Child makes the third level.
        row(app, "Topic 5").tap()
        app.buttons["add-child"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("Detail")
        done(app)
        XCTAssertTrue(row(app, "Detail").waitForExistence(timeout: 5))
        XCTAssertGreaterThan(row(app, "Detail").frame.minX, row(app, "Topic 5").frame.minX, "indented under Topic 5")
    }

    /// The Inbox widget's capture button and the Lock Screen widget open this link: Quick
    /// Capture over Home, the idea saved to the Inbox, then edited in the Inbox's Outline.
    func testPhoneQuickCaptureToTheInbox() throws {
        try XCTSkipUnless(phone, "the iPhone's Outline")
        let app = launch()
        XCTAssertTrue(app.buttons["New Mind Map"].waitForExistence(timeout: 15))
        app.open(URL(string: "opennexus://inbox/add")!)
        let field = app.descendants(matching: .any)["capture-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the link opens Quick Capture")
        let idea = "Call the venue \(Int.random(in: 100...999))"
        app.typeText(idea)
        app.buttons["capture-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["capture-saved"].waitForExistence(timeout: 5), "saved")
        app.buttons["capture-done"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Mind Map"].exists, "Home stays where it was")

        app.open(URL(string: "opennexus://inbox")!)
        let captured = row(app, idea)
        XCTAssertTrue(captured.waitForExistence(timeout: 10), "the idea is in the Inbox map")
        captured.doubleTap()
        XCTAssertTrue(app.textViews["node-editor"].waitForExistence(timeout: 5))
        app.textViews["node-editor"].typeText(" on Monday")
        done(app)
        let edited = app.descendants(matching: .any)["outline"].buttons.matching(
            NSPredicate(format: "label CONTAINS ' on Monday'")
        ).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "edited in the Outline")
    }

    /// Present fills the screen and a swipe or a tap moves through the slides; with a
    /// second display (AirPlay's Screen Mirroring, simulated) the phone shows the presenter
    /// view and its buttons step the deck.
    func testPhonePresentSwipesAndThePresenterView() throws {
        try XCTSkipUnless(phone, "the iPhone's More menu")
        func slide(_ app: XCUIApplication, _ n: Int) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Slide \(n) of "))
                .firstMatch
        }
        func present(_ app: XCUIApplication) {
            XCTAssertTrue(app.buttons["more-menu"].waitForExistence(timeout: 15))
            app.buttons["more-menu"].tap()
            app.buttons["Present"].tap()
        }
        var app = launch(extra: ["-uitest-starter", "meeting"])
        present(app)
        XCTAssertTrue(slide(app, 1).waitForExistence(timeout: 5), "Present fills the screen")
        XCTAssertFalse(app.buttons["more-menu"].isHittable)
        app.swipeLeft()
        XCTAssertTrue(slide(app, 2).waitForExistence(timeout: 5), "a swipe left goes on")
        app.swipeRight()
        XCTAssertTrue(slide(app, 1).waitForExistence(timeout: 5), "a swipe right goes back")
        app.tap()
        XCTAssertTrue(slide(app, 2).waitForExistence(timeout: 5), "a tap goes on")
        app.terminate()

        app = launch(extra: ["-uitest-starter", "meeting", "-uitest-display"])
        present(app)
        let next = app.buttons["Next step"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the presenter view")
        XCTAssertTrue(slide(app, 1).exists)
        try audit(app, "Presenter view")
        next.tap()
        XCTAssertTrue(slide(app, 2).waitForExistence(timeout: 5))
        app.buttons["Previous step"].tap()
        XCTAssertTrue(slide(app, 1).waitForExistence(timeout: 5))
        app.buttons["End"].tap()
        XCTAssertTrue(app.buttons["more-menu"].waitForExistence(timeout: 5), "back to the document")
    }

    /// A comment from the Outline: More › Comments opens the topic's thread as a sheet; the
    /// Outline then shows the comments line, and tapping it opens the thread again.
    func testPhoneCommentFromTheOutline() throws {
        try XCTSkipUnless(phone, "the iPhone's Outline")
        let app = launch(extra: ["-uitest-starter", "meeting"])
        let outline = app.descendants(matching: .any)["outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 15))
        let first = outline.buttons.element(boundBy: 1)
        let name = first.label
        first.tap()
        app.buttons["more-menu"].tap()
        app.buttons["Comments"].tap()
        let field = app.descendants(matching: .any)["New comment"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the thread opens")
        field.tap()
        app.typeText("Check the budget")
        // Add Comment is enabled once the field's text has reached its binding.
        let add = app.buttons["Add Comment"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: add)
        waitForExpectations(timeout: 5)
        add.tap()
        let posted = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", ": Check the budget")
        ).firstMatch
        XCTAssertTrue(posted.waitForExistence(timeout: 5), "the thread lists it")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the thread closes")
        // The row after the topic: its comments line.
        let line = outline.buttons.element(boundBy: 2)
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        XCTAssertTrue(
            line.label.hasPrefix("1 comment · ") && line.label.hasSuffix("Check the budget"),
            "the Outline shows the comment under \(name): \(line.label)")
        line.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Comment thread"].waitForExistence(timeout: 5))
    }

    /// The audit on the iPhone's Outline (a mind map) and canvas (a flowchart, which opens
    /// there), in portrait and landscape.
    func testPhoneOutlineAndCanvasAudit() throws {
        try XCTSkipUnless(phone, "the iPhone's layout")
        var app = launch(extra: ["-uitest-starter", "meeting"])
        XCTAssertTrue(app.descendants(matching: .any)["outline"].waitForExistence(timeout: 15))
        try audit(app, "Outline")
        app.terminate()

        app = launch(extra: ["-uitest-starter", "apiFlow"])
        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "a flowchart opens in the canvas")
        try audit(app, "Canvas")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        _ = settled()
        for id in ["close-document", "view-mode", "add-child", "add-sibling", "inspector", "more-menu"] {
            let e = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(e.isHittable && app.frame.contains(e.frame), "\(id) in landscape: \(e.frame)")
        }
        // The title, the canvases' menu.
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "API request flow"))
            .firstMatch
        XCTAssertTrue(title.isHittable, "the title menu in landscape: \(title.frame)")
        try audit(app, "Canvas, landscape")
        app.buttons["Outline"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["outline"].waitForExistence(timeout: 5))
        try audit(app, "Outline, landscape")
    }

    /// The largest accessibility text size clips nothing on Home, the Outline, the canvas
    /// and every pane of Settings.
    func testPhoneLargestTextClipsNothing() throws {
        try XCTSkipUnless(phone, "the iPhone's layout")
        let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        var app = launch(extra: largest + ["-uitest-starter", "meeting"])
        XCTAssertTrue(app.descendants(matching: .any)["outline"].waitForExistence(timeout: 15))
        try audit(app, "Outline, largest text", only: .textClipped)
        app.buttons["Canvas"].tap()
        XCTAssertTrue(app.otherElements["canvas"].waitForExistence(timeout: 5))
        try audit(app, "Canvas, largest text", only: .textClipped)
        app.terminate()

        app = launch(extra: largest)
        XCTAssertTrue(app.buttons["New Mind Map"].waitForExistence(timeout: 15))
        try audit(app, "Home, largest text", scrolling: app.scrollViews["home.content"], only: .textClipped)
        try auditSettings(app, only: .textClipped)
    }
}
