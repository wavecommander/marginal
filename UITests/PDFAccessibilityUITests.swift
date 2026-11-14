import XCTest

/// Accessibility of the PDF must stay cheap on a 1,500-page book: no accessibility query may
/// make PDFKit extract the whole document's text. Times typed queries and typing on `large.pdf`
/// and `small.pdf`, and checks that the visible page's text is still readable.
@MainActor
final class PDFAccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func loadAverage() -> String {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? String(format: "%.1f %.1f %.1f", load[0], load[1], load[2]) : "?"
    }

    private func timed<T>(_ label: String, _ body: () -> T) -> (T, TimeInterval) {
        let start = Date()
        let value = body()
        let elapsed = Date().timeIntervalSince(start)
        print("A11Y-TIMING \(label): \(String(format: "%.2f", elapsed)) s (load \(loadAverage()))")
        return (value, elapsed)
    }

    private func measure(_ fixture: String, _ title: String, page: Int, bound: TimeInterval) {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(fixture)
                                              + ["-openBook", title, "-openPage", "\(page)"])
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30))
        sleep(2)
        let (_, buttons) = timed("\(title) buttons query") { app.buttons["reader.pagePill"].firstMatch.label }
        let (fields, textFields) = timed("\(title) textFields query") { app.textFields.count }
        let (_, textViews) = timed("\(title) textViews query") { app.textViews.count }
        let (pageText, staticTexts) = timed("\(title) staticTexts query") {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture page \(page)")).firstMatch.exists
        }
        // A tap on the page makes PDFKit's text-input view active (as reading by hand does).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        sleep(1)
        let (_, tappedFields) = timed("\(title) textFields query after page tap") { app.textFields.count }
        let (_, tappedViews) = timed("\(title) textViews query after page tap") { app.textViews.count }
        // Typing into the go-to-page field (keyboard focus lookup walks text inputs).
        app.typeKey("g", modifierFlags: [.command, .option])
        sleep(1)
        let (_, typing) = timed("\(title) typeText") { app.typeText("\(page)\n") }
        sleep(1)
        // A text selection on the page (long press), as when highlighting.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).press(forDuration: 1.2)
        sleep(1)
        let (_, selectedFields) = timed("\(title) textFields query with a selection") { app.textFields.count }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)).tap()
        sleep(1)
        // The search panel open with its field focused, typing a query.
        app.typeKey("f", modifierFlags: [.command, .shift])
        sleep(2)
        let (_, searchFields) = timed("\(title) textFields query with search open") { app.textFields.count }
        let (_, searchTyping) = timed("\(title) typeText into search") { app.typeText("theorem") }
        sleep(2)
        let (_, searchFields2) = timed("\(title) textFields query with results") { app.textFields.count }
        print("A11Y-RESULT \(title): textFields=\(fields) pageTextReadable=\(pageText)")
        for (label, elapsed) in [("selection", selectedFields), ("search open", searchFields),
                                 ("search typing", searchTyping), ("search results", searchFields2)] {
            XCTAssertLessThan(elapsed, bound, "\(title) \(label) took \(elapsed) s (load \(loadAverage()))")
        }
        XCTAssertTrue(pageText, "\(title): the visible page's text is exposed to accessibility")
        for (label, elapsed) in [("buttons", buttons), ("textFields", textFields), ("textViews", textViews),
                                 ("staticTexts", staticTexts), ("textFields after tap", tappedFields),
                                 ("textViews after tap", tappedViews), ("typeText", typing)] {
            XCTAssertLessThan(elapsed, bound, "\(title) \(label) took \(elapsed) s (load \(loadAverage()))")
        }
    }

    func testTypedQueriesAreFastOnLargeBook() {
        measure(Fixtures.large, "large", page: 700, bound: 8)
    }

    func testTypedQueriesAreFastOnSmallBook() {
        measure(Fixtures.small, "small", page: 7, bound: 8)
    }
}
