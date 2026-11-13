import XCTest

@MainActor
final class LibraryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchShowsLibraryAndImportButton() {
        let app = XCUIApplication.launchFresh()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["library.importButton"].exists)
    }
}
