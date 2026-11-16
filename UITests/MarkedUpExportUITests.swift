import XCTest

/// "Export Marked-Up PDF" in the reader's More menu: the two choices, the export's progress,
/// and the share sheet with the file. What the file holds is checked by the app-hosted
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
    }

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
        XCTAssertTrue(waitForShareSheet(app), "share sheet with the exported PDF")
    }
}
