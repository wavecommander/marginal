import XCTest

/// Scanned books (S3): the notice at import and the status in the search panel, on
/// `scanned.pdf` (page 1 typed, pages 2 to 30 pictures of text; "The quiet heron measures
/// tidewater." is on page 17).
///
/// Recognition runs for real (Vision in the simulator, about 1.4 s a page), so the waits are
/// generous. Screenshots go to `build/shots/scanned-*-<system version>.png`.
@MainActor
final class ScannedBooksUITests: XCTestCase {
    private enum ID {
        static let searchButton = "reader.toolbar.search"
        static let pagePill = "reader.pagePill"
        static let searchDone = "search.done"
        static let searchField = "search.field"
        static let searchStatus = "search.status"
        static let partial = "search.partial"
        static let status = "recognition.status"
        static let title = "recognition.status.title"
        static let detail = "recognition.status.detail"
        static let note = "recognition.status.note"
        static let makeSearchable = "recognition.makeSearchable"
        static let notNow = "recognition.notNow"
        static let pause = "recognition.pause"
        static let resume = "recognition.resume"
        static let heronHit = "search.result.text-16-0"
        static let scannedBook = "library.book.scanned"
        static let smallBook = "library.book.small"
    }

    private enum Words {
        static let noticeTitle = "“scanned” Looks Scanned"
        static let offerTitle = "This book looks scanned"
        static let inProgressTitle = "Making this book searchable…"
        static let pausedTitle = "Making this book searchable is paused"
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Tests

    /// Import shows the notice; Not Now; the book opens and reads; search makes the offer;
    /// Make Searchable; progress, Pause and Resume; "heron" is found on page 17 with its hit
    /// marked on the page; once complete the status goes.
    func testNoticeThenSearchOfferThenHeronFoundAndMarked() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.scanned))
        let notice = app.alerts[Words.noticeTitle].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "no notice after importing scanned.pdf")
        let message = notice.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("can't be searched as it is"), message)
        XCTAssertTrue(message.contains("reading every page on this iPad, which takes time and battery"), message)
        XCTAssertTrue(message.contains("Estimated time: less than a minute."), message)
        XCTAssertTrue(notice.buttons["Make Searchable"].exists)
        try save("scanned-notice")
        notice.buttons["Not Now"].tap()
        XCTAssertTrue(waitFor { !notice.exists }, "the notice did not close")

        // The book opens and reads normally.
        let cell = app.buttons[ID.scannedBook].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "the book did not open")
        XCTAssertTrue(waitForLabel(pill, "Page 1 of 30"), pill.label)

        // Search makes the offer (declined: the same explanation and choices).
        openSearch(app)
        let title = app.staticTexts[ID.title].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no status in the search panel")
        XCTAssertEqual(title.label, Words.offerTitle)
        let detail = app.staticTexts[ID.detail].firstMatch
        XCTAssertTrue(detail.label.contains("Your notes and highlights are searched as usual."), detail.label)
        XCTAssertTrue(app.buttons[ID.notNow].firstMatch.exists)
        // Searching before the book is searchable: page search is partial, nothing found.
        app.typeText("heron")
        XCTAssertTrue(app.staticTexts[ID.partial].firstMatch.waitForExistence(timeout: 10), "no partial line")
        XCTAssertTrue(waitForLabel(app.staticTexts[ID.searchStatus].firstMatch, "No results"))
        try save("scanned-search-offer")

        // Make Searchable: in progress, then Pause and Resume.
        app.buttons[ID.makeSearchable].firstMatch.tap()
        XCTAssertTrue(waitForLabel(title, Words.inProgressTitle), title.label)
        XCTAssertTrue(waitForLabel(detail) { $0.hasSuffix(" of 30 pages") }, detail.label)
        try save("scanned-search-in-progress")
        app.buttons[ID.pause].firstMatch.tap()
        XCTAssertTrue(waitForLabel(title, Words.pausedTitle), title.label)
        XCTAssertTrue(app.buttons[ID.resume].firstMatch.waitForExistence(timeout: 10))
        sleep(3)  // the page in flight when the pause came is still saved
        let pausedAt = detail.label
        sleep(4)
        XCTAssertEqual(detail.label, pausedAt, "pages kept being read while paused")
        try save("scanned-search-paused")
        app.buttons[ID.resume].firstMatch.tap()
        XCTAssertTrue(waitForLabel(title, Words.inProgressTitle), title.label)

        // The hit on page 17 arrives as the pages are read (the running search picks it up).
        let hit = app.buttons[ID.heronHit].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 120), "heron not found; status: \(detail.label)")
        XCTAssertTrue(hit.label.contains("p. 17"), hit.label)
        XCTAssertTrue(hit.label.localizedCaseInsensitiveContains("heron"), hit.label)

        // Complete: the status and the partial line go.
        XCTAssertTrue(waitFor(timeout: 120) { !title.exists }, "the status stayed: \(title.label) \(detail.label)")
        XCTAssertTrue(waitFor { !app.staticTexts[ID.partial].firstMatch.exists }, "the partial line stayed")

        // Choosing the hit jumps to page 17 and marks it from the recognised words' rects: the
        // word's yellow tint is on screen, and goes when a tap on the page clears the mark.
        hit.tap()
        XCTAssertTrue(waitForLabel(pill, "Page 17 of 30"), pill.label)
        sleep(2)
        let marked = Self.yellowPixels(XCUIScreen.main.screenshot().image)
        try save("scanned-heron-marked")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8)).tap()
        sleep(2)
        let cleared = Self.yellowPixels(XCUIScreen.main.screenshot().image)
        print("SCANNED-UI yellow pixels marked \(marked), cleared \(cleared)")
        XCTAssertGreaterThan(marked, cleared + 250, "no search mark on page 17 (yellow pixels \(marked) → \(cleared))")
    }

    /// A book with a text layer gets no notice.
    func testTypedImportShowsNoNotice() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small))
        XCTAssertTrue(app.buttons[ID.smallBook].firstMatch.waitForExistence(timeout: 60), "small.pdf was not imported")
        sleep(4)
        XCTAssertEqual(app.alerts.count, 0, "an alert appeared after importing small.pdf")
    }

    /// Declining at import is remembered: a relaunch shows no notice (the offer stays in search).
    func testRelaunchAfterDecliningShowsNoNotice() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.scanned))
        let notice = app.alerts[Words.noticeTitle].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "no notice after importing scanned.pdf")
        notice.buttons["Not Now"].tap()
        XCTAssertTrue(waitFor { !notice.exists })
        app.terminate()

        app.launchArguments = ["-pagePillStaysVisible"]
        app.launch()
        XCTAssertTrue(app.buttons[ID.scannedBook].firstMatch.waitForExistence(timeout: 60))
        sleep(4)
        XCTAssertEqual(app.alerts.count, 0, "a notice came back after relaunching")

        // Importing the same file again finds the book already there: no notice either.
        app.terminate()
        app.launchArguments = ["-pagePillStaysVisible"] + XCUIApplication.importing(Fixtures.scanned)
        app.launch()
        XCTAssertTrue(app.buttons[ID.scannedBook].firstMatch.waitForExistence(timeout: 60))
        sleep(4)
        XCTAssertEqual(app.alerts.count, 0, "re-importing the same book showed a notice")
        app.buttons[ID.scannedBook].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30))
        openSearch(app)
        XCTAssertTrue(waitForLabel(app.staticTexts[ID.title].firstMatch, Words.offerTitle), "the offer is gone from search")
    }

    /// Two windows on the book show the same state, live. The second window opens in front of
    /// the first (full screen), so they are checked in turn: accept in the front window (B),
    /// close it, and the first window (A), open on the book since launch, shows the progress in
    /// its own panel, counting up as pages finish; Pause there shows paused.
    func testSecondWindowShowsTheSameProgress() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.scanned)
            + ["-openBook", "scanned", "-alsoOpenWindow", "scanned"])
        let pills = app.buttons.matching(identifier: ID.pagePill)
        XCTAssertTrue(waitFor(timeout: 60) { pills.count >= 2 }, "the second window did not open")
        sleep(2)
        // No `isHittable` or snapshot queries on the window behind: on the iOS 27 simulator they
        // made backboardd abort (a Metal texture check while flattening the hidden scene).
        XCTAssertEqual(app.alerts.count, 0, "the notice must not cover a book opened at launch")
        let title = app.staticTexts[ID.title].firstMatch
        let detail = app.staticTexts[ID.detail].firstMatch

        // Window B (in front): the offer; accept it.
        app.buttons.matching(identifier: ID.searchButton).element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons[ID.searchDone].firstMatch.waitForExistence(timeout: 30), "the search panel did not open")
        sleep(1)
        XCTAssertTrue(app.buttons[ID.makeSearchable].firstMatch.waitForExistence(timeout: 15), "no offer in window B")
        app.buttons[ID.makeSearchable].firstMatch.tap()
        XCTAssertTrue(waitForLabel(title, Words.inProgressTitle), title.label)
        try save("scanned-two-windows-b-progress")
        let countInB = Self.pagesDone(detail.label)
        app.buttons[ID.searchDone].firstMatch.tap()
        sleep(1)

        // Close B (system Close Window, ⌘W): A comes forward, still open on the book.
        // The first ⌘W can go to the dismissing panel, so try up to three times.
        for _ in 0..<3 where pills.count > 1 {
            app.typeKey("w", modifierFlags: .command)
            _ = waitFor(timeout: 5) { pills.count == 1 }
        }
        XCTAssertEqual(pills.count, 1, "window B did not close")
        sleep(1)
        openSearch(app)
        XCTAssertTrue(waitForLabel(title, Words.inProgressTitle), "window A: \(title.label)")
        let first = Self.pagesDone(detail.label)
        XCTAssertGreaterThanOrEqual(first, countInB, "window A is behind window B")
        // Live: the count goes up in A's open panel as pages finish.
        XCTAssertTrue(waitForLabel(detail, timeout: 60) { Self.pagesDone($0) > first }, "no progress in A: \(detail.label)")
        try save("scanned-two-windows-a-progress")
        app.buttons[ID.pause].firstMatch.tap()
        XCTAssertTrue(waitForLabel(title, Words.pausedTitle), title.label)
        XCTAssertTrue(app.buttons[ID.resume].firstMatch.waitForExistence(timeout: 10))
        app.buttons[ID.resume].firstMatch.tap()
        XCTAssertTrue(waitForLabel(title, Words.inProgressTitle), title.label)
    }

    /// The "12" of "12 of 30 pages".
    static func pagesDone(_ label: String) -> Int {
        Int(label.split(separator: " ").first.map(String.init) ?? "") ?? -1
    }

    /// The offer at an accessibility text size, in portrait: the buttons stack, every line
    /// wraps, and the status scrolls within a capped height so the field stays in view.
    func testScreenshotOfferLargeText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.scanned)
            + ["-openBook", "scanned", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 60))
        openSearch(app)
        XCTAssertTrue(app.buttons[ID.makeSearchable].firstMatch.waitForExistence(timeout: 15))
        // The status scrolls rather than pushing the field out of the panel.
        XCTAssertTrue(app.textFields[ID.searchField].firstMatch.isHittable, "the search field is pushed out of view")
        try save("scanned-search-offer-large-text")
    }

    // MARK: Helpers

    private func openSearch(_ app: XCUIApplication) {
        app.buttons[ID.searchButton].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.searchDone].firstMatch.waitForExistence(timeout: 30), "the search panel did not open")
        sleep(1)  // the panel focuses its field 150 ms after presenting
    }

    private func waitFor(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    private func waitForLabel(_ element: XCUIElement, timeout: TimeInterval = 30, _ predicate: (String) -> Bool) -> Bool {
        waitFor(timeout: timeout) { element.exists && predicate(element.label) }
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 30) -> Bool {
        waitForLabel(element, timeout: timeout) { $0 == label }
    }

    /// Pixels the search mark tints: its yellow (`systemYellow` at 0.6, multiplied) over the
    /// page's white, about (255, 224, 102).
    static func yellowPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if r > 225, g > 180, g < 245, b < 160 { count += 1 }
        }
        return count
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
