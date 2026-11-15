import XCTest

/// First-run onboarding (docs/DESIGN.md, "First-run onboarding"). Every other UI test starts
/// with `-resetState`, which switches onboarding off; these add `-onboarding reset`, so each
/// launch here is a true first launch.
@MainActor
final class OnboardingUITests: XCTestCase {
    private static let firstLaunch = ["-resetState", "-onboarding", "reset"]
    private static let guideTitle = "Tactile Texts Quick Guide"
    private static let markupTipTitle = "Write with Apple Pencil"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func guideCells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "library.book.\(Self.guideTitle)")
    }

    func testWelcomeSheetShowsOnceAndNotNowLeavesTheEmptyLibrary() {
        let app = launch(Self.firstLaunch)
        XCTAssertTrue(app.staticTexts["Welcome to Tactile Texts"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["onboarding.welcome.openGuide"].exists)
        app.buttons["onboarding.welcome.notNow"].tap()

        XCTAssertTrue(app.staticTexts["No Books Yet"].waitForExistence(timeout: 10))
        // The empty state is one accessibility container, so its buttons are found by label.
        XCTAssertTrue(app.buttons["Open the Quick Guide"].exists)
        XCTAssertFalse(app.staticTexts["Welcome to Tactile Texts"].exists)

        // A second launch, as a reader's would be: no arguments, and no sheet.
        app.terminate()
        let again = launch([])
        XCTAssertTrue(again.buttons["Open the Quick Guide"].waitForExistence(timeout: 20))
        XCTAssertFalse(again.staticTexts["Welcome to Tactile Texts"].waitForExistence(timeout: 3))
    }

    func testQuickGuideOpensSeededHasNoTipsAndIsNeverDuplicated() {
        let app = launch(Self.firstLaunch)
        let openGuide = app.buttons["onboarding.welcome.openGuide"]
        XCTAssertTrue(openGuide.waitForExistence(timeout: 20))
        openGuide.tap()

        // The guide opens in the ordinary reader, on page 1, with its seeded page note.
        XCTAssertTrue(element(app, "reader.pdfView").waitForExistence(timeout: 30))
        let note = app.textViews["notePage.text"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(timeout: 15) { ((note.value as? String) ?? "").hasPrefix("This is a page note") },
                      "note text: \(String(describing: note.value))")
        XCTAssertTrue(element(app, "notePage.ink").waitForExistence(timeout: 10), "the seeded note carries ink")
        // The guide teaches by its pages: no tip points at anything in it.
        XCTAssertFalse(app.staticTexts[Self.markupTipTitle].waitForExistence(timeout: 4))

        app.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(guideCells(app).firstMatch.waitForExistence(timeout: 10))

        // Settings ▸ Help opens the same copy.
        app.buttons["settings.open"].firstMatch.tap()
        let fromSettings = app.buttons["settings.help.openGuide"]
        XCTAssertTrue(fromSettings.waitForExistence(timeout: 10))
        fromSettings.tap()
        XCTAssertTrue(element(app, "reader.pdfView").waitForExistence(timeout: 30))
        app.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(guideCells(app).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(guideCells(app).count, 1)
    }

    func testMarkupTipShowsOnceInARealBookAndGoesWhenMarkupIsUsed() {
        let app = launch(Self.firstLaunch + XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(element(app, "reader.pdfView").waitForExistence(timeout: 30))
        // A book is in hand, so there is no welcome sheet; the tip arrives once the page settles.
        let tip = app.staticTexts[Self.markupTipTitle]
        XCTAssertTrue(tip.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Welcome to Tactile Texts"].exists)

        let markup = element(app, "reader.toolbar.markup")
        markup.tap()
        XCTAssertTrue(waitFor { !tip.exists }, "the tip goes once Markup is on")

        // Shown once: the next launch of the same book has no tip.
        app.terminate()
        let again = launch(["-openBook", "small"])
        XCTAssertTrue(element(again, "reader.pdfView").waitForExistence(timeout: 30))
        XCTAssertFalse(again.staticTexts[Self.markupTipTitle].waitForExistence(timeout: 5))
    }
}
