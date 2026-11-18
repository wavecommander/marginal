import XCTest

/// The notes panel on `small.pdf` (12 pages; "1 Linear Systems" p1 with "1.1 Foundations"
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
        static let shrink = "notesPanel.shrink"
        static let lowerRegionToggle = "notesPanel.lowerRegionToggle"
        static let markup = "notesPanel.markup"
        static let undo = "notesPanel.undo"
        static let redo = "notesPanel.redo"
        static let levelToggle = "notesPanel.levelToggle"
        static let level = "notesPanel.level"
        static let highlight = "notesPanel.highlight"
        static let openNotebook = "notesPanel.openNotebook"
        static let addHeading = "notesPanel.addHeading"
        static let editor = "notePage.editor"
        static let text = "notePage.text"
        static let ink = "notePage.ink"
        static let writingSpace = "notePage.writingSpace"
        static let pagePill = "reader.pagePill"
        static let divider = "reader.notesDivider"
        static let notesSheet = "reader.pane.notesSheet"
        static let pdfView = "reader.pdfView"
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
            app.launchArguments = ["-pagePillStaysVisible"] + arguments
            app.launch()
        }
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "reader open")
        return app
    }

    /// `no-outline.pdf` with the Notebook's debug seed (user headings "5 Eigenvalues and
    /// Eigenvectors" p15 › "5.1 Invariant Directions" p16 and "5.2 The Characteristic Equation"
    /// p23; highlights on pp. 4, 10, 19, 25 and 29; page notes on 17 and 25). The seed is applied
    /// when the Notebook first appears, so this opens it once, then relaunches into the reader.
    private func launchSeeded(page: Int, tab: String = "page", extra: [String] = [],
                              orientation: UIDeviceOrientation = .landscapeLeft) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let seed = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
                                               + ["-screen", "notebook", "-seedNotebook", "-seedNotebookPageInk"])
        XCTAssertTrue(seed.buttons["notebook.header.3 Matrices and Linear Maps"].firstMatch.waitForExistence(timeout: 30),
                      "seeded")
        sleep(1)
        seed.terminate()
        let app = XCUIApplication()
        app.launchArguments = ["-pagePillStaysVisible", "-openBook", "no-outline", "-openPage", "\(page)", "-notesPanel", tab] + extra
        app.launch()
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "reader open")
        return app
    }

    private func textView(_ app: XCUIApplication) -> XCUIElement { app.textViews[ID.text].firstMatch }
    private func editor(_ app: XCUIApplication) -> XCUIElement { app.otherElements[ID.editor].firstMatch }
    private func ink(_ app: XCUIApplication) -> XCUIElement { editor(app).images[ID.ink].firstMatch }
    private func writingSpace(_ app: XCUIApplication) -> XCUIElement { editor(app).otherElements[ID.writingSpace].firstMatch }
    private func title(_ app: XCUIApplication) -> XCUIElement { app.staticTexts[ID.title].firstMatch }
    private func status(_ app: XCUIApplication) -> XCUIElement { app.staticTexts[ID.status].firstMatch }
    private func pill(_ app: XCUIApplication) -> XCUIElement { app.buttons[ID.pagePill].firstMatch }
    private func levelToggle(_ app: XCUIApplication) -> XCUIElement { app.buttons[ID.levelToggle].firstMatch }
    private func levels(_ app: XCUIApplication) -> XCUIElementQuery { app.buttons.matching(identifier: ID.level) }

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
    private func goToPage(_ app: XCUIApplication, _ number: Int, of count: Int = 12) {
        pill(app).tap()
        let field = app.textFields["reader.goToPageField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "go-to-page field")
        app.typeText("\(number)\n")
        XCTAssertTrue(wait(pill(app), "label == %@", "Page \(number) of \(count)"), "on page \(number)")
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

    /// A point on the note page in note-page points from its top-left (any zoom, any page width).
    private func pagePoint(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let scale = CGFloat(percent(app)) / 100
        return textView(app).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x * scale, dy: y * scale))
    }

    private func drawLine(_ app: XCUIApplication, y: CGFloat, from x0: CGFloat = 40, to x1: CGFloat = 220) {
        pagePoint(app, x: x0, y: y).press(forDuration: 0.2, thenDragTo: pagePoint(app, x: x1, y: y + 3))
    }

    /// The note's zoom in whole percent (the editor's accessibility value, "100%"). The page's
    /// width on screen does not tell it: a widened pane widens the page (TSOFT-226).
    private func percent(_ app: XCUIApplication) -> Int {
        Int(((editor(app).value as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? -1
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

    /// The level picker sits at the bottom of the Section tab, under the note and above "Open in
    /// Notebook", collapsed to one row naming the shown heading. Expanded, it lists the heading
    /// path; the chapter's note is one tap up, and the choice stays while the reader scrolls and
    /// moves within the chapter.
    func testChapterNoteIsReachableThroughTheLevelPicker() {
        let app = launch(fresh: true, page: 3, tab: "section")
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        let toggle = levelToggle(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the level picker")
        XCTAssertEqual(toggle.label, "Heading level, 1.1 Foundations", "names the shown heading")
        XCTAssertEqual(toggle.value as? String, "Collapsed", "starts collapsed")
        XCTAssertEqual(levels(app).count, 0, "collapsed: one row")
        XCTAssertGreaterThanOrEqual(toggle.frame.minY, editor(app).frame.maxY - 1, "under the note")
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)

        toggle.tap()
        XCTAssertTrue(wait(toggle, "value == %@", "Expanded"))
        let chapter = button(app, ID.level, label: "1 Linear Systems")
        XCTAssertTrue(chapter.waitForExistence(timeout: 5), "the chapter in the level picker")
        XCTAssertEqual(levels(app).count, 2, "the heading path, shallowest first")
        XCTAssertLessThan(chapter.frame.minY, button(app, ID.level, label: "1.1 Foundations").frame.minY)
        XCTAssertTrue(button(app, ID.level, label: "1.1 Foundations").isSelected, "the shown heading is marked")
        XCTAssertFalse(chapter.isSelected)
        XCTAssertEqual(chapter.value as? String, "Level 1")
        chapter.tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"))
        XCTAssertTrue(wait(toggle, "label == %@", "Heading level, 1 Linear Systems"))
        XCTAssertTrue(button(app, ID.level, label: "1 Linear Systems").isSelected)
        type(app, "Chapter one note")
        hideKeyboard(app)
        XCTAssertTrue(wait(button(app, ID.level, label: "1 Linear Systems"), "value == %@", "Level 1, has a note"),
                      "a mark on the level that has a note")

        // Scrolling the PDF a little (still in chapter 1) keeps the chosen level.
        let pdf = app.otherElements[ID.pdfView].firstMatch
        let start = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
        sleep(1)
        XCTAssertTrue(["Page 3 of 12", "Page 4 of 12"].contains(pill(app).label), pill(app).label)
        XCTAssertEqual(title(app).label, "1 Linear Systems", "the chosen level stays while scrolling")
        goToPage(app, 4)  // 1.2 Exercises, still in chapter 1
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"), "the chosen level stays")
        XCTAssertTrue(wait(textView(app), "value == %@", "Chapter one note"))
        goToPage(app, 6)  // chapter 2: following again
        XCTAssertTrue(wait(title(app), "label == %@", "2.1 Foundations"))
        XCTAssertTrue(wait(toggle, "label == %@", "Heading level, 2.1 Foundations"))
    }

    /// The level picker's expanded or collapsed state is remembered across launches.
    func testLevelPickerStateIsRememberedAcrossLaunches() {
        let app = launch(fresh: true, page: 6, tab: "section")
        XCTAssertTrue(wait(title(app), "label == %@", "2.1 Foundations"))
        XCTAssertTrue(levelToggle(app).waitForExistence(timeout: 5))
        XCTAssertEqual(levelToggle(app).value as? String, "Collapsed")
        levelToggle(app).tap()
        XCTAssertTrue(wait(levelToggle(app), "value == %@", "Expanded"))
        app.terminate()

        let expanded = launch(fresh: false, page: 6, tab: "section")
        XCTAssertTrue(levelToggle(expanded).waitForExistence(timeout: 10))
        XCTAssertEqual(levelToggle(expanded).value as? String, "Expanded", "remembered")
        XCTAssertTrue(button(expanded, ID.level, label: "2 Vector Spaces").waitForExistence(timeout: 5))
        levelToggle(expanded).tap()
        XCTAssertTrue(wait(levelToggle(expanded), "value == %@", "Collapsed"))
        XCTAssertTrue(button(expanded, ID.level, label: "2 Vector Spaces").waitForNonExistence(timeout: 5))
        expanded.terminate()

        let collapsed = launch(fresh: false, page: 6, tab: "section")
        XCTAssertTrue(levelToggle(collapsed).waitForExistence(timeout: 10))
        XCTAssertEqual(levelToggle(collapsed).value as? String, "Collapsed", "remembered")
        XCTAssertEqual(levels(collapsed).count, 0)
    }

    /// The Page note tab holds the note and, only while the page has highlights, "Highlights on
    /// this page" under it. With none, the note reaches the bottom of the panel. There is no
    /// level picker or "This page is in" list on this tab.
    func testPageTabShowsHighlightsOnlyWhenThePageHasThem() {
        let app = launchSeeded(page: 25)
        XCTAssertTrue(wait(title(app), "label == %@", "Page 25"))
        let highlight = app.buttons[ID.highlight].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 10), "p. 25's highlights")
        XCTAssertEqual(app.buttons.matching(identifier: ID.highlight).count, 2)
        XCTAssertGreaterThanOrEqual(highlight.frame.minY, editor(app).frame.maxY - 1, "under the note")
        XCTAssertFalse(levelToggle(app).exists)
        XCTAssertFalse(app.staticTexts["This page is in"].exists)
        let listBottom = app.buttons.matching(identifier: ID.highlight).element(boundBy: 1).frame.maxY

        goToPage(app, 17, of: 40)  // a page note, no highlights
        XCTAssertTrue(wait(title(app), "label == %@", "Page 17"))
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5), "no highlights, no list")
        XCTAssertFalse(app.staticTexts["Highlights on this page"].exists)
        XCTAssertGreaterThanOrEqual(editor(app).frame.maxY, listBottom - 1,
                                    "the note takes the space the list had: no divider, no empty region")
    }

    /// Widening the pane widens the note page without zooming it: the text keeps its size and
    /// re-wraps onto fewer lines (TSOFT-226). The shrink button restores the page and its lines.
    func testWideningGrowsTheNoteWithoutZoomingAndShrinkRestoresIt() {
        let app = launch(fresh: true, page: 3)
        type(app, "A paragraph long enough to wrap onto several lines of the note page, so a reflow would show")
        XCTAssertEqual(percent(app), 100)
        let width = textView(app).frame.width
        XCTAssertEqual(width, 320, accuracy: 1)
        let textHeight = writingSpace(app).frame.minY - textView(app).frame.minY
        XCTAssertGreaterThan(textHeight, 14 + 2 * 22, "the paragraph wraps onto three lines")
        let paneLeft = divider(app).frame.midX

        dragDivider(app, by: -220)
        XCTAssertTrue(app.buttons[ID.shrink].firstMatch.waitForExistence(timeout: 5), "shrink button while widened")
        XCTAssertLessThan(divider(app).frame.midX, paneLeft - 100, "the pane widened")
        XCTAssertEqual(percent(app), 100, "the note did not zoom")
        XCTAssertGreaterThan(textView(app).frame.width, width + 150, "the note page grew with the pane")
        XCTAssertLessThan(writingSpace(app).frame.minY - textView(app).frame.minY, textHeight - 10,
                          "same text size, re-wrapped onto fewer lines")

        app.buttons[ID.shrink].firstMatch.tap()
        for _ in 0..<20 where abs(textView(app).frame.width - width) > 1 { usleep(250_000) }
        XCTAssertEqual(percent(app), 100)
        XCTAssertEqual(textView(app).frame.width, width, accuracy: 1)
        XCTAssertEqual(writingSpace(app).frame.minY - textView(app).frame.minY, textHeight, accuracy: 1,
                       "the default line breaks are back")
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
        type(app, "Narrow page note")
        hideKeyboard(app)
        try saveScreenshot("wp8-narrow-page")
        tab(app, "Section note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        let toggle = levelToggle(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the level picker")
        XCTAssertTrue(wait(toggle, "isHittable == true", "", timeout: 5) || toggle.isHittable, "below the note")
        toggle.tap()
        let chapter = button(app, ID.level, label: "1 Linear Systems")
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        try saveScreenshot("wp8-narrow-section")
        chapter.tap()
        XCTAssertTrue(wait(title(app), "label == %@", "1 Linear Systems"))
    }

    /// Narrow sheet: the header's button hides the lists under the note and shows them again,
    /// and the choice is still there after a relaunch. A regular-size iPad window keeps Markup
    /// in the toolbar only (the header's own Markup button is for compact screens). The note
    /// page's widening in a two-column sheet is pinned in `NotesPanelRulesTests`.
    func testNarrowSheetHidesAndShowsTheLists() {
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        var app = launch(fresh: true, page: 3, tab: "section", orientation: .portrait)
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        XCTAssertTrue(levelToggle(app).waitForExistence(timeout: 5), "the level picker, under the note")
        var hide = app.buttons[ID.lowerRegionToggle].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(hide, "label == %@", "Hide Section Levels"))
        XCTAssertFalse(app.buttons[ID.markup].firstMatch.exists, "Markup stays in the toolbar at regular size")

        hide.tap()
        XCTAssertTrue(levelToggle(app).waitForNonExistence(timeout: 5), "the lists are hidden")
        XCTAssertTrue(wait(hide, "label == %@", "Show Section Levels"))

        app.terminate()
        app = launch(fresh: false, page: 3, tab: "section", orientation: .portrait)
        XCTAssertTrue(wait(title(app), "label == %@", "1.1 Foundations"))
        hide = app.buttons[ID.lowerRegionToggle].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 10))
        XCTAssertEqual(hide.label, "Show Section Levels", "the choice is remembered")
        XCTAssertFalse(levelToggle(app).exists)

        hide.tap()
        XCTAssertTrue(levelToggle(app).waitForExistence(timeout: 5), "and shown again")
    }

    /// On a phone, the notes sheet hides its own Markup and ink Undo/Redo buttons at the medium
    /// detent and shows them only when expanded to full screen (the large detent in portrait, or
    /// landscape where the sheet takes the whole screen).
    func testPhoneNotesSheetShowsMarkupControlsOnlyWhenFullScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("full-screen sheet markup controls are for compact windows")
        }
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(fresh: true, page: 3, orientation: .portrait)
        let sheet = app.descendants(matching: .any)[ID.notesSheet].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "notes sheet at medium detent")
        let markup = app.buttons[ID.markup].firstMatch
        let undo = app.buttons[ID.undo].firstMatch
        let redo = app.buttons[ID.redo].firstMatch
        XCTAssertFalse(markup.exists, "Markup button is hidden at medium detent")
        XCTAssertFalse(undo.exists, "Undo is hidden at medium detent")
        XCTAssertFalse(redo.exists, "Redo is hidden at medium detent")

        // Drag the sheet up to the large (full-screen) detent.
        let tabs = app.segmentedControls[ID.tabs].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        let topGrab = tabs.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.4))
        topGrab.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        XCTAssertTrue(markup.waitForExistence(timeout: 5), "Markup button appears when expanded to full screen")

        markup.tap()
        XCTAssertTrue(wait(markup, "label == %@", "Done with Markup"))
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo appears in markup mode at full screen")
        XCTAssertTrue(redo.exists, "Redo appears in markup mode at full screen")

        // Collapse back to the medium detent: markup controls hide again.
        let expandedGrab = tabs.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.4))
        expandedGrab.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(markup.waitForNonExistence(timeout: 5), "Markup button hides at medium detent")
        XCTAssertFalse(undo.exists, "Undo hides at medium detent")
        XCTAssertFalse(redo.exists, "Redo hides at medium detent")

        // In landscape the sheet always takes the full screen, so the controls appear.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(markup.waitForExistence(timeout: 5), "Markup button appears in full-screen landscape sheet")
        XCTAssertTrue(undo.exists, "Undo appears in landscape markup mode")
        XCTAssertTrue(redo.exists, "Redo appears in landscape markup mode")
    }

    /// Delete Note: disabled on an empty note; deleting asks first, leaves the placeholder, and the
    /// note is still gone after a relaunch.
    func testDeleteNoteFromTheHeader() {
        let app = launch(fresh: true, page: 3)
        let delete = app.buttons["notes.deleteNote"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        XCTAssertFalse(delete.isEnabled, "nothing to delete on an empty note")
        type(app, "Delete me")
        XCTAssertTrue(waitForEnabled(delete))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "asks first")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "highlights are not affected"))
                      .firstMatch.exists, "says what stays")
        alert.buttons["Delete"].tap()
        XCTAssertTrue(wait(status(app), "label == %@", "Empty"), "the placeholder")
        XCTAssertEqual((textView(app).value as? String) ?? "", "")
        XCTAssertTrue(wait(delete, "isEnabled == false", ""))
        app.terminate()

        let again = launch(fresh: false, page: 3)
        XCTAssertTrue(wait(status(again), "label == %@", "Empty"), "still gone")
        XCTAssertEqual((textView(again).value as? String) ?? "", "")
    }

    /// Deleting a note from the header shows the Undo pill; tapping it restores the note.
    func testDeleteNoteUndoPillRestoresDeletedNote() {
        let app = launch(fresh: true, page: 3)
        let delete = app.buttons["notes.deleteNote"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        type(app, "Keep me")
        XCTAssertTrue(waitForEnabled(delete))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(wait(status(app), "label == %@", "Empty"), "cleared on delete")

        let undoPill = app.buttons["notes.undoDelete"].firstMatch
        XCTAssertTrue(undoPill.waitForExistence(timeout: 5), "Undo pill appears after delete")
        undoPill.tap()

        XCTAssertTrue(wait(textView(app), "value == %@", "Keep me"), "note text restored")
        XCTAssertTrue(wait(status(app), "label == %@", "Saved"), "restored note is saved")
        XCTAssertFalse(undoPill.exists, "Undo pill goes away once tapped")

        app.terminate()
        let again = launch(fresh: false, page: 3)
        XCTAssertTrue(wait(textView(again), "value == %@", "Keep me"), "still restored after relaunch")
    }

    /// Deleting a note while in markup mode ends markup mode so the toolbar button looks inactive;
    /// cancelling keeps markup mode active.
    func testDeletingNoteInMarkupModeUpdatesMarkupButtonToInactive() {
        let app = launch(fresh: true, page: 3, extra: ["-markup", "-inkAnyInput"])
        let toolbarMarkup = app.buttons["reader.toolbar.markup"].firstMatch
        XCTAssertTrue(toolbarMarkup.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(toolbarMarkup, "label == %@", "Done with Markup"), "markup active initially")

        drawLine(app, y: 160)
        let delete = app.buttons["notes.deleteNote"].firstMatch
        XCTAssertTrue(waitForEnabled(delete))

        // Cancelling keeps markup mode active.
        delete.tap()
        let cancelAlert = app.alerts.firstMatch
        XCTAssertTrue(cancelAlert.waitForExistence(timeout: 5))
        cancelAlert.buttons["Cancel"].tap()
        XCTAssertTrue(wait(toolbarMarkup, "label == %@", "Done with Markup"), "cancelling keeps markup active")

        // Confirming delete ends markup mode so the button looks inactive.
        delete.tap()
        let deleteAlert = app.alerts.firstMatch
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 5))
        deleteAlert.buttons["Delete"].tap()
        XCTAssertTrue(wait(status(app), "label == %@", "Empty"), "note cleared on delete")
        XCTAssertTrue(wait(toolbarMarkup, "label == %@", "Markup"), "markup button looks inactive after delete")
        XCTAssertFalse(toolbarMarkup.isSelected, "no selected state on inactive markup button")
    }

    /// Swiping right on the notes pane (its header, the note page), as when a drag meant for the
    /// divider's pill misses it, never goes back to the Library: on iPadOS 26+ the navigation
    /// stack's full-width back swipe must not start there (TSOFT-225).
    func testSwipingRightOnTheNotesPaneDoesNotGoBack() {
        let app = launch(fresh: true, page: 3)
        let pane = app.otherElements["reader.pane.notes"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "notes pane")
        XCTAssertTrue(textView(app).waitForExistence(timeout: 10), "note page")

        // Drags like a finger that missed the divider's pill: from just inside the pane's
        // leading edge, from its header, from the note page. No hold before moving.
        let starts: [(String, XCUICoordinate)] = [
            ("beside the divider", pane.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.7)).withOffset(CGVector(dx: 20, dy: 0))),
            ("header", pane.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06))),
            ("note page", pane.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4))),
        ]
        for (place, start) in starts {
            start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 285, dy: 4)),
                        withVelocity: 1000, thenHoldForDuration: 0)
            sleep(2)
            XCTAssertFalse(app.buttons["library.book.small"].firstMatch.exists, "still in the reader (\(place))")
            XCTAssertTrue(pill(app).exists, "reader still open (\(place))")
            XCTAssertTrue(pane.exists, "notes pane still open (\(place))")
        }
    }

    /// A book with no outline: the Section tab's empty state offers "Add Heading at This Page…"
    /// (the Contents sidebar presents the sheet). The Page tab holds only the note.
    func testAddHeadingIsOfferedWhereThePageIsInNoSection() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
                                              + ["-openBook", "no-outline", "-openPage", "3", "-notesPanel", "section"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30), "reader open")
        let add = app.buttons[ID.addHeading].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "offered in the Section tab's empty state")
        XCTAssertFalse(textView(app).exists, "no section, so no section note")
        XCTAssertFalse(levelToggle(app).exists, "no heading, no level picker")
        tab(app, "Page note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "Page 3"))
        XCTAssertTrue(add.waitForNonExistence(timeout: 5), "the Page tab holds only the note")
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

    /// Not a check: saves the notes panel screenshots (`build/shots/wp8-*-ios<major>.png`) on the seeded
    /// book: the Page note tab with and without highlights, the Section note tab with the level
    /// picker collapsed and expanded, both tabs in the widened pane, and both in the narrow-window
    /// sheet. Appearance is the simulator's (`xcrun simctl ui <udid> appearance dark`).
    func testScreenshots() throws {
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launchSeeded(page: 25)
        XCTAssertTrue(wait(title(app), "label == %@", "Page 25"))
        XCTAssertTrue(app.buttons[ID.highlight].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        try saveScreenshot("wp8-page-highlights")
        goToPage(app, 17, of: 40)
        XCTAssertTrue(wait(title(app), "label == %@", "Page 17"))
        sleep(2)
        try saveScreenshot("wp8-page")

        goToPage(app, 25, of: 40)
        tab(app, "Section note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "5.2 The Characteristic Equation"))
        XCTAssertTrue(levelToggle(app).waitForExistence(timeout: 5))
        sleep(2)
        try saveScreenshot("wp8-section")
        levelToggle(app).tap()
        XCTAssertTrue(wait(levelToggle(app), "value == %@", "Expanded"))
        sleep(1)
        try saveScreenshot("wp8-section-levels")

        dragDivider(app, by: -260)
        XCTAssertTrue(app.buttons[ID.shrink].firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        try saveScreenshot("wp8-wide-section")
        tab(app, "Page note").tap()
        sleep(2)
        try saveScreenshot("wp8-wide-page")
        app.buttons[ID.shrink].firstMatch.tap()

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)[ID.notesSheet].firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        try saveScreenshot("wp8-sheet-page")
        tab(app, "Section note").tap()
        XCTAssertTrue(wait(title(app), "label == %@", "5.2 The Characteristic Equation"))
        sleep(2)
        try saveScreenshot("wp8-sheet-section")
        levelToggle(app).tap()  // leave it collapsed for the next run
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
