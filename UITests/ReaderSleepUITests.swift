import XCTest

/// Design: "Sleeping readers". A reader two screens below the top of the window's stack falls
/// asleep (its session is released) after `-readerSleepDelay`, wakes when the screens above it
/// are popped, and resumes exactly where it was left (place and zoom), whatever another reader on
/// the same book did meanwhile. Reads `reader.markupState` (`sessions=N`: live reader sessions)
/// and `reader.viewportAnchor` ("page N x X y Y scale S"). Seeded with `-seedNotebook` on
/// `no-outline.pdf` (see `NotebookUITests`).
@MainActor
final class ReaderSleepUITests: XCTestCase {
    private enum ID {
        static let pagePill = "reader.pagePill"
        static let markupState = "reader.markupState"
        static let viewportAnchor = "reader.viewportAnchor"
        static let more = "reader.toolbar.more"
        static let memoryWarning = "reader.memoryWarning"
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

    func testABuriedReaderSleepsAndResumesItsOwnPosition() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
            + ["-screen", "notebook", "-seedNotebook", "-exposeMarkupState", "-exposeViewportAnchor",
               "-pagePillStaysVisible", "-readerSleepDelay", "1"])
        let section = "5.1 Invariant Directions"
        XCTAssertTrue(row(app, ID.header("3 Matrices and Linear Maps")).waitForExistence(timeout: 30), "seeded feed")
        let scope = app.collectionViews["notebook.scopes"].otherElements[ID.scope(section)].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()

        // Notebook → reader A (page 17): zoom in and read on a little.
        let note = row(app, ID.pageNote(17))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", ["Page 17 of 40"]), pill.label)
        sleep(1)  // hardware-key events need the window to have become key
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        sleep(1)
        drag(app)
        let leftInA = settledAnchor(app)

        // Its Notebook → reader B on the same book (page 16, fit width).
        let more = app.buttons[ID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
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

        // Read on in reader B, then go back to reader A: it resumes where A was left.
        goToPage(app, 20)
        XCTAssertTrue(wait(pill, "label == %@", ["Page 20 of 40"]), pill.label)
        drag(app)
        let leftInB = settledAnchor(app)
        XCTAssertNotEqual(leftInB.page, leftInA.page)

        back(app)
        XCTAssertTrue(header.waitForExistence(timeout: 10), "back in the Notebook")
        back(app)
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        let woken = settledAnchor(app)
        print("READER-SLEEP A left \(leftInA), B left \(leftInB), A woken \(woken)")
        XCTAssertEqual(woken.page, leftInA.page, "A resumes its own page: \(leftInA) -> \(woken)")
        XCTAssertLessThanOrEqual(abs(woken.y - leftInA.y), 1, "A resumes its own place: \(leftInA) -> \(woken)")
        XCTAssertEqual(woken.scale, leftInA.scale, accuracy: 0.001, "A resumes its own zoom")
        XCTAssertTrue(wait(state, "value CONTAINS %@", ["sessions=1"]), "reader B went with its screen: \(state.value ?? "")")

        // The menu bar commands act on the woken reader.
        goToPage(app, 25)
        XCTAssertTrue(wait(pill, "label == %@", ["Page 25 of 40"]), pill.label)
    }

    /// A memory warning puts every off-screen reader to sleep at once: here the sleep delay is
    /// ten minutes, so only the warning can have done it. The reader on screen stays.
    func testAMemoryWarningSleepsOffScreenReadersAtOnce() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
            + ["-screen", "notebook", "-seedNotebook", "-exposeMarkupState", "-exposeViewportAnchor",
               "-pagePillStaysVisible", "-readerSleepDelay", "600"])
        let section = "5.1 Invariant Directions"
        XCTAssertTrue(row(app, ID.header("3 Matrices and Linear Maps")).waitForExistence(timeout: 30), "seeded feed")
        let scope = app.collectionViews["notebook.scopes"].otherElements[ID.scope(section)].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()

        // Notebook → reader A (page 17) → its Notebook → reader B (page 16).
        let note = row(app, ID.pageNote(17))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", ["Page 17 of 40"]), pill.label)
        let leftInA = settledAnchor(app)
        let more = app.buttons[ID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
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

        // Both readers are awake, and stay so: the countdown is ten minutes.
        let state = app.buttons[ID.markupState].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(state, "value CONTAINS %@", ["sessions=2"]), "both awake: \(state.value ?? "")")
        sleep(3)
        XCTAssertTrue((state.value as? String)?.contains("sessions=2") == true, "still both: \(state.value ?? "")")

        // The warning: reader A sleeps now; reader B, on screen, stays where it is.
        let warning = app.buttons[ID.memoryWarning].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        warning.tap()
        XCTAssertTrue(wait(state, "value CONTAINS %@", ["sessions=1"], timeout: 5), "A sleeps at once: \(state.value ?? "")")
        XCTAssertEqual(pill.label, "Page 16 of 40")

        // Reader A wakes where it was left.
        back(app)
        XCTAssertTrue(header.waitForExistence(timeout: 10), "back in the Notebook")
        back(app)
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", ["Page 17 of 40"]), pill.label)
        let woken = settledAnchor(app)
        XCTAssertEqual(woken.page, leftInA.page)
        XCTAssertLessThanOrEqual(abs(woken.y - leftInA.y), 1, "A resumes its own place: \(leftInA) -> \(woken)")
    }

    // MARK: Helpers

    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    /// Scrolls the page down a little by dragging (not a jump).
    private func drag(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5)))
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
