import XCTest

/// Library (WP3): import through `-importFixture` (the real pipeline), grid, open, rename,
/// delete, dedupe, sort, search, a large import, and a second window.
@MainActor
final class LibraryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func launch(_ fixtures: [String] = [], extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(fixtures.flatMap { XCUIApplication.importing($0) } + extra)
    }

    private func book(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["library.book.\(title)"].firstMatch
    }

    private func titlesInGridOrder(_ app: XCUIApplication) -> [String] {
        let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).allElementsBoundByIndex
        return cells
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map { $0.identifier.replacingOccurrences(of: "library.book.", with: "") }
    }

    /// Something only a reader shows: its toolbar's Contents toggle.
    private func readerToolbar(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["reader.toolbar.contents"].firstMatch
    }

    private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    private func openContextMenu(_ app: XCUIApplication, of title: String) {
        let cell = book(app, title)
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.press(forDuration: 1.0)
    }

    // MARK: Tests

    func testLaunchShowsLibraryAndImportButton() {
        let app = XCUIApplication.launchFresh()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["library.importButton"].exists)
        XCTAssertTrue(app.staticTexts["No Books Yet"].waitForExistence(timeout: 5))
    }

    func testImportOpenBackRenameDelete() {
        let app = launch([Fixtures.small])
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["12 pages · 75 KB"].exists || app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH '12 pages'")).firstMatch.exists)

        // Open in place, then back to the Library.
        book(app, "small").tap()
        XCTAssertTrue(readerToolbar(app).waitForExistence(timeout: 20))
        app.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 10))
        // The book was opened, so the Continue reading card shows it.
        XCTAssertTrue(app.descendants(matching: .any)["library.continueCard"].waitForExistence(timeout: 10))

        // Rename.
        openContextMenu(app, of: "small")
        XCTAssertTrue(menuItem(app, "Rename…").waitForExistence(timeout: 5))
        menuItem(app, "Rename…").tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "Renamed")
        app.alerts.buttons["Rename"].tap()
        if app.alerts.firstMatch.waitForNonExistence(timeout: 3) == false {
            // The first tap can only dismiss the keyboard's input assistant.
            app.alerts.buttons["Rename"].tap()
        }
        XCTAssertTrue(book(app, "Renamed").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(book(app, "small").exists)

        // Delete with the confirmation.
        openContextMenu(app, of: "Renamed")
        XCTAssertTrue(menuItem(app, "Delete…").waitForExistence(timeout: 5))
        menuItem(app, "Delete…").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'permanently removes'")).firstMatch.exists,
                      app.debugDescription)
        alert.buttons["Delete"].tap()
        XCTAssertTrue(book(app, "Renamed").waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Books Yet"].waitForExistence(timeout: 10))
    }

    func testImportingTheSameFileTwiceYieldsOneBook() {
        let app = launch([Fixtures.small, Fixtures.small])
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertEqual(app.buttons.matching(identifier: "library.book.small").count, 1)
    }

    func testLargeImportKeepsTheUIResponsive() {
        let started = Date()
        let app = launch([Fixtures.large])
        XCTAssertTrue(book(app, "large").waitForExistence(timeout: 30))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        // The grid responds: the sort menu opens and closes.
        let sort = app.buttons["library.sortMenu"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        XCTAssertTrue(app.buttons["Title"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Title"].firstMatch.tap()
        XCTAssertTrue(book(app, "large").exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1,500 pages'")).firstMatch.exists)
    }

    func testSortChangesTheGridOrder() {
        // Imported in this order: small, large, no-outline.
        let app = launch([Fixtures.small, Fixtures.large, Fixtures.noOutline])
        XCTAssertTrue(book(app, "no-outline").waitForExistence(timeout: 30))
        XCTAssertTrue(book(app, "large").exists && book(app, "small").exists)
        let sort = app.buttons["library.sortMenu"].firstMatch

        sort.tap()
        app.buttons["Title"].firstMatch.tap()
        XCTAssertTrue(waitFor { self.titlesInGridOrder(app) == ["large", "no-outline", "small"] }, "\(titlesInGridOrder(app))")

        sort.tap()
        app.buttons["Date Added"].firstMatch.tap()
        XCTAssertTrue(waitFor { self.titlesInGridOrder(app) == ["no-outline", "large", "small"] }, "\(titlesInGridOrder(app))")
    }

    func testSearchFiltersByTitle() {
        let app = launch([Fixtures.small, Fixtures.large, Fixtures.noOutline])
        XCTAssertTrue(book(app, "no-outline").waitForExistence(timeout: 30))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("larg")
        XCTAssertTrue(book(app, "small").waitForNonExistence(timeout: 10))
        XCTAssertTrue(book(app, "large").exists, app.debugDescription)
        XCTAssertFalse(book(app, "no-outline").exists)
        // No match: the empty search state.
        search.typeText("zzz")
        XCTAssertTrue(book(app, "large").waitForNonExistence(timeout: 10))
    }

    func testOpenInNewWindowShowsAReaderBesideTheLibrary() {
        let app = launch([Fixtures.small])
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 20))
        openContextMenu(app, of: "small")
        XCTAssertTrue(menuItem(app, "Open in New Window").waitForExistence(timeout: 5))
        menuItem(app, "Open in New Window").tap()
        XCTAssertTrue(readerToolbar(app).waitForExistence(timeout: 20), app.debugDescription)
        // The Library window is still there.
        XCTAssertTrue(book(app, "small").exists)
    }

    func testImportButtonPresentsTheFilesPicker() {
        let app = launch()
        let button = app.buttons["library.importButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        // The system document picker is out of process; its Cancel button proves it appeared.
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10) || app.otherElements["Browse"].exists
                      || app.navigationBars.count > 1, app.debugDescription)
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }
}
