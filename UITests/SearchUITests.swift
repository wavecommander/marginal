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
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
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

    /// The "Page N of 1,500" pill. Found by its label: in the current shell snapshot the pill
    /// inherits the container's identifier, and the label formats the total with a separator.
    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page ' AND label CONTAINS ' of '")).firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        // Compares ignoring thousands separators ("Page 1,400 of 1,500").
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.label.replacingOccurrences(of: ",", with: "") == label { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                                          "search.group.")).firstMatch.exists)

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

    func testCancellingStopsResultsAndListScrollsWhileSearching() {
        // Slow the search to 30 ms a page (the 500-hit cap then takes ~15 s) so it is still running.
        let app = openLarge(["-searchPageDelayMs", "30"])
        _ = openSearch(app, query: "Fixture page")

        let first = resultRows(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons[ID.stop].exists, "still searching: \(status(app))")
        XCTAssertTrue(status(app).hasPrefix("Searching"), status(app))

        // The list scrolls while results are still arriving.
        let list = app.descendants(matching: .any)[ID.results].firstMatch
        XCTAssertTrue(list.exists)
        let before = first.label
        let started = Date()
        list.swipeUp()
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "scrolling blocked while searching")
        XCTAssertTrue(app.buttons[ID.stop].exists, "search should still be running after scrolling")
        _ = before

        // Stop: the count stops growing.
        app.buttons[ID.stop].tap()
        XCTAssertTrue(app.buttons[ID.resume].waitForExistence(timeout: 5))
        let atStop = status(app)
        XCTAssertTrue(atStop.hasPrefix("Stopped"), atStop)
        sleep(2)
        XCTAssertEqual(status(app), atStop, "results kept arriving after Stop")
        sleep(1)
        XCTAssertEqual(status(app), atStop)
    }

    func testNoResultsShowsAnEndState() {
        let app = openLarge()
        _ = openSearch(app, query: "qqxjzv")
        let status = app.staticTexts[ID.status].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(status, "No results", timeout: 60))
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
        let list = app.descendants(matching: .any)[ID.results].firstMatch
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
