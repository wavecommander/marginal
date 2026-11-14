import XCTest

/// Notebook (WP9): grouping along the outline, type filter and search, the inked note, opening
/// the reader from a row, export through the share sheet, live updates, and screenshots
/// (`build/shots/notebook-*.png`, suffix `-ios17` on iOS 17).
///
/// Seeded with the app's DEBUG `-seedNotebook` on `no-outline.pdf` (user headings 3, 4, 5, 5.1,
/// 5.2, 6; see `NotebookDebugSeed`). Queries are typed (buttons, cells, segmented controls): no
/// `.any` queries, which are slow and flood XCTest logging on iPadOS 17.5.
@MainActor
final class NotebookUITests: XCTestCase {
    // Mirrors `NotebookAccessibilityID` (the test target cannot import the app).
    private enum ID {
        static let typeFilter = "notebook.typeFilter"
        static let export = "notebook.export"
        static let scopeMenu = "notebook.scopeMenu"
        static func header(_ title: String) -> String { "notebook.header.\(title)" }
        static func headingNote(_ title: String) -> String { "notebook.headingNote.\(title)" }
        static func pageNote(_ page: Int) -> String { "notebook.pageNote.\(page)" }
        static func highlight(_ page: Int, _ index: Int) -> String { "notebook.highlight.\(page).\(index)" }
        static func scope(_ title: String) -> String { "notebook.scope.\(title)" }
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
                                              + ["-screen", "notebook", "-seedNotebook"] + extra)
        XCTAssertTrue(row(app, ID.header("3 Matrices and Linear Maps")).waitForExistence(timeout: 30), "seeded feed")
        return app
    }

    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    /// A filter-column entry.
    private func scope(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        // The entry's element inside its list cell.
        app.collectionViews["notebook.scopes"].otherElements[ID.scope(title)].firstMatch
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func select(_ app: XCUIApplication, scope title: String) {
        let entry = scope(app, title)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "scope \(title)")
        entry.tap()
    }

    private var shotSuffix: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18 ? "-ios17" : ""
    }

    private func saveShot(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("\(name)\(shotSuffix).png"))
    }

    /// The share sheet: its "Save to Files" action or its activity list.
    private func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists
                || app.cells["Save to Files"].exists || app.buttons["Save to Files"].exists
                || app.staticTexts["Save to Files"].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func dismissShareSheet(_ app: XCUIApplication) {
        let close = app.navigationBars["UIActivityContentView"].buttons.firstMatch
        if app.buttons["Close"].exists {
            app.buttons["Close"].firstMatch.tap()
        } else if close.exists, close.isHittable, close.label == "Close" {
            close.tap()
        } else {
            // A popover: tap outside it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        }
    }

    private func export(_ app: XCUIApplication, _ format: String) {
        let menu = app.buttons[ID.export].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(menu, enabled: true), "export enabled")
        menu.tap()
        let item = app.buttons[format].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(format) menu item")
        item.tap()
        XCTAssertTrue(waitForShareSheet(app), "share sheet for \(format)")
        dismissShareSheet(app)
        XCTAssertTrue(waitFor(menu, enabled: true, timeout: 15), "export available again after \(format)")
    }

    private func waitFor(_ element: XCUIElement, enabled: Bool, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: Tests

    func testSectionsGroupItemsUnderTheRightHeadings() {
        let app = launch()
        // Front matter first, then chapter 3 with its highlight and note.
        let front = row(app, ID.header("Front matter"))
        XCTAssertTrue(front.exists)
        XCTAssertLessThan(front.frame.minY, row(app, ID.pageNote(1)).frame.minY)
        XCTAssertLessThan(row(app, ID.pageNote(1)).frame.minY, row(app, ID.header("3 Matrices and Linear Maps")).frame.minY)

        select(app, scope: "5 Eigenvalues and Eigenvectors")
        let chapter = row(app, ID.header("5 Eigenvalues and Eigenvectors"))
        let s51 = row(app, ID.header("5.1 Invariant Directions"))
        let s52 = row(app, ID.header("5.2 The Characteristic Equation"))
        XCTAssertTrue(s51.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(row(app, ID.header("3 Matrices and Linear Maps"))), "other chapters filtered out")
        let order = [chapter, row(app, ID.headingNote("5 Eigenvalues and Eigenvectors")), s51,
                     row(app, ID.headingNote("5.1 Invariant Directions")), row(app, ID.pageNote(17)),
                     row(app, ID.highlight(19, 0)), s52]
        for (upper, lower) in zip(order, order.dropFirst()) {
            XCTAssertTrue(upper.exists && lower.exists, "\(upper.identifier) and \(lower.identifier)")
            XCTAssertLessThan(upper.frame.minY, lower.frame.minY, "\(upper.identifier) above \(lower.identifier)")
        }
        XCTAssertTrue(row(app, ID.header("5 Eigenvalues and Eigenvectors")).label.contains("pages 15 to 30"))
    }

    func testTypeFilterAndSearchNarrowTheFeed() {
        let app = launch()
        let filter = app.segmentedControls[ID.typeFilter].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.buttons["Highlights"].tap()
        XCTAssertTrue(row(app, ID.highlight(4, 0)).waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(row(app, ID.pageNote(5))), "page notes hidden")
        XCTAssertFalse(row(app, ID.header("Front matter")).exists, "front matter has no highlights")

        filter.buttons["Section Notes"].tap()
        XCTAssertTrue(row(app, ID.headingNote("5 Eigenvalues and Eigenvectors")).waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(row(app, ID.highlight(4, 0))))

        filter.buttons["All"].tap()
        XCTAssertTrue(row(app, ID.pageNote(5)).waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("triangular")
        XCTAssertTrue(waitForAbsence(row(app, ID.pageNote(5))), "non-matching note hidden")
        XCTAssertTrue(row(app, ID.pageNote(28)).waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, ID.highlight(29, 0)).exists)
        XCTAssertTrue(row(app, ID.header("5.2 The Characteristic Equation")).exists)
        XCTAssertFalse(row(app, ID.header("4 Determinants")).exists)
    }

    func testInkedNoteShowsItsHandwriting() {
        let app = launch()
        select(app, scope: "5.2 The Characteristic Equation")
        let inked = row(app, ID.pageNote(25))
        XCTAssertTrue(inked.waitForExistence(timeout: 5))
        XCTAssertTrue(inked.label.contains("Has handwriting"), inked.label)
        XCTAssertTrue(inked.label.contains("Why the determinant shows up"), inked.label)
        XCTAssertFalse(row(app, ID.pageNote(23)).label.contains("handwriting"))
        // Drawn as the note page (taller than its text alone would be: the sketch below the text).
        XCTAssertGreaterThan(inked.frame.height, 250)
    }

    func testTappingAPageRowOpensTheReaderOnThatPage() {
        let app = launch()
        select(app, scope: "5.1 Invariant Directions")
        let note = row(app, ID.pageNote(17))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        let pill = app.buttons["reader.pagePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 17 of 40"), object: pill)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, pill.label)

        // Back to the Notebook, then a heading row opens at the heading's start page.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let header = row(app, ID.header("5.1 Invariant Directions"))
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        let headingPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 16 of 40"), object: pill)
        XCTAssertEqual(XCTWaiter().wait(for: [headingPage], timeout: 15), .completed, pill.label)
    }

    func testExportMarkdownAndPDFPresentTheShareSheet() {
        let app = launch()
        export(app, "Markdown")
        export(app, "PDF")
    }

    func testANoteAddedWhileOpenAppearsWithoutRelaunch() {
        let app = launch(["-seedNotebookLateNote"])
        XCTAssertFalse(scope(app, "6 Orthogonality").exists)
        let deadline = Date().addingTimeInterval(20)
        while !scope(app, "6 Orthogonality").exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(scope(app, "6 Orthogonality").exists, "new heading entry")
        select(app, scope: "6 Orthogonality")
        XCTAssertTrue(row(app, ID.pageNote(33)).waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, ID.pageNote(33)).label.contains("Added while the Notebook was open."))
    }

    // MARK: Screenshots

    func testScreenshotLandscape() throws {
        continueAfterFailure = true
        let app = launch()
        _ = app
        sleep(2)
        try saveShot("notebook-landscape")
        select(app, scope: "5 Eigenvalues and Eigenvectors")
        sleep(2)
        try saveShot("notebook-landscape-chapter")
    }

    func testScreenshotNarrow() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["-notebookDebugWidth", "420"])
        XCTAssertTrue(app.buttons[ID.scopeMenu].firstMatch.waitForExistence(timeout: 5), "collapsed filter column")
        sleep(2)
        try saveShot("notebook-narrow")
    }
}
