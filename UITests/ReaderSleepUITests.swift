import XCTest

/// Design: "Sleeping readers". A reader two screens below the top of the window's stack falls
/// asleep (its session is released) after `-readerSleepDelay`, wakes when the screens above it
/// are popped, and opens at the book's latest position, wherever another reader on the book left
/// it. Reads `reader.markupState` (`sessions=N`: live reader sessions) and
/// `reader.viewportAnchor` ("page N x X y Y scale S"). Seeded with `-seedNotebook` on
/// `no-outline.pdf` (see `NotebookUITests`).
@MainActor
final class ReaderSleepUITests: XCTestCase {
    private enum ID {
        static let pagePill = "reader.pagePill"
        static let markupState = "reader.markupState"
        static let viewportAnchor = "reader.viewportAnchor"
        static let more = "reader.toolbar.more"
        static func header(_ title: String) -> String { "notebook.header.\(title)" }
        static func pageNote(_ page: Int) -> String { "notebook.pageNote.\(page)" }
        static func scope(_ title: String) -> String { "notebook.scope.\(title)" }
    }

    private struct Anchor: Equatable, CustomStringConvertible {
        var page: Int
        var y: Double
        var scale: Double
        var description: String { String(format: "p%d y%.2f s%.4f", page, y, scale) }
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testABuriedReaderSleepsAndWakesAtTheLatestPosition() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
            + ["-screen", "notebook", "-seedNotebook", "-exposeMarkupState", "-exposeViewportAnchor",
               "-pagePillStaysVisible", "-readerSleepDelay", "1"])
        let section = "5.1 Invariant Directions"
        XCTAssertTrue(row(app, ID.header("3 Matrices and Linear Maps")).waitForExistence(timeout: 30), "seeded feed")
        let scope = app.collectionViews["notebook.scopes"].otherElements[ID.scope(section)].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()

        // Notebook → reader A (page 17) → its Notebook → reader B on the same book (page 16).
        let note = row(app, ID.pageNote(17))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", ["Page 17 of 40"]), pill.label)
        let more = app.buttons[ID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        sleep(1)  // the push has finished
        // The More menu's item, not the back button (which reads "Notebook" here).
        let notebookItem = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                            "Notebook", "BackButton")).firstMatch
        for _ in 0..<3 where !notebookItem.exists {
            more.tap()
            _ = notebookItem.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(notebookItem.exists, "Notebook in the More menu")
        notebookItem.tap()
        let header = row(app, ID.header(section))
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        header.tap()
        XCTAssertTrue(wait(pill, "label == %@", ["Page 16 of 40"]), pill.label)

        // Reader A is two screens below the top: it falls asleep.
        let state = app.buttons[ID.markupState].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(state, "value CONTAINS %@", ["sessions=1"]), "the buried reader sleeps: \(state.value ?? "")")

        // Read on in reader B, then go back to reader A: it opens where B was left.
        sleep(1)  // hardware-key events need the window to have become key
        goToPage(app, 20)
        XCTAssertTrue(wait(pill, "label == %@", ["Page 20 of 40"]), pill.label)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5)))
        let left = settledAnchor(app)

        back(app)
        XCTAssertTrue(header.waitForExistence(timeout: 10), "back in the Notebook")
        back(app)
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        let woken = settledAnchor(app)
        print("READER-SLEEP left \(left), woken \(woken)")
        XCTAssertEqual(woken.page, left.page, "woken at the latest page: \(left) -> \(woken)")
        XCTAssertLessThanOrEqual(abs(woken.y - left.y), 1, "woken at the exact place: \(left) -> \(woken)")
        XCTAssertEqual(woken.scale, left.scale, accuracy: 0.001)
        XCTAssertTrue(wait(state, "value CONTAINS %@", ["sessions=1"]), "reader B went with its screen: \(state.value ?? "")")

        // The menu bar commands act on the woken reader.
        goToPage(app, 25)
        XCTAssertTrue(wait(pill, "label == %@", ["Page 25 of 40"]), pill.label)
    }

    // MARK: Helpers

    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Go to Page… (⌥⌘G on iOS 26+; on 17.5 the pill is tapped) and types the number.
    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        if #available(iOS 26.0, *) {
            app.typeKey("g", modifierFlags: [.command, .option])
        } else {
            app.buttons[ID.pagePill].firstMatch.tap()
        }
        sleep(1)
        app.typeText("\(number)\n")
    }

    private func readAnchor(_ app: XCUIApplication) -> Anchor? {
        guard let value = app.buttons[ID.viewportAnchor].firstMatch.value as? String else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 8, let page = Int(parts[1]), let y = Double(parts[5]), let scale = Double(parts[7]) else {
            return nil
        }
        return Anchor(page: page, y: y, scale: scale)
    }

    /// The anchor once it has stopped changing.
    private func settledAnchor(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Anchor {
        var last = readAnchor(app)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            usleep(500_000)
            let next = readAnchor(app)
            if next == last, next != nil { break }
            last = next
        }
        guard let last else {
            XCTFail("no viewport anchor", file: file, line: line)
            return Anchor(page: 0, y: 0, scale: 0)
        }
        return last
    }

    private func wait(_ element: XCUIElement, _ format: String, _ arguments: [Any], timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
