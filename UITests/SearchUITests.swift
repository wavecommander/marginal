import XCTest

/// Search (WP10): finds a phrase deep in `large.pdf` while the UI stays responsive, jumps to it
/// (recorded in section history), and stops when cancelled.
@MainActor
final class SearchUITests: XCTestCase {
    private enum ID {
        static let searchButton = "reader.toolbar.search"
        static let pagePill = "reader.pagePill"
        static let historyBack = "reader.toolbar.historyBack"
        static let field = "search.field"
        static let status = "search.status"
        static let stop = "search.stop"
        static let resume = "search.resume"
        static let results = "search.results"
        static let done = "search.done"
        static let resultPrefix = "search.result."
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func openLarge(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large) + ["-openBook", "large"] + extra)
    }

    private func openSearch(_ app: XCUIApplication, query: String) -> XCUIElement {
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        app.buttons[ID.searchButton].firstMatch.tap()
        let field = app.textFields[ID.field]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(query)
        return field
    }

    private func resultRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", ID.resultPrefix))
    }

    private func status(_ app: XCUIApplication) -> String {
        app.staticTexts[ID.status].firstMatch.label
    }

    /// The "Page N of 1500" pill.
    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[ID.pagePill].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: Tests

    func testFindPhraseOnPage1400JumpsAndRecordsHistory() {
        let app = openLarge()
        _ = openSearch(app, query: "zygomorphic lighthouse theorem")

        // The result streams in while the rest of the book is still being searched (about five
        // seconds on the simulator); a generous bound covers slower machines.
        let row = resultRows(app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90), "no result: \(status(app))")
        XCTAssertTrue(row.label.contains("p. 1400"), row.label)
        // The grouped list names the heading that contains page 1,400.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*, [0-9]+ results?"))
            .firstMatch.exists, "no group header")

        // At the iPadOS 17 floor a disabled toolbar Menu with a primary action still reports
        // enabled to XCUITest, so the "disabled before" check runs on newer systems only; the
        // Back-returns-to-start check below proves the jump was recorded on every system.
        if #available(iOS 18, *) { XCTAssertFalse(app.buttons[ID.historyBack].isEnabled) }
        row.tap()

        let pill = pill(app)
        XCTAssertTrue(waitForLabel(pill, "Page 1400 of 1500"))
        XCTAssertTrue(app.buttons[ID.historyBack].isEnabled, "the hit is a jump: Back must be enabled")
        // The panel closed after choosing.
        XCTAssertFalse(app.textFields[ID.field].exists)

        // Back returns to where the reader was.
        app.buttons[ID.historyBack].tap()
        // The section history returns to the section the reader left (near the start of the book).
        // (PDFKit may report page 2 as current while page 1 is on screen, so accept either.)
        XCTAssertTrue(waitForLabel(pill, "Page 1 of 1500", timeout: 4) || waitForLabel(pill, "Page 2 of 1500"),
                      "pill after Back: \(pill.label)")
    }

    func testCancellingStopsResultsAndListScrollsAfterwards() {
        // Slow the search to 100 ms a page (the 500-hit cap then needs ~50 s) so it is still
        // running when the test acts; every XCUITest query over large.pdf is slow (see below).
        let app = openLarge(["-searchPageDelayMs", "100"])
        _ = openSearch(app, query: "Fixture page")

        XCTAssertTrue(resultRows(app).firstMatch.waitForExistence(timeout: 60))
        // Stop: the result count stops growing.
        XCTAssertTrue(app.buttons[ID.stop].exists, "still searching: \(status(app))")
        app.buttons[ID.stop].tap()
        XCTAssertTrue(app.buttons[ID.resume].waitForExistence(timeout: 30))
        let atStop = status(app)
        XCTAssertTrue(atStop.hasPrefix("Stopped"), atStop)
        sleep(3)
        XCTAssertEqual(status(app), atStop, "results kept arriving after Stop")
        sleep(2)
        XCTAssertEqual(status(app), atStop)

        // The list scrolls. (No time bound: with large.pdf open every XCUITest snapshot walks
        // PDFKit's text-input view, `-[PDFTextInputView textInRange:]`, O(document), which pegs
        // the main thread during queries and gestures whatever the search does. Main-thread
        // responsiveness during a search is measured by `SearchEngineTests`' heartbeat test.)
        let list = app.collectionViews[ID.results]
        XCTAssertTrue(list.exists)
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertEqual(status(app), atStop)
    }

    func testNoResultsShowsAnEndState() {
        let app = openLarge()
        _ = openSearch(app, query: "qqxjzv")
        let status = app.staticTexts[ID.status].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(status, "No results", timeout: 240))
        XCTAssertEqual(resultRows(app).count, 0)
    }

    // MARK: Screenshots (written to build/shots by the UI test run)

    func testScreenshotsOfGroupedResults() throws {
        let app = openLarge()
        _ = openSearch(app, query: "Fixture page")
        XCTAssertTrue(resultRows(app).firstMatch.waitForExistence(timeout: 30))
        // Wait for the 500-result cap.
        let capped = app.buttons[ID.resume].waitForExistence(timeout: 60)
        if !capped { try save(app, "search-debug-not-capped") }
        XCTAssertTrue(capped, "status: \(status(app))")
        // Scrolling the list dismisses the keyboard so the results are visible in the shot.
        let list = app.collectionViews[ID.results]
        list.swipeUp()
        list.swipeDown()
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
        try save(app, "search-grouped-landscape")

        app.buttons[ID.done].tap()
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.buttons[ID.searchButton].firstMatch.tap()
        XCTAssertTrue(app.textFields[ID.field].waitForExistence(timeout: 10))
        sleep(1)
        try save(app, "search-grouped-portrait")
    }

    private func save(_ app: XCUIApplication, _ name: String) throws {
        let version = UIDevice.current.systemVersion
        let dir = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The raw screen buffer: in landscape the image comes out rotated a quarter turn (see the report).
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: dir.appendingPathComponent("\(name)-\(version).png"))
    }
}
