import XCTest

/// Design rule "The reading position is stable": panels, the divider, rotation and the keyboard
/// never move the page point at the top of the view. Uses the `-exposeViewportAnchor` hook
/// (`reader.viewportAnchor`, value "page N x X y Y scale S", page space).
@MainActor
final class ReadingPositionUITests: XCTestCase {
    struct Anchor: Equatable, CustomStringConvertible {
        var page: Int
        var x: Double
        var y: Double
        var scale: Double
        var description: String { String(format: "p%d x%.2f y%.2f s%.4f", page, x, y, scale) }
    }

    override func setUp() {
        // Keep going after a failed comparison so every offset is measured and logged.
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func launch(_ fixture: String, _ title: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(fixture)
                                              + ["-openBook", title, "-exposeViewportAnchor"] + extra)
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["reader.viewportAnchor"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func readAnchor(_ app: XCUIApplication) -> Anchor? {
        guard let value = app.buttons["reader.viewportAnchor"].firstMatch.value as? String else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 8, let page = Int(parts[1]), let x = Double(parts[3]), let y = Double(parts[5]),
              let scale = Double(parts[7]) else { return nil }
        return Anchor(page: page, x: x, y: y, scale: scale)
    }

    /// The anchor once it has stopped changing (animations finished).
    private func settledAnchor(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Anchor {
        var last = readAnchor(app)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            usleep(500_000)
            let next = readAnchor(app)
            if next == last, next != nil { break }
            last = next
        }
        guard let last else {
            XCTFail("no viewport anchor", file: file, line: line)
            return Anchor(page: 0, x: 0, y: 0, scale: 0)
        }
        return last
    }

    /// Same page point at the top edge of the view (≤ 1 pt in page space). Logs the offset.
    private func assertSamePosition(_ a: Anchor, _ b: Anchor, _ context: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let dy = b.y - a.y, dx = b.x - a.x
        print("READING-ANCHOR \(context): \(a) -> \(b) dy=\(String(format: "%.3f", dy)) dx=\(String(format: "%.3f", dx))")
        XCTAssertEqual(a.page, b.page, "\(context): page \(a) -> \(b)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(dy), 1, "\(context): \(a) -> \(b)", file: file, line: line)
        // x is logged, not asserted: when the page is narrower than the view PDFKit centres it,
        // so the top-left corner's page x legitimately follows the width.
    }

    private func scrollPage(_ app: XCUIApplication, by fraction: Double = 0.3) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        if #available(iOS 26.0, *) {
            app.typeKey("g", modifierFlags: [.command, .option])
        } else {
            app.buttons["reader.pagePill"].firstMatch.tap()
        }
        sleep(1)
        app.typeText("\(number)\n")
        sleep(2)
    }

    private func toggle(_ app: XCUIApplication, _ identifier: String) {
        app.buttons[identifier].firstMatch.tap()
    }

    /// Toggles each panel open/closed `rounds` times, alternating at the end; the position must
    /// hold after every step and return exactly to the start.
    private func exerciseWidePanels(_ app: XCUIApplication, rounds: Int, label: String) {
        let start = settledAnchor(app)
        let pill = app.buttons["reader.pagePill"].firstMatch
        let pageLabel = pill.label
        defer {
            XCTAssertEqual(pill.label, pageLabel, "\(label): the current page never changes")
            XCTAssertFalse(app.buttons["reader.toolbar.historyBack"].firstMatch.isEnabled, "\(label): no history entry")
        }
        let contents = "reader.toolbar.contents", notes = "reader.toolbar.notes"
        toggle(app, contents)
        assertSamePosition(start, settledAnchor(app), "\(label) contents closed")
        toggle(app, contents)
        assertSamePosition(start, settledAnchor(app), "\(label) contents reopened")
        toggle(app, notes)
        assertSamePosition(start, settledAnchor(app), "\(label) notes closed")
        toggle(app, notes)
        assertSamePosition(start, settledAnchor(app), "\(label) notes reopened")
        for _ in 0..<rounds { toggle(app, contents); usleep(400_000); toggle(app, contents); usleep(400_000) }
        assertSamePosition(start, settledAnchor(app), "\(label) contents x\(rounds)")
        for _ in 0..<rounds { toggle(app, notes); usleep(400_000); toggle(app, notes); usleep(400_000) }
        assertSamePosition(start, settledAnchor(app), "\(label) notes x\(rounds)")
        for _ in 0..<rounds {
            toggle(app, contents); usleep(300_000); toggle(app, notes); usleep(300_000)
            toggle(app, contents); usleep(300_000); toggle(app, notes); usleep(300_000)
        }
        let end = settledAnchor(app)
        assertSamePosition(start, end, "\(label) alternating x\(rounds)")
        XCTAssertEqual(start.scale, end.scale, accuracy: 0.0001, "\(label): scale after round trips")

        // The divider: widen the notes panel, then narrow it back to its start.
        let divider = app.descendants(matching: .any)["reader.notesDivider"].firstMatch
        if divider.exists {
            let from = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -200, dy: 0)))
            assertSamePosition(start, settledAnchor(app), "\(label) divider widened")
            let back = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            // Back to the narrowest width (no further: sliding past it closes the pane).
            back.press(forDuration: 0.1, thenDragTo: back.withOffset(CGVector(dx: 200, dy: 0)))
            assertSamePosition(start, settledAnchor(app), "\(label) divider back")
        }
    }

    // MARK: Tests

    func testPanelTogglesKeepPositionMidPageSmall() {
        let app = launch(Fixtures.small, "small")
        scrollPage(app, by: 0.35)
        exerciseWidePanels(app, rounds: 10, label: "small mid-page")
    }

    func testPanelTogglesKeepPositionAtPageTopSmall() {
        let app = launch(Fixtures.small, "small", ["-openPage", "5"])
        exerciseWidePanels(app, rounds: 3, label: "small page top")
    }

    func testPanelTogglesKeepPositionAcrossPageBoundarySmall() {
        let app = launch(Fixtures.small, "small", ["-openPage", "5"])
        // Scroll back a little so the top edge shows the end of page 4 and the gap.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)))
        exerciseWidePanels(app, rounds: 3, label: "small boundary")
    }

    func testPanelTogglesKeepPositionDeepInLarge() {
        let app = launch(Fixtures.large, "large", ["-openPage", "700"])
        scrollPage(app, by: 0.25)
        exerciseWidePanels(app, rounds: 10, label: "large p700")
    }

    func testPanelTogglesKeepPositionWhenZoomed() {
        let app = launch(Fixtures.small, "small")
        sleep(1)
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        sleep(1)
        scrollPage(app, by: 0.3)
        exerciseWidePanels(app, rounds: 3, label: "small zoomed")
    }

    func testRotationAndKeyboardKeepPosition() {
        let app = launch(Fixtures.small, "small")
        scrollPage(app, by: 0.35)
        let start = settledAnchor(app)
        XCUIDevice.shared.orientation = .portrait
        let portrait = settledAnchor(app)
        assertSamePosition(start, portrait, "rotate to portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertSamePosition(start, settledAnchor(app), "rotate back")
        // Keyboard: open the go-to-page field, then dismiss it without jumping.
        app.buttons["reader.pagePill"].firstMatch.tap()
        XCTAssertTrue(app.textFields["reader.goToPageField"].waitForExistence(timeout: 5))
        assertSamePosition(start, settledAnchor(app), "keyboard shown")
        app.buttons["Cancel"].firstMatch.tap()
        assertSamePosition(start, settledAnchor(app), "keyboard hidden")
        XCTAssertFalse(app.buttons["reader.toolbar.historyBack"].firstMatch.isEnabled, "no history entry")
    }

    /// Design rule "No scroll-to-top": taps on the title, the navigation bar and the status bar
    /// never move the reader (and record no history).
    func testTitleAndStatusBarTapsDoNotScrollToTop() {
        let app = launch(Fixtures.large, "large", ["-openPage", "700"])
        scrollPage(app, by: 0.2)
        let start = settledAnchor(app)
        XCTAssertGreaterThan(start.page, 600)
        let pillBefore = app.buttons["reader.pagePill"].firstMatch.label
        let bar = app.navigationBars.firstMatch
        // The title (center of the bar), a blank part of the bar, and the status bar.
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertSamePosition(start, settledAnchor(app), "title tap")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)).tap()
        assertSamePosition(start, settledAnchor(app), "navigation bar tap")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
        assertSamePosition(start, settledAnchor(app), "status bar tap")
        // With both panels closed the PDF is the only scroll view left in the window (before
        // iPadOS 26 the system scrolls to top only when exactly one scroll view opts in).
        app.buttons["reader.toolbar.contents"].firstMatch.tap()
        app.buttons["reader.toolbar.notes"].firstMatch.tap()
        let alone = settledAnchor(app)
        assertSamePosition(start, alone, "panels closed")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertSamePosition(start, settledAnchor(app), "title tap, PDF alone")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
        assertSamePosition(start, settledAnchor(app), "status bar tap, PDF alone")
        XCTAssertFalse(app.buttons["reader.toolbar.historyBack"].firstMatch.isEnabled, "no history entry")
        XCTAssertEqual(app.buttons["reader.pagePill"].firstMatch.label, pillBefore)
    }

    /// Design "Writing room": sliding the notes handle to the pane's own edge closes the pane
    /// (a slow slide that stops just past the narrowest width only resizes); the reading position
    /// holds through every drag and the snap; the toolbar button reopens the pane at the width it
    /// had before the closing slide began. Also checks the handle's 44 pt hit area.
    func testSlidingTheNotesHandleShutClosesThePane() {
        let app = launch(Fixtures.small, "small")
        scrollPage(app, by: 0.3)
        let start = settledAnchor(app)
        let divider = app.descendants(matching: .any)["reader.notesDivider"].firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        func width() -> Int { Int((divider.value as? String ?? "").split(separator: " ").first ?? "") ?? -1 }
        func handle(dx: CGFloat = 0) -> XCUICoordinate {
            divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: dx, dy: 0))
        }
        let narrowest = width()
        XCTAssertEqual(narrowest, 330)

        // The hit area: a drag starting 16 pt left of the 12 pt strip, on the pill's level, widens.
        handle(dx: -16).press(forDuration: 0.3, thenDragTo: handle(dx: -136), withVelocity: 300,
                              thenHoldForDuration: 0.3)
        let widened = width()
        XCTAssertGreaterThan(widened, narrowest + 80, "a drag next to the strip did not move the handle")
        assertSamePosition(start, settledAnchor(app), "handle widened")

        // A slow slide that stops just past the narrowest width resizes, it does not close.
        handle().press(forDuration: 0.3, thenDragTo: handle(dx: CGFloat(widened - narrowest) + 16), withVelocity: 60,
                       thenHoldForDuration: 0.5)
        sleep(1)
        XCTAssertTrue(divider.exists, "a slow slide near the narrowest width closed the pane")
        XCTAssertEqual(width(), narrowest)
        assertSamePosition(start, settledAnchor(app), "slow slide to the narrowest width")

        // Widen again, then slide the handle all the way to the window's edge.
        handle().press(forDuration: 0.3, thenDragTo: handle(dx: -100), withVelocity: 300, thenHoldForDuration: 0.3)
        let before = width()
        XCTAssertGreaterThan(before, narrowest + 50)
        let edge = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5))
        let from = handle()
        from.press(forDuration: 0.3, thenDragTo: edge, withVelocity: 600, thenHoldForDuration: 0.1)
        let notesToggle = app.buttons["reader.toolbar.notes"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while divider.exists && Date() < deadline { usleep(250_000) }
        XCTAssertFalse(divider.exists, "the pane did not close")
        assertSamePosition(start, settledAnchor(app), "slid shut")

        // The toolbar button brings it back at the width from before the closing slide.
        notesToggle.tap()
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        XCTAssertEqual(width(), before, "reopened at another width")
        assertSamePosition(start, settledAnchor(app), "reopened")
        XCTAssertFalse(app.buttons["reader.toolbar.historyBack"].firstMatch.isEnabled, "no history entry")
    }

    /// In markup mode the handle resizes and slides the pane shut without inking the page or the note.
    func testSlidingTheNotesHandleInMarkupModeDrawsNothing() {
        let app = launch(Fixtures.small, "small", ["-markup"])
        XCTAssertTrue(app.buttons["reader.toolbar.done"].waitForExistence(timeout: 10))
        let start = settledAnchor(app)
        let divider = app.descendants(matching: .any)["reader.notesDivider"].firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        func handle(dx: CGFloat = 0) -> XCUICoordinate {
            divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: dx, dy: 0))
        }
        func assertNoInk(_ context: String) {
            let pageInk = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pageInk.ink.")).count
            XCTAssertEqual(pageInk, 0, "\(context): a stroke on the page")
            XCTAssertFalse(app.images["notePage.ink"].exists, "\(context): a stroke in the note")
        }
        handle(dx: -16).press(forDuration: 0.3, thenDragTo: handle(dx: -136), withVelocity: 300, thenHoldForDuration: 0.3)
        handle(dx: 16).press(forDuration: 0.3, thenDragTo: handle(dx: 76), withVelocity: 300, thenHoldForDuration: 0.3)
        sleep(1)
        assertNoInk("resized")
        handle().press(forDuration: 0.3,
                       thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)),
                       withVelocity: 600, thenHoldForDuration: 0.1)
        let deadline = Date().addingTimeInterval(5)
        while divider.exists && Date() < deadline { usleep(250_000) }
        XCTAssertFalse(divider.exists, "the pane did not close in markup mode")
        assertSamePosition(start, settledAnchor(app), "markup: slid shut")
        app.buttons["reader.toolbar.notes"].firstMatch.tap()
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        sleep(1)
        assertNoInk("closed and reopened")
        XCTAssertTrue(app.buttons["reader.toolbar.done"].exists, "markup mode ended")
    }

    func testNarrowPanelsKeepPosition() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(Fixtures.small, "small")
        sleep(1)
        let pill = app.buttons["reader.pagePill"].firstMatch
        let pageBefore = pill.label
        scrollPage(app, by: 0.15)
        let start = settledAnchor(app)
        for round in 0..<5 {
            app.buttons["reader.toolbar.notes"].firstMatch.tap()
            assertSamePosition(start, settledAnchor(app), "narrow notes hidden \(round)")
            app.buttons["reader.toolbar.notes"].firstMatch.tap()
            assertSamePosition(start, settledAnchor(app), "narrow notes shown \(round)")
            app.buttons["reader.toolbar.contents"].firstMatch.tap()
            assertSamePosition(start, settledAnchor(app), "narrow contents overlay \(round)")
            app.buttons["reader.toolbar.contents"].firstMatch.tap()
            assertSamePosition(start, settledAnchor(app), "narrow contents closed \(round)")
        }
        _ = pageBefore
        XCTAssertFalse(app.buttons["reader.toolbar.historyBack"].firstMatch.isEnabled, "no history entry")
    }
}
