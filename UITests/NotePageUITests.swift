import XCTest

/// Note page (WP13): ink follows text, ink persists, typing in markup mode, read-only ink outside
/// markup mode, emptied notes are deleted. Runs in the notes panel host with `-inkAnyInput` so a
/// finger can draw.
@MainActor
final class NotePageUITests: XCTestCase {
    // Mirrors `NotePageAccessibilityID` (the test target cannot import the app).
    private enum ID {
        static let text = "notePage.text"
        static let ink = "notePage.ink"
        static let writingSpace = "notePage.writingSpace"
        static let status = "notePage.status"
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func launch(fresh: Bool, markup: Bool) -> XCUIApplication {
        var arguments = ["-openBook", "small", "-notesPanel", "page", "-inkAnyInput"]
        if markup { arguments.append("-markup") }
        let app: XCUIApplication
        if fresh {
            app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + arguments)
        } else {
            app = XCUIApplication()
            app.launchArguments = arguments
            app.launch()
        }
        XCTAssertTrue(textView(app).waitForExistence(timeout: 30), "note text view")
        return app
    }

    private func textView(_ app: XCUIApplication) -> XCUIElement {
        app.textViews[ID.text].firstMatch
    }

    private func ink(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[ID.ink].firstMatch
    }

    private func writingSpace(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[ID.writingSpace].firstMatch
    }

    private func status(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[ID.status].firstMatch
    }

    private func wait(_ element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A point on the note page, in note-page points from the page's top-left (zoom 100%).
    private func pagePoint(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        textView(app).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Draws a horizontal finger stroke on the note page (markup mode, `-inkAnyInput`).
    private func drawLine(_ app: XCUIApplication, y: CGFloat, from x0: CGFloat = 40, to x1: CGFloat = 200) {
        pagePoint(app, x: x0, y: y).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: x1, y: y + 2))
    }

    /// Top of an element relative to the top of the note page (screen points).
    private func top(of element: XCUIElement, in app: XCUIApplication) -> CGFloat {
        element.frame.minY - textView(app).frame.minY
    }

    // MARK: Tests

    func testStrokeOverAWordMovesWhenAParagraphIsInsertedAbove() {
        let app = launch(fresh: true, markup: true)
        textView(app).tap()
        textView(app).typeText("First line\nSecond line has the word")
        XCTAssertTrue(wait(textView(app), "value CONTAINS %@", "has the word"))

        // Line 2 of the note: insets 14 + one band (22 + 6) + half a line.
        drawLine(app, y: 14 + 28 + 11, from: 100, to: 200)
        XCTAssertTrue(ink(app).waitForExistence(timeout: 5), "stroke drawn")
        XCTAssertTrue(wait(ink(app), "value == %@", "1 stroke"))
        let inkBefore = top(of: ink(app), in: app)
        let spaceBefore = top(of: writingSpace(app), in: app)

        // Insert a paragraph above, at the very start of the note.
        pagePoint(app, x: 15, y: 14 + 11).tap()
        textView(app).typeText("Inserted\n")
        XCTAssertTrue(wait(textView(app), "value BEGINSWITH %@", "Inserted\nFirst line"))

        let inkMoved = top(of: ink(app), in: app) - inkBefore
        let spaceMoved = top(of: writingSpace(app), in: app) - spaceBefore
        XCTAssertGreaterThan(spaceMoved, 20, "the text grew by one paragraph")
        XCTAssertEqual(inkMoved, spaceMoved, accuracy: 0.5, "the stroke moved by exactly the inserted height")
        XCTAssertEqual(ink(app).value as? String, "1 stroke")
    }

    func testStrokeIsStillThereAfterRelaunch() {
        let app = launch(fresh: true, markup: true)
        drawLine(app, y: 160)
        XCTAssertTrue(ink(app).waitForExistence(timeout: 5))
        let frameBefore = ink(app).frame.offsetBy(dx: -textView(app).frame.minX, dy: -textView(app).frame.minY)
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"))
        app.terminate()

        let again = launch(fresh: false, markup: false)
        XCTAssertTrue(ink(again).waitForExistence(timeout: 10), "stroke restored")
        XCTAssertEqual(ink(again).value as? String, "1 stroke")
        let frameAfter = ink(again).frame.offsetBy(dx: -textView(again).frame.minX, dy: -textView(again).frame.minY)
        XCTAssertEqual(frameAfter.minY, frameBefore.minY, accuracy: 1)
        XCTAssertEqual(frameAfter.minX, frameBefore.minX, accuracy: 1)
        XCTAssertEqual(textView(again).label, "Note with handwriting")
    }

    func testTypingWithMarkupOnByTapping() {
        let app = launch(fresh: true, markup: true)
        textView(app).tap()
        textView(app).typeText("Typed in markup mode")
        XCTAssertTrue(wait(textView(app), "value == %@", "Typed in markup mode"))
        XCTAssertFalse(ink(app).exists, "a finger tap places the cursor and leaves no dot")
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"))
    }

    func testCanvasTakesNoInputOutsideMarkupMode() {
        let app = launch(fresh: true, markup: false)
        drawLine(app, y: 160)
        drawLine(app, y: 30)
        sleep(1)
        XCTAssertFalse(ink(app).exists, "no ink outside markup mode")
        // The text view still takes input.
        textView(app).tap()
        textView(app).typeText("Reading mode")
        XCTAssertTrue(wait(textView(app), "value == %@", "Reading mode"))
        XCTAssertFalse(ink(app).exists)
    }

    /// Not a check: leaves a marked-up note behind and saves the "Markup · page and note
    /// together" screenshot (panel widened) to `build/shots/notepage-wide-<OS>.png`.
    func testScreenshotMarkupPageAndNoteTogether() throws {
        let app = launch(fresh: true, markup: true)
        textView(app).tap()
        textView(app).typeText("Why the determinant shows up\n(A - kI)v = 0 needs a nonzero v, so A - kI has to flatten some direction to zero. That means singular, and singular means det = 0.\n- Degree of the polynomial = size of the matrix.\n- Ex. 5.4: trace 4 = 1 + 3 and det 3 = 1 x 3.")
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
        // Underline in the second paragraph, a ring in the text, and a sketch in the blank space.
        drawLine(app, y: 14 + 28 + 22 + 20, from: 150, to: 290)
        drawLine(app, y: 14 + 28 + 4 * 22 + 17, from: 20, to: 120)
        pagePoint(app, x: 40, y: 330).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: 270, y: 328))
        pagePoint(app, x: 150, y: 345).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: 151, y: 230))
        pagePoint(app, x: 95, y: 342).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: 220, y: 236))
        pagePoint(app, x: 95, y: 236).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: 215, y: 342))
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"))

        // Widen the panel to half the window by dragging its divider.
        let divider = app.descendants(matching: .any)["reader.notesDivider"].firstMatch
        if divider.waitForExistence(timeout: 5) {
            let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: -400, dy: 0)))
        }
        sleep(2)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let version = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "os"
        try shot.pngRepresentation.write(to: directory.appendingPathComponent("notepage-wide-ios\(version).png"))
    }

    func testEmptiedNoteIsGoneAfterRelaunch() {
        let app = launch(fresh: true, markup: false)
        textView(app).tap()
        textView(app).typeText("Temporary")
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"))
        textView(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        XCTAssertTrue(wait(status(app), "label == %@", "Empty"))
        app.terminate()

        let again = launch(fresh: false, markup: false)
        XCTAssertTrue(wait(status(again), "label == %@", "Empty"), "no stored note")
        XCTAssertEqual((textView(again).value as? String) ?? "", "")
    }
}
