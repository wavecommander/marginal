import XCTest

/// Section history with links inside the PDF (TSOFT-214), on `links.pdf`: `small.pdf`'s pages and
/// outline plus links. Back and Forward go through the toolbar buttons (synthesized ⌘[ / ⌘] are
/// intermittently lost on the iPadOS 27 simulator). Positions come from the
/// `-exposeViewportAnchor` hook (`reader.viewportAnchor`, "page N x X y Y scale S", page space).
@MainActor
final class SectionHistoryUITests: XCTestCase {
    struct Anchor: Equatable, CustomStringConvertible {
        var page: Int
        var x: Double
        var y: Double
        var scale: Double
        var description: String { String(format: "p%d x%.2f y%.2f s%.4f", page, x, y, scale) }
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.links)
                                              + ["-openBook", "links", "-exposeViewportAnchor"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["reader.viewportAnchor"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement { app.buttons["reader.pagePill"].firstMatch }
    private func back(_ app: XCUIApplication) -> XCUIElement { app.buttons["reader.toolbar.historyBack"].firstMatch }
    private func forward(_ app: XCUIApplication) -> XCUIElement { app.buttons["reader.toolbar.historyForward"].firstMatch }

    private func readAnchor(_ app: XCUIApplication) -> Anchor? {
        guard let value = app.buttons["reader.viewportAnchor"].firstMatch.value as? String else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 8, let page = Int(parts[1]), let x = Double(parts[3]), let y = Double(parts[5]),
              let scale = Double(parts[7]) else { return nil }
        return Anchor(page: page, x: x, y: y, scale: scale)
    }

    /// The anchor once it has stopped changing (moves and alignment finished).
    private func settledAnchor(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Anchor {
        var last = readAnchor(app)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            usleep(500_000)
            let next = readAnchor(app)
            if next == last, next != nil { break }
            last = next
        }
        guard let last else {
            XCTFail("no viewport anchor", file: file, line: line)
            return Anchor(page: 0, x: 0, y: 0, scale: 0)
        }
        return last
    }

    /// Same page point at the top of the view (≤ 1 pt in page space).
    private func assertSamePlace(_ actual: Anchor, _ expected: Anchor, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        print("SECTION-HISTORY \(context): left \(expected), now \(actual)")
        XCTAssertEqual(actual.page, expected.page, "\(context): \(actual), left at \(expected)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.y - expected.y), 1, "\(context): \(actual), left at \(expected)",
                                 file: file, line: line)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        app.typeKey("g", modifierFlags: [.command, .option])
        sleep(1)
        app.typeText("\(number)\n")
        XCTAssertTrue(waitForLabel(pill(app), "Page \(number) of 12"))
    }

    /// Drags the page area upward by `fraction` of the window (scrolls down, no tap).
    private func scrollPage(_ app: XCUIApplication, by fraction: Double = 0.25) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Taps page-space point (`x`, `y`) of the page at the top of the view, placed from the
    /// reading anchor (the top-left corner of the PDF view is the anchor's page point).
    private func tapPagePoint(_ app: XCUIApplication, x: Double, y: Double, anchor: Anchor) {
        let frame = app.descendants(matching: .any)["reader.pdfView"].firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.minX + (x - anchor.x) * anchor.scale,
                                   dy: frame.minY + (anchor.y - y) * anchor.scale)).tap()
    }

    // MARK: Tests

    /// TSOFT-214, the owner's sequence: jump A → B, Back, Forward, read on in B, tap a link to C,
    /// Back: back in B at the exact place the link was tapped (not section A, not the top of the
    /// page). Forward then returns to C.
    func testBackAfterFollowingALinkReturnsToTheExactPlace() {
        let app = launch()
        goToPage(app, 6)                                       // A "1 Linear Systems" → B "2.1 Foundations"
        XCTAssertTrue(back(app).isEnabled)
        back(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        forward(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 6 of 12"))

        // Read on until page 7 is at the top: its "3.2 Exercises" link (y 200–224) is in view.
        var left = settledAnchor(app)
        for _ in 0..<6 where left.page < 7 {
            scrollPage(app)
            left = settledAnchor(app)
        }
        XCTAssertEqual(left.page, 7, "read on to page 7: \(left)")
        XCTAssertGreaterThan(left.y, 300, "the link is in view: \(left)")
        let leftPage = pill(app).label
        tapPagePoint(app, x: 140, y: 212, anchor: left)
        XCTAssertTrue(waitForLabel(pill(app), "Page 12 of 12"), "the link was followed")

        back(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), leftPage), "Back returned to \(pill(app).label)")
        assertSamePlace(settledAnchor(app), left, "Back after the link")
        XCTAssertTrue(forward(app).isEnabled)
        forward(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 12 of 12"))
        back(app).tap()
        assertSamePlace(settledAnchor(app), left, "Back again")
        back(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        XCTAssertFalse(back(app).isEnabled)
    }

    /// A link tapped from the middle of a page into another section, then Back: the exact place
    /// the link was tapped. A link into the section the reader is already in adds no entry.
    func testMidPageAndSameSectionLinks() {
        let app = launch()
        goToPage(app, 3)                                       // "1.1 Foundations"; link at y 400–424
        scrollPage(app, by: 0.15)
        let left = settledAnchor(app)
        XCTAssertEqual(left.page, 3, "\(left)")
        XCTAssertLessThan(left.y, 780, "scrolled into the page: \(left)")
        tapPagePoint(app, x: 140, y: 412, anchor: left)          // → page 7 y 450, "2.1 Foundations"
        XCTAssertTrue(waitForLabel(pill(app), "Page 7 of 12"), "the link was followed")

        // Page 7's "start of 2.1" link (y 120–144) lands in the same section: no entry.
        let onSeven = settledAnchor(app)
        XCTAssertEqual(onSeven.page, 7, "\(onSeven)")
        XCTAssertGreaterThan(onSeven.y, 144, "the same-section link is in view: \(onSeven)")
        tapPagePoint(app, x: 140, y: 132, anchor: onSeven)
        XCTAssertTrue(waitForLabel(pill(app), "Page 6 of 12"), "the same-section link was followed")
        XCTAssertFalse(forward(app).isEnabled)

        back(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 3 of 12"))
        assertSamePlace(settledAnchor(app), left, "Back to where the mid-page link was tapped")
        back(app).tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        XCTAssertFalse(back(app).isEnabled)
    }
}
