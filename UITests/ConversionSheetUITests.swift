import XCTest

/// The Convert to PDF sheet (F3), driven through `-importFixture` with the stub converter
/// (`-stubConverters`): the sheet appears for an EPUB, Cancel leaves the Library empty, Convert
/// imports the book, and `-confirmConversions` skips the sheet.
@MainActor
final class ConversionSheetUITests: XCTestCase {
    /// `Tests/Fixtures/f3-small.epub` (a two-chapter EPUB 3) and `f3-notes.md`.
    private static func fixture(_ name: String) -> String {
        Fixtures.repoRoot.appendingPathComponent("Tests/Fixtures/\(name)").path
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func book(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["library.book.\(title)"].firstMatch
    }

    /// Scrolls the sheet's form up until `target` is on screen (form rows off screen are not in
    /// the accessibility tree).
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, swipes: Int = 6) {
        let sheet = element(app, "conversion.sheet")
        for _ in 0..<swipes where !(target.exists && target.isHittable) {
            sheet.swipeUp()
        }
    }

    private func launch(_ fixtures: [String], extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(["-stubConverters"] + extra
            + fixtures.flatMap { XCUIApplication.importing(Self.fixture($0)) })
    }

    func testAnEPUBShowsTheSheetAndCancelLeavesTheLibraryEmpty() {
        let app = launch(["f3-small.epub"])
        let convert = app.buttons["conversion.convert"]
        XCTAssertTrue(convert.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["conversion.cancel"].exists)
        XCTAssertTrue(app.navigationBars["Convert to PDF?"].exists || app.staticTexts["Convert to PDF?"].exists)
        XCTAssertTrue(element(app, "conversion.block.common").exists, app.debugDescription)
        XCTAssertTrue(element(app, "conversion.block.epub").exists)
        XCTAssertTrue(app.staticTexts["f3-small.epub"].exists)
        XCTAssertTrue(element(app, "conversion.limitation.pageNumbersDiffer").exists)
        XCTAssertTrue(element(app, "conversion.limitation.fixedPages").exists)
        // The symbols are decoration: VoiceOver reads only the sentences.
        XCTAssertEqual(app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'conversion.'")).count, 0)
        // The Text size setting is further down the sheet.
        reveal(app, element(app, "conversion.textSize"))
        XCTAssertTrue(element(app, "conversion.textSize").exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Choose now. It can't be changed after converting."].exists)

        app.buttons["conversion.cancel"].tap()
        XCTAssertTrue(convert.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Books Yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(book(app, "Stub Title").exists)
    }

    func testConvertImportsTheBook() {
        let app = launch(["f3-small.epub"])
        let convert = app.buttons["conversion.convert"]
        XCTAssertTrue(convert.waitForExistence(timeout: 20), app.debugDescription)
        let large = app.buttons["Large"].firstMatch
        reveal(app, large)
        XCTAssertTrue(large.exists, app.debugDescription)
        large.tap()
        XCTAssertTrue(large.isSelected)
        convert.tap()
        XCTAssertTrue(convert.waitForNonExistence(timeout: 10))
        XCTAssertTrue(book(app, "Stub Title").waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '3 pages'")).firstMatch.exists)
        // It opens like any book.
        book(app, "Stub Title").tap()
        XCTAssertTrue(app.buttons["reader.toolbar.contents"].firstMatch.waitForExistence(timeout: 20))
    }

    func testMarkdownHasTheTextBlockAndTextSize() {
        let app = launch(["f3-notes.md"])
        XCTAssertTrue(app.buttons["conversion.convert"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(element(app, "conversion.block.textAndWeb").exists)
        XCTAssertFalse(element(app, "conversion.block.epub").exists)
        XCTAssertTrue(element(app, "conversion.textSize").exists)
        app.buttons["conversion.cancel"].tap()
        XCTAssertTrue(app.staticTexts["No Books Yet"].waitForExistence(timeout: 10))
    }

    func testConfirmConversionsImportsWithoutTheSheet() {
        let app = launch(["f3-small.epub"], extra: ["-confirmConversions"])
        XCTAssertTrue(book(app, "Stub Title").waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.buttons["conversion.convert"].exists)
    }

    func testTheSheetWorksAtTheLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-pagePillStaysVisible", "-resetState", "-stubConverters",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                               "-importFixture", Self.fixture("f3-small.epub")]
        app.launch()
        let convert = app.buttons["conversion.convert"]
        XCTAssertTrue(convert.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(convert.isHittable)
        // At accessibility sizes the text size is a list of choices, not three segments.
        let large = app.buttons["Large"].firstMatch
        reveal(app, large, swipes: 12)
        XCTAssertTrue(large.exists, app.debugDescription)
        large.tap()
        XCTAssertTrue(large.isSelected || large.value as? String == "1" || app.buttons["Large"].firstMatch.isSelected,
                      app.debugDescription)
        // The buttons stay in reach after scrolling.
        XCTAssertTrue(convert.isHittable)
        app.buttons["conversion.cancel"].tap()
        XCTAssertTrue(convert.waitForNonExistence(timeout: 10))
    }
}
