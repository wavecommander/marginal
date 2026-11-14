import XCTest

/// The notes panel (WP8) on `small.pdf` (12 pages; "1 Linear Systems" p1 with "1.1 Foundations"
/// p2–3 and "1.2 Exercises" p4; "2 Vector Spaces" p5 with 2.1 p6–7 and 2.2 p8; "3 Eigenvalues"
/// p9…). Queries are typed and scoped (never `.any` over the PDF's element tree) except for the
/// shell's divider.
@MainActor
final class NotesPanelUITests: XCTestCase {
    /// Mirrors `NotesPanelAccessibilityID` and `NotePageAccessibilityID`.
    private enum ID {
        static let tabs = "notesPanel.tabs"
        static let title = "notesPanel.title"
        static let status = "notePage.status"
        static let zoom = "notePage.zoom"
        static let shrink = "notesPanel.shrink"
        static let level = "notesPanel.level"
        static let pageIsIn = "notesPanel.pageIsIn"
        static func pageNote(_ number: Int) -> String { "notesPanel.pageNote.\(number)" }
        static let editor = "notePage.editor"
        static let text = "notePage.text"
        static let ink = "notePage.ink"
        static let writingSpace = "notePage.writingSpace"
        static let pagePill = "reader.pagePill"
        static let historyBack = "reader.toolbar.historyBack"
        static let done = "reader.toolbar.done"
        static let divider = "reader.notesDivider"
        static let notesSheet = "reader.pane.notesSheet"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(fresh: Bool, page: Int, tab: String = "page", extra: [String] = [],
                        orientation: UIDeviceOrientation = .landscapeLeft) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let arguments = ["-openBook", "small", "-openPage", "\(page)", "-notesPanel", tab] + extra
        let app: XCUIApplication
        if fresh {
            app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + arguments)
        } else {
            app = XCUIApplication()
            app.launchArguments = arguments
            app.launch()
        }
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "reader open")
        return app
    }

    private func textView(_ app: XCUIApplication) -> XCUIElement { app.textViews[ID.text].firstMatch }
    private func editor(_ app: XCUIApplication) -> XCUIElement { app.otherElements[ID.editor].firstMatch }
    private func ink(_ app: XCUIApplication) -> XCUIElement { editor(app).images[ID.ink].firstMatch }
    private func writingSpace(_ app: XCUIApplication) -> XCUIElement { editor(app).otherElements[ID.writingSpace].firstMatch }
    private func title(_ app: XCUIApplication) -> XCUIElement { app.staticTexts[ID.title].firstMatch }
    private func status(_ app: XCUIApplication) -> XCUIElement { app.staticTexts[ID.status].firstMatch }
    private func zoom(_ app: XCUIApplication) -> XCUIElement { app.buttons[ID.zoom].firstMatch }
    private func pill(_ app: XCUIApplication) -> XCUIElement { app.buttons[ID.pagePill].firstMatch }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.segmentedControls[ID.tabs].buttons[name].firstMatch
    }

    private func button(_ app: XCUIApplication, _ identifier: String, label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)).firstMatch
    }

    private func wait(_ element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func type(_ app: XCUIApplication, _ text: String) {
        XCTAssertTrue(textView(app).waitForExistence(timeout: 10), "note text view")
        textView(app).tap()
        textView(app).typeText(text)
        XCTAssertTrue(wait(textView(app), "value CONTAINS %@", text), "typed")
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"), "saved")
    }

    /// Goes to a page with the page pill's field (a jump).
    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        pill(app).tap()
        let field = app.textFields["reader.goToPageField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "go-to-page field")
        app.typeText("\(number)\n")
        XCTAssertTrue(wait(pill(app), "label == %@", "Page \(number) of 12"), "on page \(number)")
    }

    /// Dismisses the software keyboard with its own key (no-op with a hardware keyboard).
    private func hideKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let hide = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hide keyboard' OR identifier CONTAINS[c] 'dismiss'")).firstMatch
        if hide.exists { hide.tap() }
        _ = keyboard.waitForNonExistence(timeout: 5)
    }

    private func divider(_ app: XCUIApplication) -> XCUIElement {
        for query in [app.sliders, app.otherElements] where query[ID.divider].exists {
            return query[ID.divider].firstMatch
        }
        return app.descendants(matching: .any)[ID.divider].firstMatch
    }

    private func dragDivider(_ app: XCUIApplication, by dx: CGFloat) {
        let handle = divider(app)
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "notes divider")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: 300, thenHoldForDuration: 0.3)
    }

    /// A point on the note page in note-page points from its top-left (any zoom).
    private func pagePoint(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let scale = textView(app).frame.width / 320
        return textView(app).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x * scale, dy: y * scale))
    }

    private func drawLine(_ app: XCUIApplication, y: CGFloat, from x0: CGFloat = 40, to x1: CGFloat = 220) {
        pagePoint(app, x: x0, y: y).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: x1, y: y + 3))
    }

    private func percent(_ app: XCUIApplication) -> Int {
        let label = zoom(app).label  // "Note zoom, 140 percent"
        return Int(label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }

    // MARK: Tests

    /// A page note and a section note survive scrolling away and back, and a relaunch.
    func testPageAndSectionNotesSurviveScrollingAndRelaunch() {
        let app = launch(fresh: true, page: 3)
        XCTAssertTrue(wait(title(app), "label == %@", "Page 3"))
        type(app, "Page three note")

        tab(app, "Section note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        XCTAssertTrue(wait(status(app), "label == %@", "Empty"), "an empty placeholder, not a record")
        type(app, "Foundations note")

        goToPage(app, 9)
        XCTAssertTrue(wait(title(app), "label == %@", "3 Eigenvalues"), "the section tab follows the page")
        XCTAssertEqual((textView(app).value as? String) ?? "", "")
        goToPage(app, 3)
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        XCTAssertTrue(wait(textView(app), "value == %@", "Foundations note"))
        tab(app, "Page note").tap()
        XCTAssertTrue(wait(textView(app), "value == %@", "Page three note"))
        app.terminate()

        let again = launch(fresh: false, page: 3, tab: "section")
        XCTAssertTrue(wait(title(again), "label == %@", "1.1 Foundations"))
        XCTAssertTrue(wait(textView(again), "value == %@", "Foundations note"))
        tab(again, "Page note").tap()
        XCTAssertTrue(wait(textView(again), "value == %@", "Page three note"))
    }

    /// From a page inside a subsection, the chapter's note is one tap up in the level picker, and
    /// the choice stays while the reader scrolls within the chapter.
    func testChapterNoteIsReachableThroughTheLevelPicker() {
        let app = launch(fresh: true, page: 3, tab: "section")
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        let chapter = button(app, ID.level, label: "1 Linear Systems")
        XCTAssertTrue(chapter.waitForExistence(timeout: 5), "the chapter in the level picker")
        XCTAssertTrue(button(app, ID.level, label: "1.1 Foundations").isSelected)
        chapter.tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"))
        type(app, "Chapter one note")

        goToPage(app, 4)  // 1.2 Exercises, still in chapter 1
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"), "the chosen level stays")
        XCTAssertTrue(wait(textView(app), "value == %@", "Chapter one note"))
        goToPage(app, 6)  // chapter 2: following again
        XCTAssertTrue(wait(title(app), "label == %@", "2.1 Foundations"))
    }

    /// A page note inside a section is listed under "Page notes in this section"; tapping it jumps
    /// there and the jump is recorded in section history.
    func testPageNoteIsListedInItsSectionAndTappingItJumps() {
        let app = launch(fresh: true, page: 3)
        type(app, "Foundations detail")
        goToPage(app, 1)
        tab(app, "Section note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"))
        let row = app.buttons[ID.pageNote(3)].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "page 3's note under chapter 1")
        XCTAssertEqual(row.value as? String, "Foundations detail")
        row.tap()
        XCTAssertTrue(wait(pill(app), "label == %@", "Page 3 of 12"), "jumped to the page")
        XCTAssertTrue(waitForEnabled(app.buttons[ID.historyBack].firstMatch), "the jump is in section history")
    }

    /// Widening the pane zooms the note without re-wrapping it; the shrink button restores both.
    func testWideningZoomsTheNoteAndShrinkRestoresIt() {
        let app = launch(fresh: true, page: 3)
        type(app, "A paragraph long enough to wrap onto several lines of the note page, so a reflow would show")
        XCTAssertEqual(percent(app), 100)
        let width = textView(app).frame.width
        let textHeight = writingSpace(app).frame.minY - textView(app).frame.minY
        let ratio = textHeight / width
        XCTAssertGreaterThan(textHeight / (width / 320), 14 + 2 * 22, "the paragraph wraps onto three lines")

        dragDivider(app, by: -220)
        XCTAssertTrue(app.buttons[ID.shrink].firstMatch.waitForExistence(timeout: 5), "shrink button while widened")
        let wideZoom = percent(app)
        XCTAssertGreaterThan(wideZoom, 140, "the note zoomed with the wider pane")
        let wideWidth = textView(app).frame.width
        XCTAssertEqual(wideWidth / width, CGFloat(wideZoom) / 100, accuracy: 0.03)
        let wideRatio = (writingSpace(app).frame.minY - textView(app).frame.minY) / wideWidth
        XCTAssertEqual(wideRatio, ratio, accuracy: 0.004, "same line breaks: the text block scaled, not reflowed")

        app.buttons[ID.shrink].firstMatch.tap()
        XCTAssertTrue(wait(zoom(app), "label == %@", "Note zoom, 100 percent"))
        XCTAssertEqual(textView(app).frame.width, width, accuracy: 1)
        XCTAssertFalse(app.buttons[ID.shrink].firstMatch.exists)
    }

    /// Narrow window: the sheet (iPadOS 26+) or bottom panel (earlier) shows the same panel.
    func testNarrowLayoutShowsTheSamePanel() throws {
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(fresh: true, page: 3, orientation: .portrait)
        XCTAssertTrue(app.otherElements[ID.notesSheet].firstMatch.waitForExistence(timeout: 10)
                      || app.descendants(matching: .any)[ID.notesSheet].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(title(app), "label == %@", "Page 3"))
        XCTAssertTrue(tab(app, "Section note").exists)
        XCTAssertTrue(zoom(app).exists)
        type(app, "Narrow page note")
        hideKeyboard(app)
        let section = button(app, ID.pageIsIn, label: "Section note for 1.1 Foundations")
        XCTAssertTrue(section.waitForExistence(timeout: 5), "This page is in")
        XCTAssertTrue(wait(section, "isHittable == true", "", timeout: 5) || section.isHittable, "below the note")
        try saveScreenshot("wp8-narrow-page")
        section.tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        XCTAssertTrue(tab(app, "Section note").isSelected)
        try saveScreenshot("wp8-narrow-section")
    }

    /// Markup mode: a finger stroke (`-inkAnyInput`) on the page note survives a tab switch and a
    /// relaunch.
    func testMarkupStrokeSurvivesTabSwitchAndRelaunch() {
        let app = launch(fresh: true, page: 3, extra: ["-markup", "-inkAnyInput"])
        XCTAssertTrue(textView(app).waitForExistence(timeout: 10))
        drawLine(app, y: 160)
        XCTAssertTrue(ink(app).waitForExistence(timeout: 5), "stroke drawn")
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"))

        tab(app, "Section note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        XCTAssertTrue(ink(app).waitForNonExistence(timeout: 5), "the section note has no ink")
        tab(app, "Page note").tap()
        XCTAssertTrue(ink(app).waitForExistence(timeout: 5), "the stroke is back")
        XCTAssertEqual(ink(app).value as? String, "1 stroke")
        app.terminate()

        let again = launch(fresh: false, page: 3)
        XCTAssertTrue(ink(again).waitForExistence(timeout: 10), "the stroke after relaunch")
        XCTAssertEqual(ink(again).value as? String, "1 stroke")
    }

    /// Not a check: seeds notes and saves the WP8 screenshots (`build/shots/wp8-*-ios<major>.png`):
    /// the widened panel in markup mode, the page note, and the section note with its level picker
    /// and page notes drawn with ink.
    func testScreenshots() throws {
        let seed = launch(fresh: true, page: 2)
        type(seed, "Motivation: guessing a solution does not scale past 2 x 2.")
        goToPage(seed, 3)
        type(seed, "Why elimination works\nEach row operation is invertible, so the solution set never changes.\n- Pivot columns = basic variables")
        seed.terminate()

        let app = launch(fresh: false, page: 3, extra: ["-markup", "-inkAnyInput"])
        XCTAssertTrue(wait(textView(app), "value BEGINSWITH %@", "Why elimination"))
        drawLine(app, y: 14 + 28 + 22 + 11, from: 150, to: 290)
        pagePoint(app, x: 60, y: 260).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: 260, y: 300))
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"))
        dragDivider(app, by: -260)
        if !wait(title(app), "label == %@", "Page 3", timeout: 2) { goToPage(app, 3) }
        sleep(2)
        try saveScreenshot("wp8-markup-wide")
        app.buttons[ID.shrink].firstMatch.tap()
        app.buttons[ID.done].firstMatch.tap()
        if !wait(title(app), "label == %@", "Page 3", timeout: 2) { goToPage(app, 3) }
        sleep(1)
        try saveScreenshot("wp8-page")

        tab(app, "Section note").tap()
        button(app, ID.level, label: "1 Linear Systems").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"))
        type(app, "Big idea: a linear system is one matrix equation Ax = b.")
        hideKeyboard(app)
        XCTAssertTrue(app.buttons[ID.pageNote(3)].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"))
        sleep(2)
        try saveScreenshot("wp8-section")
    }

    // MARK: Screenshots

    /// Saves a screenshot to `build/shots/<name>-ios<major>.png` (and attaches it).
    private func saveScreenshot(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let version = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "os"
        try upright(shot.image).write(to: directory.appendingPathComponent("\(name)-ios\(version).png"))
    }

    /// The screenshot in the interface's orientation (the raw capture is always portrait).
    private func upright(_ image: UIImage) throws -> Data {
        guard let cgImage = image.cgImage, cgImage.height > cgImage.width,
              XCUIDevice.shared.orientation.isLandscape else {
            return try XCTUnwrap(image.pngData())
        }
        let size = CGSize(width: cgImage.height, height: cgImage.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rotated = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.rotate(by: -.pi / 2)
            UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: size.height, height: size.width))
        }
        return try XCTUnwrap(rotated.pngData())
    }
}
