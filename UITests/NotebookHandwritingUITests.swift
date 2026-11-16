import XCTest

/// Ink navigation: a page drawn on in a reader appears in the Notebook as a handwriting
/// row, live, in another window; undoing the ink removes the row and redoing brings it back;
/// tapping the row opens the reader at that page. Also the Handwriting type filter, VoiceOver
/// labels, and screenshots (`build/shots/notebook-handwriting-*.png`, light and dark).
///
/// Fingers draw through `-inkAnyInput`. Markup state is read from the Markup toggle's label
/// ("Done with Markup"), not its accessibility value (toolbar values do not reach XCUITest on
/// iOS 27).
@MainActor
final class NotebookHandwritingUITests: XCTestCase {
    // Mirrors `NotebookAccessibilityID`, `PageInkAccessibilityID` and `AccessibilityID.Reader`.
    private enum ID {
        static let typeFilter = "notebook.typeFilter"
        static let pdfView = "reader.pdfView"
        static let markupToggle = "reader.toolbar.markup"
        static let pagePill = "reader.pagePill"
        static func handwriting(_ page: Int) -> String { "notebook.handwriting.\(page)" }
        static func header(_ title: String) -> String { "notebook.header.\(title)" }
        static func pageNote(_ page: Int) -> String { "notebook.pageNote.\(page)" }
        static func highlight(_ page: Int, _ index: Int) -> String { "notebook.highlight.\(page).\(index)" }
        static func scope(_ title: String) -> String { "notebook.scope.\(title)" }
        static func ink(_ page: Int) -> String { "pageInk.ink.\(page)" }
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    private func wait(_ element: XCUIElement, _ format: String, _ arguments: [Any] = [], timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCount(_ query: XCUIElementQuery, atLeast count: Int, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while query.count < count {
            if Date() > deadline { return false }
            usleep(250_000)
        }
        return true
    }

    private func saveShot(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The seeded Notebook of `no-outline.pdf`, with page ink on pp. 2, 18 and 25.
    private func launchSeeded(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
                                              + ["-screen", "notebook", "-seedNotebook", "-seedNotebookPageInk"] + extra)
        XCTAssertTrue(row(app, ID.header("3 Matrices and Linear Maps")).waitForExistence(timeout: 30), "seeded feed")
        return app
    }

    // MARK: Draw, find in the Notebook, jump, erase

    /// Window 1 shows the Notebook of `small.pdf` (empty), window 2 a reader on page 3. A stroke
    /// drawn in the reader appears in the Notebook as "Handwriting, page 3" without a relaunch;
    /// undoing it removes the row, redoing brings it back; closing the reader and tapping the row
    /// opens the reader at page 3 with the stroke on it.
    func testDrawnPageIsFoundInTheNotebookOpensAndGoesWhenUndone() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-screen", "notebook", "-openBook", "small", "-inkAnyInput",
                                                 "-alsoOpenWindow", "small", "-alsoOpenWindowPage", "3"])
        // Always end with one window (a window left open is restored into later launches).
        let pdfViews = app.otherElements.matching(identifier: ID.pdfView)
        let notebook = app.segmentedControls[ID.typeFilter].firstMatch
        addTeardownBlock { @MainActor in
            // Both windows still open (a failure before the reader window was closed): close it.
            if pdfViews.count > 0, notebook.exists {
                app.typeKey("w", modifierFlags: .command)
                sleep(2)
            }
        }
        XCTAssertTrue(waitForCount(pdfViews, atLeast: 1), "reader window")
        XCTAssertTrue(notebook.waitForExistence(timeout: 30), "the Notebook window")
        sleep(2)

        // Markup on in the reader window, then a stroke on page 3.
        let toggles = app.buttons.matching(identifier: ID.markupToggle)
        let toggle = try XCTUnwrap((0..<toggles.count).map { toggles.element(boundBy: $0) }.first { $0.isHittable },
                                   "the reader's Markup toggle")
        toggle.tap()
        XCTAssertTrue(wait(toggle, "label == %@", ["Done with Markup"]), "markup on: \(toggle.label)")
        let pdf = try XCTUnwrap((0..<pdfViews.count).map { pdfViews.element(boundBy: $0) }.first { $0.isHittable })
        let start = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 220, dy: 8)))
        XCTAssertTrue(wait(pdf.images[ID.ink(3)].firstMatch, "exists == true AND value == %@", ["1 stroke"]), "stroke drawn")

        // The Notebook (other window) lists page 3, live.
        let handwriting = row(app, ID.handwriting(3))
        XCTAssertTrue(handwriting.waitForExistence(timeout: 20), "page 3 listed in the Notebook")
        XCTAssertEqual(handwriting.label, "Handwriting, page 3")

        // Undo (the reader is the key window): all ink on the page gone, so the row goes.
        // A key press can be dropped while the window settles after the stroke: press again once
        // if nothing happened (the page has one stroke, so a second undo/redo is harmless).
        let pageInk = pdf.images[ID.ink(3)].firstMatch
        sleep(1)
        app.typeKey("z", modifierFlags: .command)
        if !wait(pageInk, "exists == false", timeout: 5) { app.typeKey("z", modifierFlags: .command) }
        XCTAssertTrue(wait(pageInk, "exists == false"), "stroke undone: \(String(describing: pageInk.value))")
        XCTAssertTrue(wait(handwriting, "exists == false", timeout: 20), "row removed after the ink was undone")
        // Redo: back again.
        app.typeKey("z", modifierFlags: [.command, .shift])
        if !wait(pageInk, "exists == true", timeout: 5) { app.typeKey("z", modifierFlags: [.command, .shift]) }
        XCTAssertTrue(wait(pageInk, "exists == true AND value == %@", ["1 stroke"]), "stroke redone")
        XCTAssertTrue(handwriting.waitForExistence(timeout: 20), "row back after redo")

        // Leave markup (flushes), close the reader window; the Notebook window comes forward.
        toggle.tap()
        XCTAssertTrue(wait(toggle, "label == %@", ["Markup"]), "markup off: \(toggle.label)")
        sleep(1)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(wait(pdf, "exists == false", timeout: 15), "reader window closed")
        XCTAssertTrue(wait(handwriting, "isHittable == true", timeout: 15), "Notebook in front")

        // Tap the row: the reader opens at page 3, with the stroke. (The first tap after the
        // other window closed may only activate this one: tap again if nothing opened.)
        let pill = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", ID.pagePill, "Page 3 of 12"))
            .firstMatch
        handwriting.tap()
        if !pill.waitForExistence(timeout: 8), handwriting.exists, handwriting.isHittable { handwriting.tap() }
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "reader at page 3: "
                      + app.buttons.matching(identifier: ID.pagePill).allElementsBoundByIndex.map(\.label).joined(separator: ", "))
        let opened = app.otherElements[ID.pdfView].firstMatch
        XCTAssertTrue(wait(opened.images[ID.ink(3)].firstMatch, "exists == true AND value == %@", ["1 stroke"]),
                      "the page shows its ink")
    }

    // MARK: Seeded

    func testHandwritingRowsFilterAndOpenTheirPage() {
        let app = launchSeeded()
        // Front matter: p. 1's note, then p. 2's handwriting.
        let front = row(app, ID.handwriting(2))
        XCTAssertTrue(front.waitForExistence(timeout: 10))
        XCTAssertEqual(front.label, "Handwriting, page 2")
        XCTAssertLessThan(row(app, ID.pageNote(1)).frame.minY, front.frame.minY)
        XCTAssertLessThan(front.frame.minY, row(app, ID.header("3 Matrices and Linear Maps")).frame.minY)

        // The Handwriting filter: only inked pages, under their headings.
        let filter = app.segmentedControls[ID.typeFilter].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.buttons["Handwriting"].tap()
        XCTAssertTrue(wait(row(app, ID.pageNote(1)), "exists == false", timeout: 5), "notes hidden")
        XCTAssertTrue(row(app, ID.handwriting(2)).exists)
        XCTAssertTrue(row(app, ID.handwriting(18)).waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, ID.header("5.1 Invariant Directions")).exists)
        XCTAssertFalse(row(app, ID.header("3 Matrices and Linear Maps")).exists, "no ink under chapter 3")
        XCTAssertLessThan(row(app, ID.header("5.1 Invariant Directions")).frame.minY, row(app, ID.handwriting(18)).frame.minY)
        // The 5.2 handwriting row (p. 25 also has a note and highlights, hidden by this filter).
        let p25 = row(app, ID.handwriting(25))
        if !p25.exists { app.swipeUp() }
        XCTAssertTrue(p25.waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, ID.pageNote(25)).exists)

        // Tap: the reader at that page.
        row(app, ID.handwriting(18)).tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", ["Page 18 of 40"]), pill.label)
    }

    func testAPageWithANoteHighlightsAndInkShowsEachAsItsOwnRow() {
        let app = launchSeeded()
        let scope = app.collectionViews["notebook.scopes"].otherElements[ID.scope("5.2 The Characteristic Equation")].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(scope.value as? String, "8 items")
        scope.tap()
        let note = row(app, ID.pageNote(25))
        let ink = row(app, ID.handwriting(25))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        if !ink.isHittable { app.swipeUp() }
        XCTAssertTrue(ink.waitForExistence(timeout: 5))
        XCTAssertLessThan(note.frame.minY, row(app, ID.highlight(25, 1)).frame.minY)
        XCTAssertLessThan(row(app, ID.highlight(25, 1)).frame.minY, ink.frame.minY)
        // A preview of the page: taller than a text row.
        XCTAssertGreaterThan(ink.frame.height, 200)
    }

    // MARK: Screenshots

    /// The appearance is the simulator's (`xcrun simctl ui <device> appearance dark`; setting
    /// `XCUIDevice.appearance` did not reach the app on the iOS 27 simulator). The runner's
    /// `SHOT_SUFFIX` (`TEST_RUNNER_SHOT_SUFFIX=-dark`) names the files.
    func testScreenshots() throws {
        continueAfterFailure = true
        let suffix = ProcessInfo.processInfo.environment["SHOT_SUFFIX"] ?? "-light"
        let app = launchSeeded()
        sleep(3)
        try saveShot("notebook-handwriting\(suffix)")
        let scope = app.collectionViews["notebook.scopes"].otherElements[ID.scope("5.1 Invariant Directions")].firstMatch
        if scope.waitForExistence(timeout: 5) { scope.tap() }
        sleep(3)
        try saveShot("notebook-handwriting-section\(suffix)")
        let whole = app.collectionViews["notebook.scopes"].otherElements[ID.scope("Whole book")].firstMatch
        if whole.exists { whole.tap() }
        let filter = app.segmentedControls[ID.typeFilter].firstMatch
        if filter.waitForExistence(timeout: 5) { filter.buttons["Handwriting"].tap() }
        sleep(3)
        try saveShot("notebook-handwriting-filter\(suffix)")
    }

    /// Narrow width: the type filter is a menu.
    func testScreenshotNarrow() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        let suffix = ProcessInfo.processInfo.environment["SHOT_SUFFIX"] ?? "-light"
        let app = launchSeeded(["-notebookDebugWidth", "420"])
        let menu = app.buttons[ID.typeFilter].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "type filter menu")
        menu.tap()
        let item = app.buttons["Handwriting"].firstMatch
        if item.waitForExistence(timeout: 5) { item.tap() }
        XCTAssertTrue(row(app, ID.handwriting(2)).waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, ID.pageNote(1)).exists, "filtered to handwriting")
        sleep(3)
        try saveShot("notebook-handwriting-narrow\(suffix)")
    }
}
