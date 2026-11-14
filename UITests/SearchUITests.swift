import XCTest

/// Search (WP10) through the real UI.
///
/// Queries: the panel focuses its field itself, so the tests type with `app.typeText` and find
/// everything by typed, identifier-scoped queries (buttons, static texts). This style dates from
/// when PDFKit's `PDFTextInputView` was exposed to accessibility and any text-field query built a
/// selection over the whole of `large.pdf` (about 25 s); the reader no longer exposes it
/// (`ReaderPDFController`, and `PDFAccessibilityUITests` holds text-field queries and typing on
/// `large.pdf` to a few seconds), but typed queries remain the cheaper choice.
@MainActor
final class SearchUITests: XCTestCase {
    private enum ID {
        static let searchButton = "reader.toolbar.search"
        static let pagePill = "reader.pagePill"
        static let historyBack = "reader.toolbar.historyBack"
        static let status = "search.status"
        static let cancel = "search.cancel"
        static let resume = "search.resume"
        static let clear = "search.clear"
        static let results = "search.results"
        static let done = "search.done"
        static let resultPrefix = "search.result."
        static let groupPrefix = "search.group."
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func launch(_ fixture: String, _ title: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(fixture) + ["-openBook", title] + extra)
        XCTAssertTrue(pill(app).waitForExistence(timeout: 60), "the reader did not open")
        return app
    }

    /// Opens the panel from the toolbar and types into its field, which the panel focuses.
    private func openSearch(_ app: XCUIApplication, in scope: XCUIElement? = nil, typing query: String) {
        let root = scope ?? app
        root.buttons[ID.searchButton].firstMatch.tap()
        XCTAssertTrue(root.buttons[ID.done].firstMatch.waitForExistence(timeout: 30), "the search panel did not open")
        sleep(1)  // the panel focuses its field 150 ms after presenting
        app.typeText(query)
    }

    private func status(_ app: XCUIApplication, in scope: XCUIElement? = nil) -> XCUIElement {
        (scope ?? app).staticTexts[ID.status].firstMatch
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[ID.pagePill].firstMatch
    }

    private func row(_ app: XCUIApplication, _ resultID: String) -> XCUIElement {
        app.buttons[ID.resultPrefix + resultID].firstMatch
    }

    /// Waits for `element.label` to satisfy `predicate` (thousands separators ignored).
    private func waitForLabel(_ element: XCUIElement, timeout: TimeInterval = 30,
                              _ predicate: @escaping (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, predicate(element.label.replacingOccurrences(of: ",", with: "")) { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 30) -> Bool {
        waitForLabel(element, timeout: timeout) { $0 == label }
    }

    /// Times one UI interaction (printed for the report; machine load dominates these numbers).
    @discardableResult
    private func timed<T>(_ name: String, _ body: () -> T) -> (T, TimeInterval) {
        let start = Date()
        let value = body()
        let elapsed = Date().timeIntervalSince(start)
        print("SEARCH-UI \(name): \(String(format: "%.2f", elapsed)) s")
        return (value, elapsed)
    }

    // MARK: Tests

    /// One tap on the search button opens the panel again after each way of closing it: Done,
    /// a tap outside the popover, and choosing a result.
    func testSearchButtonReopensAfterEachWayOfClosing() {
        let app = launch(Fixtures.large, "large")
        let button = app.buttons[ID.searchButton].firstMatch
        let done = app.buttons[ID.done].firstMatch
        func reopen(_ step: String) {
            button.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10), "search did not reopen after \(step)")
        }

        reopen("launch")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "Done did not close search")
        reopen("Done")

        // Outside the popover (at the trailing edge) and above the keyboard (the bottom half in
        // landscape): the page, left of the popover.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)).tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "a tap outside did not close search")
        reopen("a tap outside")

        sleep(1)  // the panel focuses its field 150 ms after presenting
        app.typeText("zygomorphic lighthouse theorem")
        let hit = row(app, "text-1399-0")
        XCTAssertTrue(hit.waitForExistence(timeout: 90), "no result; status: \(status(app).label)")
        hit.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "choosing a result did not close search")
        reopen("choosing a result")
    }

    /// The phrase on page 1,400 of `large.pdf`: "No results" first for a nonsense query, then the
    /// phrase streams in under its heading; choosing it closes the panel, lands on page 1,400
    /// (page pill) through the jump API (Back becomes enabled), and Back returns to page 1.
    func testFindPhraseOnPage1400JumpsAndRecordsHistory() {
        let app = launch(Fixtures.large, "large")
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 1500"))
        let back = app.buttons[ID.historyBack].firstMatch
        // iPadOS 17 reports the shell's disabled Back button as enabled to XCUITest (WP4's note);
        // the Back press at the end proves the jump was recorded on every system.
        if #available(iOS 18, *) { XCTAssertFalse(back.isEnabled, "Back enabled before any jump") }

        openSearch(app, typing: "qqxjzv")
        XCTAssertTrue(waitForLabel(status(app), "No results", timeout: 90), "status: \(status(app).label)")

        app.buttons[ID.clear].firstMatch.tap()
        sleep(1)
        app.typeText("zygomorphic lighthouse theorem")
        let hit = row(app, "text-1399-0")
        XCTAssertTrue(hit.waitForExistence(timeout: 90), "no result; status: \(status(app).label)")
        XCTAssertTrue(hit.label.contains("p. 1400"), hit.label)
        XCTAssertTrue(hit.label.localizedCaseInsensitiveContains("zygomorphic lighthouse theorem"), hit.label)
        // The group header (scoped to the result list: an unscoped "any" query would walk
        // PDFKit's page elements).
        let header = app.collectionViews[ID.results].firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", ID.groupPrefix)).firstMatch
        XCTAssertTrue(header.exists, "no group header")
        XCTAssertEqual(header.label, "Set 3, in 14 Numerical Methods, Exercises, 1 result")
        XCTAssertTrue(waitForLabel(status(app), "1 result", timeout: 90), "status: \(status(app).label)")

        hit.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1400 of 1500"), "pill: \(pill(app).label)")
        XCTAssertFalse(app.buttons[ID.done].exists, "the panel stays open after choosing a result")
        XCTAssertTrue(back.isEnabled, "the hit is a jump: Back must be enabled")

        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 1500"), "pill after Back: \(pill(app).label)")
    }

    /// While a common-term search runs, the reader can scroll the result list and read the page;
    /// Cancel stops the count growing and offers Continue. The scan is slowed to 60 ms a page by
    /// `-searchPageDelayMs` (the 500-match cap then takes at least 30 s): at full speed the
    /// capped search ends in about a second, before XCUITest (2–3 s per action here) can act.
    /// Main-thread cost at full speed is measured by `SearchTests.Model`.
    func testCommonTermSearchStaysResponsiveAndCancelStopsIt() {
        let app = launch(Fixtures.large, "large", ["-searchPageDelayMs", "60"])
        openSearch(app, typing: "Fixture page")
        XCTAssertTrue(row(app, "text-0-0").waitForExistence(timeout: 30), "status: \(status(app).label)")
        XCTAssertTrue(status(app).label.hasPrefix("Searching…"), status(app).label)

        // Interact while results keep arriving.
        let list = app.collectionViews[ID.results].firstMatch
        XCTAssertTrue(list.exists)
        var slowest: TimeInterval = 0
        for index in 0..<2 {
            slowest = max(slowest, timed("swipe up \(index) during search") { list.swipeUp() }.1)
            slowest = max(slowest, timed("read page pill during search") { pill(app).label }.1)
            slowest = max(slowest, timed("swipe down \(index) during search") { list.swipeDown() }.1)
        }
        let during = status(app).label
        XCTAssertTrue(during.hasPrefix("Searching…"), "the interactions did not happen during the search: \(during)")
        // A blocked main thread would hold every interaction until the search ended.
        XCTAssertLessThan(slowest, 20, "an interaction took \(slowest) s during the search")

        let cancel = app.buttons[ID.cancel].firstMatch
        XCTAssertTrue(cancel.exists, "the search ended before Cancel: \(status(app).label)")
        cancel.tap()
        XCTAssertTrue(app.buttons[ID.resume].firstMatch.waitForExistence(timeout: 30))
        let atCancel = status(app).label
        XCTAssertTrue(atCancel.hasPrefix("Cancelled after"), atCancel)
        sleep(3)
        XCTAssertEqual(status(app).label, atCancel, "results kept arriving after Cancel")
    }

    // MARK: Screenshots (build/shots/search-*-<system version>.png)

    func testScreenshots() throws {
        let app = launch(Fixtures.large, "large")
        openSearch(app, typing: "Fixture page")
        XCTAssertTrue(app.buttons[ID.resume].firstMatch.waitForExistence(timeout: 60), "not capped: \(status(app).label)")
        app.collectionViews[ID.results].firstMatch.swipeUp()  // dismisses the keyboard
        sleep(1)
        try save("search-grouped-landscape")

        app.buttons[ID.done].firstMatch.tap()
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.buttons[ID.searchButton].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.done].firstMatch.waitForExistence(timeout: 30))
        sleep(1)
        app.collectionViews[ID.results].firstMatch.swipeUp()
        sleep(1)
        try save("search-grouped-portrait")
    }

    /// Accessibility text size: rows stack the page under the snippet.
    func testScreenshotLargeText() throws {
        let app = launch(Fixtures.small, "small",
                         ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openSearch(app, typing: "amber")
        XCTAssertTrue(waitForLabel(status(app), "1 result"), status(app).label)
        app.collectionViews[ID.results].firstMatch.swipeUp()
        sleep(1)
        try save("search-large-text")
    }

    private func save(_ name: String) throws {
        let version = UIDevice.current.systemVersion
        let dir = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = XCUIScreen.main.screenshot().image
        // Redraw so the PNG is upright whatever the device orientation.
        let png = UIGraphicsImageRenderer(size: image.size).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        try png.write(to: dir.appendingPathComponent("\(name)-\(version).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
