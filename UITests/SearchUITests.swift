import XCTest

/// Search through the real UI.
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
        static let markupToggle = "reader.toolbar.markup"
        static let notesSheet = "reader.pane.notesSheet"
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
    private func openSearch(_ app: XCUIApplication, in scope: XCUIElement? = nil, typing query: String,
                            within timeout: TimeInterval = 30) {
        let root = scope ?? app
        root.buttons[ID.searchButton].firstMatch.tap()
        XCTAssertTrue(root.buttons[ID.done].firstMatch.waitForExistence(timeout: timeout), "the search panel did not open")
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

    /// Swipes the result list with a fast drag between two of its points. `swipeUp()` refuses it:
    /// UIKit puts an arrowed popover's content under a zero-size view, so XCUITest reports the
    /// list's visible frame as empty although the list is on screen and scrolls under a finger.
    private func swipe(_ list: XCUIElement, up: Bool) {
        let low = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let high = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        (up ? low : high).press(forDuration: 0.05, thenDragTo: up ? high : low,
                                withVelocity: .fast, thenHoldForDuration: 0)
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

    /// The phrase on page 1,400 of `large.pdf`: "No results" first for a nonsense query, then the
    /// phrase streams in under its heading; choosing it closes the panel, lands on page 1,400
    /// (page pill) through the jump API (Back becomes enabled), and Back returns to page 1.
    func testFindPhraseOnPage1400JumpsAndRecordsHistory() {
        let app = launch(Fixtures.large, "large")
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 1500"))
        let back = app.buttons[ID.historyBack].firstMatch
        // iPadOS 17 reports the shell's disabled Back button as enabled to XCUITest (see `ReaderUITests`);
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
            slowest = max(slowest, timed("swipe up \(index) during search") { swipe(list, up: true) }.1)
            slowest = max(slowest, timed("read page pill during search") { pill(app).label }.1)
            slowest = max(slowest, timed("swipe down \(index) during search") { swipe(list, up: false) }.1)
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

    /// TSOFT-216: the search popover hangs under the toolbar, pointing at the search button, and
    /// leaves the toolbar's other buttons in place; once search closes, by any route, the search
    /// button looks exactly as it did before it was tapped (same pixels, not selected). Covers
    /// Done, ⇧⌘F, a tap outside and choosing a result, then markup mode (the search
    /// button must not end up like the filled Markup toggle) and the narrow layout, where the
    /// notes sheet steps aside and comes back.
    ///
    /// Also: one tap on the search button opens the panel again, within 10 s, after each way of
    /// closing it. The steps are ordered so that a toolbar tap follows Done, a tap outside and
    /// choosing a result.
    func testSearchButtonLooksUnchangedAfterSearchCloses() throws {
        let app = launch(Fixtures.small, "small")
        let button = app.buttons[ID.searchButton].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        var baseline = settledImage(of: button)

        openAndClose(app, baseline, "Done") { app.buttons[ID.done].firstMatch.tap() }
        if #available(iOS 18.0, *) {  // hardware-key events (see ReaderUITests' menu test)
            openAndClose(app, baseline, "⇧⌘F, then Done", open: { self.pressFindUntilOpen(app) }) {
                app.buttons[ID.done].firstMatch.tap()
            }
        }
        // Opened by one tap after Done.
        openAndClose(app, baseline, "tap outside") {
            // On the page above the keyboard, once the keyboard is up (a tap while the popover
            // still moves is dropped); again if the first tap was lost.
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            let done = app.buttons[ID.done].firstMatch
            for _ in 0..<2 where done.exists {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25)).tap()
                _ = self.waitFor(done, timeout: 3) { !$0.exists }
            }
        }
        // Opened by one tap after a tap outside (`openSearch` taps the toolbar button); the next
        // step opens it by one tap after a result was chosen.
        openAndClose(app, baseline, "choosing a result", open: { self.openSearch(app, typing: "amber\n", within: 10) }) {
            let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", ID.resultPrefix)).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 30), "no result for amber")
            result.tap()
        }

        let markup = app.buttons[ID.markupToggle].firstMatch
        markup.tap()
        XCTAssertTrue(waitFor(markup, \.isSelected), "markup did not turn on")
        baseline = settledImage(of: button)
        openAndClose(app, baseline, "Done in markup mode") { app.buttons[ID.done].firstMatch.tap() }
        markup.tap()
        XCTAssertTrue(waitFor(markup) { !$0.isSelected }, "markup did not turn off")

        XCUIDevice.shared.orientation = .portrait
        let sheet = app.descendants(matching: .any)[ID.notesSheet].firstMatch
        if #available(iOS 26.0, *) { XCTAssertTrue(sheet.waitForExistence(timeout: 15), "no notes sheet") }
        baseline = settledImage(of: button)
        openAndClose(app, baseline, "Done in the narrow layout") { app.buttons[ID.done].firstMatch.tap() }
        if #available(iOS 26.0, *) { XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the notes sheet did not come back") }
    }

    /// Opens search (the toolbar button by default), checks the panel's place, closes it with
    /// `close` and waits for the search button to look like `baseline` again.
    private func openAndClose(_ app: XCUIApplication, _ baseline: UIImage, _ route: String,
                              open: (() -> Void)? = nil, close: () -> Void) {
        let button = app.buttons[ID.searchButton].firstMatch
        let done = app.buttons[ID.done].firstMatch
        if let open {
            open()
            XCTAssertTrue(done.waitForExistence(timeout: 30), "\(route): search did not open")
        } else {
            button.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10), "\(route): one tap did not open search")
        }
        // Under the toolbar, not over it, with the toolbar's other buttons still there.
        XCTAssertGreaterThanOrEqual(done.frame.minY, button.frame.maxY, "\(route): the panel covers the toolbar")
        XCTAssertTrue(app.buttons[ID.markupToggle].firstMatch.exists, "\(route): the Markup toggle is gone")
        close()
        XCTAssertTrue(waitFor(done) { !$0.exists }, "\(route): search did not close")
        let after = waitForImage(of: button, matching: baseline)
        if !Self.looksTheSame(after, baseline) {
            for (name, image) in [("before", baseline), ("after \(route)", after)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "search button \(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTFail("\(route): the search button looks different after search closed")
        }
        XCTAssertFalse(button.isSelected, "\(route): the search button is selected")
    }

    /// ⇧⌘F. Hardware keys are intermittently lost on the iPadOS 27 simulator: one retry.
    private func pressFindUntilOpen(_ app: XCUIApplication) {
        let done = app.buttons[ID.done].firstMatch
        for _ in 0..<2 where !done.exists {
            app.typeKey("f", modifierFlags: [.command, .shift])
            _ = done.waitForExistence(timeout: 5)
        }
    }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10,
                         _ predicate: (XCUIElement) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate(element) { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// The element's image once two consecutive captures agree (the toolbar has settled).
    private func settledImage(of element: XCUIElement) -> UIImage {
        var previous = element.screenshot().image
        for _ in 0..<50 {
            usleep(200_000)
            let image = element.screenshot().image
            if Self.looksTheSame(image, previous) { return image }
            previous = image
        }
        return previous
    }

    /// The element's image as soon as it matches `baseline`, or its last image after 10 s.
    private func waitForImage(of element: XCUIElement, matching baseline: UIImage) -> UIImage {
        let deadline = Date().addingTimeInterval(10)
        var image = element.screenshot().image
        while !Self.looksTheSame(image, baseline) && Date() < deadline {
            usleep(200_000)
            image = element.screenshot().image
        }
        return image
    }

    /// Same size and no channel of any pixel more than 8 apart (screenshot encoding noise).
    private static func looksTheSame(_ a: UIImage, _ b: UIImage) -> Bool {
        guard let pa = rgba(a), let pb = rgba(b), pa.count == pb.count else { return false }
        return zip(pa, pb).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
    }

    private static func rgba(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                                          bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? data : nil
    }

    // MARK: Screenshots (build/shots/search-*-<system version>.png)

    func testScreenshots() throws {
        let app = launch(Fixtures.large, "large")
        openSearch(app, typing: "Fixture page")
        XCTAssertTrue(app.buttons[ID.resume].firstMatch.waitForExistence(timeout: 60), "not capped: \(status(app).label)")
        swipe(app.collectionViews[ID.results].firstMatch, up: true)  // dismisses the keyboard
        sleep(1)
        try save("search-grouped-landscape")

        app.buttons[ID.done].firstMatch.tap()
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.buttons[ID.searchButton].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.done].firstMatch.waitForExistence(timeout: 30))
        sleep(1)
        swipe(app.collectionViews[ID.results].firstMatch, up: true)
        sleep(1)
        try save("search-grouped-portrait")
    }

    /// Accessibility text size: rows stack the page under the snippet.
    func testScreenshotLargeText() throws {
        let app = launch(Fixtures.small, "small",
                         ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openSearch(app, typing: "amber")
        XCTAssertTrue(waitForLabel(status(app), "1 result"), status(app).label)
        swipe(app.collectionViews[ID.results].firstMatch, up: true)
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
