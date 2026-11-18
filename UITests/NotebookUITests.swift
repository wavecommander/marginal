import XCTest

/// Notebook: grouping along the outline, type filter and search, the inked note, opening
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
        static let select = "notebook.select"
        static let selectAll = "notebook.selectAll"
        static let selectDone = "notebook.selectDone"
        static let scopeMenu = "notebook.scopeMenu"
        static let feed = "notebook.feed"
        static let map = "notebook.map"
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
        let identifiers = ["Markdown": "notebook.export.markdown", "Markdown (ZIP)": "notebook.export.markdownZip",
                           "PDF": "notebook.export.pdf"]
        // A menu item reads as its title and its subtitle ("Markdown, Text only").
        let item = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                                                    identifiers[format] ?? format, format, format + ",")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(format) menu item")
        item.tap()
        if format == "Markdown" {
            // The seeded Notebook has a handwritten note: plain Markdown says it leaves images out.
            let textOnly = app.alerts["Images Are Not Included"].buttons["Export Text Only"].firstMatch
            XCTAssertTrue(textOnly.waitForExistence(timeout: 5), "told to use the ZIP for images")
            textOnly.tap()
        }
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

    /// The map of the whole book: a summary for VoiceOver, and touching a mark scrolls the feed
    /// to its item, widening a chosen heading to the whole book first (design: "Notebook map").
    func testMapScrollsTheFeedToAnItem() {
        let app = launch()
        let map = app.descendants(matching: .any)[ID.map].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(map.value as? String, "16 items, most in 5 Eigenvalues and Eigenvectors")

        // The yellow highlight on page 19 (index 18 of 40): its mark sits at 18.5 / 40. The feed
        // has rows after it, so it can come to the top.
        let target = row(app, ID.highlight(19, 0))
        let feed = app.scrollViews[ID.feed].firstMatch
        func tapMark() { map.coordinate(withNormalizedOffset: CGVector(dx: 18.5 / 40, dy: 0.3)).tap() }
        tapMark()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { target.isHittable && target.frame.minY - feed.frame.minY < 120 },
                      "the feed scrolled to p. 19: \(target.frame) in \(feed.frame)")

        // From a heading that does not contain it, the feed widens to the whole book.
        select(app, scope: "4 Determinants")
        XCTAssertTrue(waitForAbsence(target))
        tapMark()
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitUntil { target.isHittable })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
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

    /// A heading note's row opens the reader at the heading with that note in the notes panel
    /// (Section tab), not just at the page.
    func testTappingAHeadingNoteRowOpensItsSectionNote() {
        let app = launch()
        select(app, scope: "5 Eigenvalues and Eigenvectors")
        let note = row(app, ID.headingNote("5 Eigenvalues and Eigenvectors"))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        // The scope shows only its own headings, and a header speaks its page range. (Which
        // rows a scope lists, and in what order, is `NotebookFeedTests` in ReaderCore.)
        XCTAssertTrue(waitForAbsence(row(app, ID.header("3 Matrices and Linear Maps"))), "other chapters filtered out")
        XCTAssertTrue(row(app, ID.header("5 Eigenvalues and Eigenvectors")).label.contains("pages 15 to 30"))
        note.tap()
        let pill = app.buttons["reader.pagePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        let page = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 15 of 40"), object: pill)
        XCTAssertEqual(XCTWaiter().wait(for: [page], timeout: 15), .completed, pill.label)
        let sectionTab = app.segmentedControls["notesPanel.tabs"].buttons["Section note"].firstMatch
        XCTAssertTrue(sectionTab.waitForExistence(timeout: 15), "notes panel open")
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: sectionTab)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed, "Section tab selected")
        let title = app.staticTexts["notesPanel.title"].firstMatch
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "5 Eigenvalues and Eigenvectors"),
                                               object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [titled], timeout: 10), .completed, title.label)
        XCTAssertTrue(app.textViews["notePage.text"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Delete Note on a row (context menu): confirms with the notes panel's wording, then the row
    /// goes and the note does not come back.
    func testDeleteNoteFromARow() {
        let app = launch()
        let note = row(app, ID.pageNote(5))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.press(forDuration: 1.0)
        let delete = app.buttons["notebook.deleteNote"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete Note in the context menu")
        delete.tap()
        let alert = app.alerts["Delete This Note?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "confirmation")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Ink on the PDF page and highlights are not affected"))
            .firstMatch.exists, "the notes panel's message")
        // Cancel keeps it.
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(waitForAbsence(alert))
        XCTAssertTrue(note.exists, "cancel keeps the note")
        // Again, and delete.
        note.press(forDuration: 1.0)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(waitForAbsence(note, timeout: 10), "row removed")
        XCTAssertTrue(row(app, ID.pageNote(1)).exists, "other notes stay")
    }

    /// Deleting a note row in the Notebook shows the Undo pill; tapping it brings the row back.
    func testDeleteNoteFromARowUndoPillRestoresNote() {
        let app = launch()
        let note = row(app, ID.pageNote(5))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.press(forDuration: 1.0)
        let delete = app.buttons["notebook.deleteNote"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts["Delete This Note?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(waitForAbsence(note, timeout: 10), "row removed")

        let undoPill = app.buttons["notes.undoDelete"].firstMatch
        XCTAssertTrue(undoPill.waitForExistence(timeout: 5), "Undo pill appears after delete")
        undoPill.tap()

        XCTAssertTrue(note.waitForExistence(timeout: 10), "row restored")
        XCTAssertFalse(undoPill.exists, "Undo pill goes away once tapped")
    }

    func testExportMarkdownAndPDFPresentTheShareSheet() {
        let app = launch()
        export(app, "Markdown")
        export(app, "PDF")
    }

    /// "Select" puts a checkbox on every row; export then takes the ticked rows only. Plain
    /// Markdown says it leaves images out and offers the ZIP (screenshots:
    /// `build/shots/notebook-select.png`, `notebook-export-images.png`).
    func testSelectingRowsThenExportingThem() throws {
        let app = launch()
        let menu = app.buttons[ID.export].firstMatch
        let select = app.buttons[ID.select].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertTrue(app.buttons[ID.selectDone].firstMatch.waitForExistence(timeout: 5), "choosing")
        XCTAssertTrue(waitFor(menu, enabled: false), "nothing ticked: nothing to export")

        // A row ticks instead of opening the reader.
        let note = row(app, ID.pageNote(1))
        XCTAssertEqual(note.value as? String, "Not selected")
        note.tap()
        XCTAssertEqual(note.value as? String, "Selected")
        XCTAssertTrue(waitFor(menu, enabled: true), "one row ticked")

        // A header ticks everything under it.
        let header = row(app, ID.header("3 Matrices and Linear Maps"))
        header.tap()
        XCTAssertEqual(header.value as? String, "Selected")
        try saveShot("notebook-select")
        header.tap()
        XCTAssertEqual(header.value as? String, "Not selected")
        XCTAssertEqual(note.value as? String, "Selected", "other rows keep their tick")

        let all = app.buttons[ID.selectAll].firstMatch
        XCTAssertEqual(all.label, "Select All")
        all.tap()
        XCTAssertEqual(header.value as? String, "Selected")
        XCTAssertEqual(all.label, "Deselect All")

        export(app, "Markdown")
        export(app, "Markdown (ZIP)")

        // From the notice, "Export as ZIP" exports the ZIP.
        menu.tap()
        try saveShot("notebook-export-menu")
        app.buttons.matching(NSPredicate(format: "identifier == 'notebook.export.markdown' OR label BEGINSWITH 'Markdown,'"))
            .firstMatch.tap()
        let alert = app.alerts["Images Are Not Included"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'export as Markdown (ZIP)'")).firstMatch.exists)
        try saveShot("notebook-export-images")
        alert.buttons["Export as ZIP"].firstMatch.tap()
        XCTAssertTrue(waitForShareSheet(app), "share sheet for the ZIP")
        dismissShareSheet(app)
        XCTAssertTrue(waitFor(menu, enabled: true, timeout: 15), "export available again")

        app.buttons[ID.selectDone].firstMatch.tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5), "back to the plain Notebook")
        XCTAssertEqual(note.value as? String ?? "", "")
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

    func testRowContextMenuNewWindowOptionFollowsMultiWindowSupport() {
        let app = launch()
        let note = row(app, ID.pageNote(5))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Open"].firstMatch.waitForExistence(timeout: 5))
        let openInNewWindow = app.buttons["Open in New Window"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(openInNewWindow.exists, "Open in New Window is hidden on iPhone")
        } else {
            XCTAssertTrue(openInNewWindow.exists, "Open in New Window is shown on iPad")
        }
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
