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

    /// `small.pdf` for tests that query panes: identifier queries over "any"/"other" elements
    /// walk PDFKit's per-page accessibility elements, which takes many seconds on `large.pdf`.
    private func openSmall(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"] + extra)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Drags the page area upward (scrolls down) without tapping anything.
    private func scrollPage(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[ReaderID.pagePill].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens the go-to-page field through More ▸ Go to Page… (the pill can sit under the
    /// system's "Hidden Windows" chip left by earlier multi-window runs) and types the number.
    /// Go to Page… through its keyboard shortcut (⌥⌘G) and types into the focused field.
    /// (Querying text fields over `large.pdf` walks PDFKit's page elements and is very slow, and
    /// the pill can sit under the system's "Hidden Windows" chip after multi-window runs.)
    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        app.typeKey("g", modifierFlags: [.command, .option])
        sleep(1)
        app.typeText("\(number)\n")
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

    /// The exact user path: tap the pill, type with the software keyboard up, Return. The page
    /// must stay on N afterwards (the keyboard's dismissal must not restore the old page), and
    /// Back returns to page 1. Portrait, so the pill sits above the notes sheet and is tappable.
    func testPillGoToPageOnSmallDocumentStaysAndBackReturns() {
        XCUIDevice.shared.orientation = .portrait
        let app = openSmall()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        pill(app).tap()
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("9\n")
        XCTAssertTrue(waitForLabel(pill(app), "Page 9 of 12"))
        sleep(3)
        XCTAssertEqual(pill(app).label, "Page 9 of 12")
        let back = app.buttons[ReaderID.historyBack].firstMatch
        XCTAssertTrue(waitForEnabled(back))
        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        sleep(2)
        XCTAssertEqual(pill(app).label, "Page 1 of 12")
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
        let app = openSmall()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let contents = element(app, ReaderID.contentsPane)
        let notes = element(app, ReaderID.notesPane)
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

        // A jump from Contents updates the page (and is recorded: Back becomes enabled).
        let chapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "2 Vector Spaces")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        chapter.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 5 of 12"))
        XCTAssertTrue(waitForEnabled(app.buttons[ReaderID.historyBack].firstMatch))
    }

    func testNarrowWidthUsesOverlayAndSheet() {
        XCUIDevice.shared.orientation = .portrait
        let app = openSmall()
        XCTAssertTrue(app.buttons[ReaderID.contentsToggle].waitForExistence(timeout: 30))
        // Notes is a sheet; Contents starts hidden and opens as an overlay.
        let sheet = element(app, ReaderID.notesSheet)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, ReaderID.contentsPane).exists)
        let overlay = element(app, ReaderID.contentsOverlay)
        XCTAssertFalse(overlay.exists)
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        // The page stays usable behind the sheet: the pill moves above it.
        XCTAssertTrue(pill(app).isHittable)
        goToPage(app, 9)
        XCTAssertTrue(waitForLabel(pill(app), "Page 9 of 12"))
        // A wide window turns them back into panes and keeps the page.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element(app, ReaderID.contentsPane).waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, ReaderID.notesPane).exists)
        sleep(1)
        XCTAssertTrue(waitForLabel(pill(app), "Page 9 of 12"))
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

        scrollPage(app)
        scrollPage(app)
        XCTAssertFalse(waitForLabel(pill(app), "Page 1 of 1500", timeout: 2))  // it scrolled
        XCTAssertFalse(back.isEnabled)                                         // but recorded nothing

        // A: "4.1.3 Summary" (pp. 311–317). Scroll a little inside it.
        goToPage(app, 311)
        XCTAssertTrue(waitForLabel(pill(app), "Page 311 of 1500"))
        scrollPage(app)
        scrollPage(app)
        scrollPage(app)
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
        let app = openSmall(["-openPage", "7", "-alsoOpenWindow", "small"])
        // Each reader window has its own page pill; both are in the hierarchy once the second opens.
        let pills = app.buttons.matching(identifier: ReaderID.pagePill)
        let deadline = Date().addingTimeInterval(30)
        while pills.count < 2 && Date() < deadline { usleep(250_000) }
        XCTAssertEqual(pills.count, 2)
        sleep(1)
        // Move the front window only; the other keeps its page.
        let mores = app.buttons.matching(identifier: ReaderID.more)
        let front = (0..<mores.count).map { mores.element(boundBy: $0) }.first { $0.isHittable }
        XCTAssertNotNil(front)
        let before = Set((0..<pills.count).map { pills.element(boundBy: $0).label })
        front?.tap()
        let item = app.buttons["Go to Page…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        sleep(1)
        app.typeText("3\n")
        sleep(2)
        let after = (0..<pills.count).map { pills.element(boundBy: $0).label }
        XCTAssertTrue(after.contains("Page 3 of 12"), "\(after)")
        XCTAssertEqual(after.count, 2)
        // The window not moved still shows a page it had before.
        XCTAssertFalse(Set(after.filter { $0 != "Page 3 of 12" }).isDisjoint(with: before), "\(before) → \(after)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Regression for the main-menu crash ("Replacement elements contain duplicates", a reader
    /// shortcut equal to a system one): drive every state through keyboard shortcuts, which
    /// forces UIKit to rebuild and re-enumerate the main menu each time, and check the app is
    /// still alive afterwards (the crash was delayed and silent to earlier assertions).
    func testMenuCommandsStayStableAcrossStates() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        app.typeKey("a", modifierFlags: [.command, .shift])          // Markup
        XCTAssertTrue(app.buttons[ReaderID.done].waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: [.command, .shift])          // Done with Markup
        XCTAssertTrue(app.buttons[ReaderID.markupToggle].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .option])         // Go to Page… (a text field)
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("7\n")
        XCTAssertTrue(waitForLabel(pill(app), "Page 7 of 12"))
        app.typeKey("s", modifierFlags: [.command, .control])        // Contents
        app.typeKey("0", modifierFlags: [.command, .option])         // Notes
        app.typeKey("[", modifierFlags: .command)                    // Back (section history)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command, .option])  // Next Page
        app.typeKey("l", modifierFlags: [.command, .shift])          // Back to Library
        let book = app.buttons["library.book.small"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)                    // disabled without a reader
        book.tap()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 15))
        app.typeKey("n", modifierFlags: [.command, .option])         // Open in New Window
        sleep(3)
        app.typeKey("s", modifierFlags: [.command, .control])
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground)

        let two = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-openBook", "small", "-alsoOpenWindow", "small"])
        XCTAssertTrue(pill(two).waitForExistence(timeout: 30))
        sleep(3)
        two.typeKey("a", modifierFlags: [.command, .shift])
        two.typeKey("a", modifierFlags: [.command, .shift])
        two.typeKey("l", modifierFlags: [.command, .shift])
        sleep(2)
        XCTAssertEqual(two.state, .runningForeground)
    }

    /// Markup mode shows the window's system tool picker; Done hides it. Also from launch (-markup).
    func testMarkupModeShowsToolPicker() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        app.buttons[ReaderID.markupToggle].tap()
        let done = app.buttons[ReaderID.done]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(done, "tool picker shown"))
        done.tap()
        XCTAssertTrue(app.buttons[ReaderID.markupToggle].waitForExistence(timeout: 5))

        let launched = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                                   + ["-openBook", "small", "-markup"])
        let doneAtLaunch = launched.buttons[ReaderID.done]
        XCTAssertTrue(doneAtLaunch.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForValue(doneAtLaunch, "tool picker shown"))
    }

    private func waitForEnabled(_ element: XCUIElement, _ enabled: Bool = true, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testSelectionMenuHookAddsAction() {
        let app = openSmall(["-selectionMenuProbe"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        // Long-press a word in the body text to select it and show the edit menu.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Probe"].firstMatch.waitForExistence(timeout: 5)
                      || app.menuItems["Probe"].firstMatch.waitForExistence(timeout: 2))
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
    static let more = "reader.toolbar.more"
    static let done = "reader.toolbar.done"
    static let pagePill = "reader.pagePill"
    static let goToPageField = "reader.goToPageField"
    static let contentsPane = "reader.pane.contents"
    static let contentsOverlay = "reader.pane.contentsOverlay"
    static let notesPane = "reader.pane.notes"
    static let notesSheet = "reader.pane.notesSheet"
}
