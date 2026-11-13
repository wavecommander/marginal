import XCTest

/// Reader shell (WP4): first page, go to page, relaunch restore, subtitle, panes, narrow
/// layout, two windows, the selection-menu hook.
@MainActor
final class ReaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func openLarge(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large) + ["-openBook", "large"] + extra)
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[ReaderID.pagePill].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        pill(app).tap()
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("\(number)\n")
    }

    /// The navigation bar shows `text` (the subtitle on iOS 26+, the title block before).
    private func navigationBarShows(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let match = app.navigationBars.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    // MARK: Tests

    func testLargeFirstPageAppearsQuickly() {
        let started = Date()
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 1500"))
        // Generous bound: launch + fixture import (5 MB copy) + open + first page.
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        XCTAssertTrue(app.otherElements[ReaderID.pdfView].exists || app.scrollViews[ReaderID.pdfView].exists
                      || app.descendants(matching: .any)[ReaderID.pdfView].exists)
    }

    func testGoToPageThenRelaunchLandsOnSamePage() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        goToPage(app, 1200)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1200 of 1500"))
        // Let the debounced last-read save run (1 s), then background to flush anyway.
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.terminate()

        let again = XCUIApplication()
        again.launchArguments = ["-openBook", "large"]
        again.launch()
        XCTAssertTrue(pill(again).waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(pill(again), "Page 1200 of 1500"))
    }

    func testSubtitleShowsSectionAfterJump() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(navigationBarShows(app, "1 Linear Systems"))
        // Page 1150 is where "12.4 Structure" starts (before its first subsection).
        goToPage(app, 1150)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1150 of 1500"))
        XCTAssertTrue(navigationBarShows(app, "12.4 Structure"))
        goToPage(app, 1152)
        XCTAssertTrue(navigationBarShows(app, "12.4.1 Definitions"))
    }

    func testContentsAndNotesTogglesInWideLayout() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let contents = app.descendants(matching: .any)[ReaderID.contentsPane]
        let notes = app.descendants(matching: .any)[ReaderID.notesPane]
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        XCTAssertTrue(notes.exists)

        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(contents.waitForNonExistence(timeout: 5))
        app.buttons[ReaderID.notesToggle].tap()
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        app.buttons[ReaderID.notesToggle].tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))

        // A jump from Contents updates the page.
        let chapter = contents.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "2 Vector Spaces")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        chapter.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 101 of 1500"))
    }

    func testNarrowWidthUsesOverlayAndSheet() {
        XCUIDevice.shared.orientation = .portrait
        let app = openLarge()
        XCTAssertTrue(app.buttons[ReaderID.contentsToggle].waitForExistence(timeout: 30))
        // Notes is a sheet; Contents starts hidden and opens as an overlay.
        XCTAssertTrue(app.descendants(matching: .any)[ReaderID.notesSheet].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)[ReaderID.contentsPane].exists)
        let overlay = app.descendants(matching: .any)[ReaderID.contentsOverlay]
        XCTAssertFalse(overlay.exists)
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        // Rotating to landscape (a wide window) turns them back into panes and keeps the page.
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        app.descendants(matching: .any)[ReaderID.notesSheet].swipeDown()
        goToPage(app, 321)
        XCTAssertTrue(waitForLabel(pill(app), "Page 321 of 1500"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)[ReaderID.contentsPane].waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertTrue(waitForLabel(pill(app), "Page 321 of 1500"))
    }

    /// Section history: scrolling never records; Back/Forward return to the exact page left in
    /// each section; a new jump drops the forward entries.
    func testSectionHistoryBackForward() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let back = app.buttons[ReaderID.historyBack].firstMatch
        let forward = app.buttons[ReaderID.historyForward].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        let pdf = app.descendants(matching: .any)[ReaderID.pdfView].firstMatch
        pdf.swipeUp(velocity: .slow)
        pdf.swipeUp(velocity: .slow)
        XCTAssertFalse(waitForLabel(pill(app), "Page 1 of 1500", timeout: 2))  // it scrolled
        XCTAssertFalse(back.isEnabled)                                         // but recorded nothing

        // A: "4.1.3 Summary" (pp. 311–317). Scroll a little inside it.
        goToPage(app, 311)
        XCTAssertTrue(waitForLabel(pill(app), "Page 311 of 1500"))
        pdf.swipeUp(velocity: .slow)
        sleep(1)
        let leftInA = currentPage(app)
        XCTAssertTrue((312...317).contains(leftInA), "scrolled to \(leftInA)")
        // B: "10.1.1 Definitions"; C: "13.4 Structure".
        goToPage(app, 905)
        XCTAssertTrue(waitForLabel(pill(app), "Page 905 of 1500"))
        goToPage(app, 1250)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1250 of 1500"))
        XCTAssertTrue(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 905 of 1500"))
        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page \(leftInA) of 1500"))  // the page left, not 311
        XCTAssertTrue(forward.isEnabled)
        forward.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 905 of 1500"))
        XCTAssertTrue(forward.isEnabled)

        goToPage(app, 50)
        XCTAssertTrue(waitForLabel(pill(app), "Page 50 of 1500"))
        XCTAssertFalse(forward.isEnabled)
        XCTAssertTrue(back.isEnabled)
    }

    private func currentPage(_ app: XCUIApplication) -> Int {
        // "Page N of 1500"
        let parts = pill(app).label.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? -1 : -1
    }

    func testAlsoOpenWindowShowsSecondReaderWithIndependentPage() {
        let app = openLarge(["-openPage", "700", "-alsoOpenWindow", "large"])
        // Each reader window has its own page pill; both are on screen once the second opens.
        let pills = app.buttons.matching(identifier: ReaderID.pagePill)
        let deadline = Date().addingTimeInterval(30)
        while pills.count < 2 && Date() < deadline { usleep(250_000) }
        XCTAssertEqual(pills.count, 2, app.debugDescription)
        let labels = Set((0..<pills.count).map { pills.element(boundBy: $0).label })
        XCTAssertEqual(labels, ["Page 700 of 1500", "Page 1 of 1500"])
    }

    func testSelectionMenuHookAddsAction() {
        let app = openLarge(["-selectionMenuProbe"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let pdf = app.descendants(matching: .any)[ReaderID.pdfView].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        // Long-press a word in the body text to select it and show the edit menu.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.32)).press(forDuration: 1.2)
        XCTAssertTrue(app.descendants(matching: .any)["Probe"].firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
    }
}

/// Mirrors `AccessibilityID.Reader` in the app (the test target cannot import it).
enum ReaderID {
    static let pdfView = "reader.pdfView"
    static let contentsToggle = "reader.toolbar.contents"
    static let historyBack = "reader.toolbar.historyBack"
    static let historyForward = "reader.toolbar.historyForward"
    static let notesToggle = "reader.toolbar.notes"
    static let markupToggle = "reader.toolbar.markup"
    static let done = "reader.toolbar.done"
    static let pagePill = "reader.pagePill"
    static let goToPageField = "reader.goToPageField"
    static let contentsPane = "reader.pane.contents"
    static let contentsOverlay = "reader.pane.contentsOverlay"
    static let notesPane = "reader.pane.notes"
    static let notesSheet = "reader.pane.notesSheet"
}
