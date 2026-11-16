import XCTest

/// A library from a newer version (docs/DESIGN.md "A library from a newer version"): the app
/// says so instead of failing, opens it in this version after a confirmation, and the library is
/// there at the next launch. The store is `Tests/Fixtures/NewerVersionLibrary.store`, written by
/// the scanned-books build (schema version 3), planted with `-plantLibraryStore`.
@MainActor
final class LibraryRecoveryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testNewerLibraryOpensInThisVersion() {
        let fixture = Fixtures.repoRoot.appendingPathComponent("Tests/Fixtures/NewerVersionLibrary.store").path
        let app = XCUIApplication.launchFresh(["-plantLibraryStore", fixture])

        XCTAssertTrue(element(app, "library.unavailable").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Library From a Newer Version"].exists)
        element(app, "library.unavailable.openInThisVersion").tap()
        let confirm = app.alerts.buttons["Open in This Version"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element(app, "library.unavailable.ready").waitForExistence(timeout: 30))

        app.terminate()
        let reopened = XCUIApplication()
        reopened.launchArguments = ["-pagePillStaysVisible"]
        reopened.launch()
        XCTAssertTrue(reopened.buttons["library.book.Newer Library Book"].waitForExistence(timeout: 20))
        XCTAssertFalse(element(reopened, "library.unavailable").exists)
    }
}
