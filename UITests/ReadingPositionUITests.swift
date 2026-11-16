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
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    /// Opens the book with both panels shown (`-notesPanel page`: every test here starts from
    /// the notes panel open, whatever a reader's first open shows).
    private func launch(_ fixture: String, _ title: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(fixture)
                                              + ["-openBook", title, "-exposeViewportAnchor", "-notesPanel", "page"] + extra)
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
        var last: Anchor?
        _ = UIWait.until(timeout: 6, poll: 0.5) {
            let next = readAnchor(app)
            defer { last = next }
            return next != nil && next == last
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

    private func toggle(_ app: XCUIApplication, _ identifier: String) {
        app.buttons[identifier].firstMatch.tap()
    }

    /// Presses ⌘`key` until the viewport's scale has changed from `scale` (the first hardware-key
    /// event after a launch can arrive before the window is key), then returns the settled anchor.
    private func zoom(_ app: XCUIApplication, key: String, from scale: Double,
                      file: StaticString = #filePath, line: UInt = #line) -> Anchor {
        var changed = false
        for _ in 0..<3 where !changed {
            app.typeKey(key, modifierFlags: .command)
            changed = UIWait.until(timeout: 3) { (readAnchor(app)?.scale ?? scale) != scale }
        }
        XCTAssertTrue(changed, "⌘\(key) did not change the zoom", file: file, line: line)
        return settledAnchor(app, file: file, line: line)
    }

    /// Closes and reopens each panel once, checking the position after every step; then, `rounds`
    /// times each, closes and reopens Contents, then Notes, then both alternating (through
    /// "both closed"), checking after each group. The position must return exactly to the start.
    /// One exercise with several rounds is enough to show there is no drift; the other positions
    /// and zoom modes need only the single steps (`rounds: 0`) or one round.
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
        for _ in 0..<rounds { toggle(app, contents); toggle(app, contents) }
        assertSamePosition(start, settledAnchor(app), "\(label) contents x\(rounds)")
        for _ in 0..<rounds { toggle(app, notes); toggle(app, notes) }
        assertSamePosition(start, settledAnchor(app), "\(label) notes x\(rounds)")
        for _ in 0..<rounds {
            // No pauses: every tap already waits for the app to go idle before and after.
            toggle(app, contents); toggle(app, notes)
            toggle(app, contents); toggle(app, notes)
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

    /// One launch, three positions on the small book: the top of a page, across a page boundary,
    /// and mid-page. (Scrolling between them records no history, which each exercise asserts.)
    func testPanelTogglesKeepPositionOnSmall() {
        let app = launch(Fixtures.small, "small", ["-openPage", "5"])
        exerciseWidePanels(app, rounds: 0, label: "small page top")
        // Scroll back a little so the top edge shows the end of page 4 and the gap.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)))
        exerciseWidePanels(app, rounds: 0, label: "small boundary")
        scrollPage(app, by: 0.35)
        exerciseWidePanels(app, rounds: 3, label: "small mid-page")
    }

    func testPanelTogglesKeepPositionDeepInLarge() {
        let app = launch(Fixtures.large, "large", ["-openPage", "700"])
        scrollPage(app, by: 0.25)
        exerciseWidePanels(app, rounds: 1, label: "large p700")
    }

    func testPanelTogglesKeepPositionWhenZoomed() {
        let app = launch(Fixtures.small, "small")
        let fit = settledAnchor(app)
        let once = zoom(app, key: "+", from: fit.scale)
        let twice = zoom(app, key: "+", from: once.scale)
        XCTAssertGreaterThan(twice.scale, fit.scale, "zoomed in")
        scrollPage(app, by: 0.3)
        exerciseWidePanels(app, rounds: 1, label: "small zoomed")
    }

    /// TSOFT-223: a double tap on the page (PDFKit's own zoom toggle) can return the view to fit
    /// width; opening and closing the notes panel afterwards must keep the place, not jump to
    /// the top of the book.
    func testPanelTogglesKeepPositionAfterDoubleTapZoom() {
        let app = launch(Fixtures.small, "small", ["-openPage", "5"])
        scrollPage(app, by: 0.3)
        let page = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5))
        let notes = "reader.toolbar.notes"
        for round in 1...2 {
            let scale = settledAnchor(app).scale
            page.doubleTap()
            // PDFKit's zoom animation: it has started once the scale moves, and `settledAnchor`
            // waits for its end.
            _ = UIWait.until(timeout: 2) { (readAnchor(app)?.scale ?? scale) != scale }
            let zoomed = settledAnchor(app)
            print("READING-ANCHOR double tap \(round): \(zoomed)")
            toggle(app, notes)
            assertSamePosition(zoomed, settledAnchor(app), "double tap \(round) notes toggled")
            toggle(app, notes)
            assertSamePosition(zoomed, settledAnchor(app), "double tap \(round) notes toggled back")
        }
    }

    /// TSOFT-223: in fit width (Fit Width, ⌘9) PDFKit refits the scale for every width the
    /// panels leave; the place holds through all of it.
    func testPanelTogglesKeepPositionInFitWidth() {
        let app = launch(Fixtures.small, "small", ["-openPage", "5"])
        // Fit Width from the More menu: ⌘9 may change nothing visible at this size, so a key
        // press lost while the window is becoming key could not be told from one that worked.
        app.buttons["reader.toolbar.more"].firstMatch.tap()
        let fitWidth = app.buttons["Fit Width"].firstMatch
        XCTAssertTrue(fitWidth.waitForExistence(timeout: 5), "More ▸ Fit Width")
        fitWidth.tap()
        XCTAssertTrue(fitWidth.waitForGone(), "the More menu closed")
        scrollPage(app, by: 0.3)
        exerciseWidePanels(app, rounds: 1, label: "small fit width")
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
        divider.waitForStableFrame()  // the release's snap (shut, if it were going to close)
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
        XCTAssertTrue(divider.waitForGone(timeout: 5), "the pane did not close")
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
        // Markup mode: the Markup toggle reads "Done with Markup" (there is no Done button; the
        // toggle's selected trait and value do not reach XCUITest from the iOS 27 toolbar).
        let markup = app.buttons["reader.toolbar.markup"].firstMatch
        XCTAssertTrue(markup.waitForExistence(timeout: 10))
        XCTAssertEqual(markup.label, "Done with Markup", "not in markup mode")
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
        divider.waitForStableFrame()
        assertNoInk("resized")
        handle().press(forDuration: 0.3,
                       thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)),
                       withVelocity: 600, thenHoldForDuration: 0.1)
        XCTAssertTrue(divider.waitForGone(timeout: 5), "the pane did not close in markup mode")
        assertSamePosition(start, settledAnchor(app), "markup: slid shut")
        app.buttons["reader.toolbar.notes"].firstMatch.tap()
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        divider.waitForStableFrame()
        assertNoInk("closed and reopened")
        XCTAssertEqual(markup.label, "Done with Markup", "markup mode ended")
    }

    func testNarrowPanelsKeepPosition() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(Fixtures.small, "small")
        _ = settledAnchor(app)  // the rotation to portrait has finished
        let pill = app.buttons["reader.pagePill"].firstMatch
        let pageBefore = pill.label
        scrollPage(app, by: 0.15)
        let start = settledAnchor(app)
        // Two rounds: the second starts from a sheet and an overlay that have each been shown
        // and hidden once, which is where a drift would first show.
        for round in 0..<2 {
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
