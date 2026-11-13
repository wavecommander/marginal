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
        let withSeparator = label.replacingOccurrences(of: "1500", with: "1,500")
        let predicate = NSPredicate(format: "label == %@ OR label == %@", label, withSeparator)
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                                          "search.group.")).firstMatch.exists)

        XCTAssertFalse(app.buttons[ID.historyBack].isEnabled)
        row.tap()

        let pill = pill(app)
        XCTAssertTrue(waitForLabel(pill, "Page 1400 of 1500"))
        XCTAssertTrue(app.buttons[ID.historyBack].isEnabled, "the hit is a jump: Back must be enabled")
        // The panel closed after choosing.
        XCTAssertFalse(app.textFields[ID.field].exists)

        // Back returns to where the reader was.
        app.buttons[ID.historyBack].tap()
        XCTAssertTrue(waitForLabel(pill, "Page 1 of 1500"))
    }

    func testCancellingStopsResultsAndListScrollsWhileSearching() {
        // Slow the search to 4 ms a page so it is still running when the test acts.
        let app = openLarge(["-searchPageDelayMs", "4"])
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
        XCTAssertTrue(app.buttons[ID.resume].waitForExistence(timeout: 60))
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
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: dir.appendingPathComponent("\(name)-\(version).png"))
    }
}

extension SearchUITests {
    func testZZDump() {
        let app = openLarge()
        sleep(10)
        try? app.debugDescription.write(toFile: "/private/tmp/claude-501/ui-dump.txt", atomically: true, encoding: .utf8)
    }
}
