import XCTest

/// "Export Marked-Up PDF" in the reader's More menu: the two choices, the confirmation before
/// it starts, the export's progress, running it in the background (it outlives the reader), the
/// share sheet, and the Notebook's "Exported PDFs", where the file stays until it is deleted. What the file holds is checked by the app-hosted
/// `MarkedUpExportTests`.
@MainActor
final class MarkedUpExportUITests: XCTestCase {
    // Mirrors `AccessibilityID.Reader` and `AccessibilityID.MarkedUpExport`.
    private enum ID {
        static let pdfView = "reader.pdfView"
        static let more = "reader.toolbar.more"
        static let menu = "reader.more.exportMarkedUp"
        static let bookOnly = "reader.more.exportMarkedUp.bookOnly"
        static let withNotes = "reader.more.exportMarkedUp.withNotes"
        static let progress = "reader.exportMarkedUp.progress"
        static let confirmExport = "reader.exportMarkedUp.confirm.export"
        static let confirmCancel = "reader.exportMarkedUp.confirm.cancel"
        static let background = "reader.exportMarkedUp.background"
        static let timeLeft = "reader.exportMarkedUp.timeLeft"
        static let status = "reader.exportMarkedUp.status"
        static let share = "reader.exportMarkedUp.status.share"
        static let hide = "reader.exportMarkedUp.status.hide"
        static let backgroundCancel = "reader.exportMarkedUp.status.cancel"
        static let confirmStop = "reader.exportMarkedUp.confirm.stop"
        static let confirmDelete = "reader.exportMarkedUp.confirm.delete"
        static let notebookSection = "notebook.exportedPDFs"
        static let notebookRow = "notebook.exportedPDFs.row"
        static let notebookShare = "notebook.exportedPDFs.share"
        static let notebookDelete = "notebook.exportedPDFs.delete"
        static func book(_ title: String) -> String { "library.book.\(title)" }
    }

    private static let fileName = "small (Marked Up).pdf"

    /// The confirmation's title for Book Only.
    private static let confirmationTitle = "Export Marked-Up PDF?"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
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

    /// `build/shots/<name>.png`, for looking at.
    private func saveShot(_ name: String) {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// A menu item by identifier, or by its title (an item reads as "Title, Subtitle").
    private func item(_ app: XCUIApplication, _ identifier: String, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                                         identifier, title, title + ",")).firstMatch
    }

    private func openExportMenu(_ app: XCUIApplication) {
        let more = app.buttons[ID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More menu")
        more.tap()
        let submenu = item(app, ID.menu, "Export Marked-Up PDF")
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), "Export Marked-Up PDF in the More menu")
        submenu.tap()
    }

    /// The confirmation shown before the export starts; checks what it says.
    private func confirmation(_ app: XCUIApplication) -> XCUIElement {
        let alert = app.alerts[Self.confirmationTitle].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "confirmation before exporting")
        let message = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "take a long time")).firstMatch
        XCTAssertTrue(message.exists, "the confirmation says the export can take a long time")
        XCTAssertTrue(message.label.contains("Tactile Texts will create a file at least as big as the current PDF"),
                      message.label)
        return alert
    }

    private func alertButton(_ alert: XCUIElement, _ identifier: String, _ title: String) -> XCUIElement {
        alert.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, title)).firstMatch
    }

    /// Answers the system's notification permission prompt, if it asks.
    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    private func openReader(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"]
                                              + extraArguments)
        XCTAssertTrue(app.otherElements[ID.pdfView].firstMatch.waitForExistence(timeout: 30), "reader open")
        sleep(2)  // the book's outline and Notebook tree are built
        return app
    }

    func testCancellingTheConfirmationExportsNothing() {
        let app = openReader()
        openExportMenu(app)
        let bookOnly = item(app, ID.bookOnly, "Book Only")
        XCTAssertTrue(bookOnly.waitForExistence(timeout: 5), "Book Only")
        bookOnly.tap()

        let alert = confirmation(app)
        saveShot("marked-up-export-confirmation")
        XCTAssertTrue(alertButton(alert, ID.confirmExport, "Export").exists, "Export button")
        alertButton(alert, ID.confirmCancel, "Cancel").tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "confirmation closes")

        XCTAssertFalse(app.progressIndicators[ID.progress].waitForExistence(timeout: 2), "no export runs")
        XCTAssertFalse(waitForShareSheet(app, timeout: 3), "no share sheet")
        // The command is offered again.
        openExportMenu(app)
        XCTAssertTrue(item(app, ID.bookOnly, "Book Only").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, ID.bookOnly, "Book Only").isEnabled, "Book Only is available again")
    }

    private func startBookOnlyExport(_ app: XCUIApplication) {
        openExportMenu(app)
        let bookOnly = item(app, ID.bookOnly, "Book Only")
        XCTAssertTrue(bookOnly.waitForExistence(timeout: 5), "Book Only")
        bookOnly.tap()
        alertButton(confirmation(app), ID.confirmExport, "Export").tap()
    }

    private func openNotebook(_ app: XCUIApplication) {
        let more = app.buttons[ID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More menu")
        more.tap()
        let notebook = app.buttons["Notebook"].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Notebook in the More menu")
        notebook.tap()
    }

    private func notebookRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[ID.notebookRow + "." + Self.fileName].firstMatch
    }

    /// Closes the share sheet's popover.
    private func dismissShareSheet(_ app: XCUIApplication) {
        let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismiss.exists { dismiss.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
        sleep(1)
    }

    func testABackgroundExportOutlivesItsReaderAndStaysInTheNotebook() {
        // About 8 seconds for small.pdf's 12 pages, so there is time to act while it runs.
        let app = openReader(["-exportPageDelayMs", "700"])
        startBookOnlyExport(app)

        let background = app.buttons[ID.background].firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 5), "Continue in Background on the progress card")
        XCTAssertTrue(app.staticTexts[ID.timeLeft].firstMatch.exists, "time left on the progress card")
        background.tap()
        allowNotificationsIfAsked()

        let status = app.buttons[ID.status].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "status pill while the export runs in the background")
        XCTAssertFalse(background.exists, "the progress card is gone")
        XCTAssertTrue(app.staticTexts[ID.timeLeft].firstMatch.exists, "time left on the status pill")
        saveShot("marked-up-export-background")

        // Leaving the book does not stop it.
        app.navigationBars.buttons["Library"].firstMatch.tap()
        let cell = app.buttons[ID.book("small")].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "back in the Library")
        sleep(10)
        cell.tap()
        XCTAssertTrue(app.otherElements[ID.pdfView].firstMatch.waitForExistence(timeout: 30), "reader open again")

        // Back in the book, the pill offers the finished file.
        let share = app.buttons[ID.share].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 40), "the pill offers Share when the export is ready")
        XCTAssertFalse(waitForShareSheet(app, timeout: 1), "the share sheet waits to be asked for")
        saveShot("marked-up-export-ready")
        share.tap()
        XCTAssertTrue(waitForShareSheet(app), "share sheet with the exported PDF")
        dismissShareSheet(app)
        XCTAssertTrue(share.waitForNonExistence(timeout: 5), "shared: the pill goes")

        // The file stays in the Notebook, with Share; Delete asks first.
        openNotebook(app)
        let row = notebookRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the export is listed under Exported PDFs")
        saveShot("marked-up-export-notebook")
        let notebookShare = app.buttons[ID.notebookShare].firstMatch
        XCTAssertTrue(notebookShare.exists, "Share in the Notebook")
        notebookShare.tap()
        XCTAssertTrue(waitForShareSheet(app), "share sheet from the Notebook")
        dismissShareSheet(app)
        XCTAssertTrue(row.exists, "sharing keeps the file")

        app.buttons[ID.notebookDelete].firstMatch.tap()
        let alert = app.alerts["Delete Exported PDF?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete asks first")
        alertButton(alert, ID.confirmDelete, "Delete").tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "deleted")
        XCTAssertFalse(app.descendants(matching: .any)[ID.notebookSection].exists, "no exports left")
    }

    func testStoppingAnExportAsksFirst() {
        let app = openReader(["-exportPageDelayMs", "2000"])
        startBookOnlyExport(app)
        let background = app.buttons[ID.background].firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        background.tap()
        allowNotificationsIfAsked()

        let stop = app.buttons[ID.backgroundCancel].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the pill's stop button")
        stop.tap()
        var alert = app.alerts["Stop Exporting?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "stopping asks first")
        alert.buttons["Keep Exporting"].tap()
        XCTAssertTrue(app.buttons[ID.status].firstMatch.waitForExistence(timeout: 3), "still exporting")

        stop.tap()
        alert = app.alerts["Stop Exporting?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alertButton(alert, ID.confirmStop, "Stop Export").tap()
        XCTAssertTrue(app.buttons[ID.status].firstMatch.waitForNonExistence(timeout: 10), "stopped")

        openNotebook(app)
        sleep(2)
        XCTAssertFalse(notebookRow(app).exists, "a stopped export keeps nothing")
    }

    func testBookOnlyExportOpensTheShareSheet() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(app.otherElements[ID.pdfView].firstMatch.waitForExistence(timeout: 30), "reader open")
        sleep(2)  // the book's outline and Notebook tree are built

        openExportMenu(app)
        let bookOnly = item(app, ID.bookOnly, "Book Only")
        XCTAssertTrue(bookOnly.waitForExistence(timeout: 5), "Book Only")
        // small.pdf has no notes yet: there is nothing to append.
        let withNotes = item(app, ID.withNotes, "Book with Notes")
        XCTAssertTrue(withNotes.exists, "Book with Notes is listed")
        XCTAssertFalse(withNotes.isEnabled, "Book with Notes is off while the book has no notes")
        saveShot("marked-up-export-menu")
        bookOnly.tap()
        XCTAssertFalse(waitForShareSheet(app, timeout: 1), "nothing is exported before the user confirms")
        alertButton(confirmation(app), ID.confirmExport, "Export").tap()
        XCTAssertTrue(waitForShareSheet(app), "share sheet with the exported PDF")
    }
}
