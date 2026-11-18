import UIKit
import XCTest

/// The main journey end to end, on `small.pdf` (page 3 is in "1 Linear Systems" ›
/// "1.1 Foundations"; its first body line reads "Remember that the quick amber fox annotates
/// margins."):
///
/// import → open from the Library → go to page 3 → markup on, draw on the page → markup off,
/// highlight a phrase with a finger selection → page note → markup on, ink the note → add a
/// heading of the reader's own at page 3 → section note on it → the Notebook lists the heading,
/// its note, the page note, the highlight and the Handwriting row → export Markdown and PDF →
/// relaunch: everything is still there, in the Notebook and in the reader.
///
/// Fingers draw through `-inkAnyInput`. Helpers are shared with `SidebarUITests` (heading
/// sheet) or copied from `HighlightsUITests` and `NotebookUITests` (private there).
@MainActor
final class JourneyUITests: XCTestCase {
    private enum ID {
        static let book = "library.book.small"
        static let pagePill = "reader.pagePill"
        static let pdfView = "reader.pdfView"
        static let markupToggle = "reader.toolbar.markup"
        static let more = "reader.toolbar.more"
        static let notesTabs = "notesPanel.tabs"
        static let notesTitle = "notesPanel.title"
        static let noteText = "notePage.text"
        static let noteEditor = "notePage.editor"
        static let noteInk = "notePage.ink"
        static let noteStatus = "notePage.status"
        static let export = "notebook.export"
        static let typeFilter = "notebook.typeFilter"
        static func pageInk(_ page: Int) -> String { "pageInk.ink.\(page)" }
        static func highlight(_ page: Int, _ index: Int) -> String { "reader.highlight.\(page).\(index)" }
        static func heading(_ title: String) -> String { "sidebar.heading.\(title)" }
        static func nbHeader(_ title: String) -> String { "notebook.header.\(title)" }
        static func nbHeadingNote(_ title: String) -> String { "notebook.headingNote.\(title)" }
        static func nbPageNote(_ page: Int) -> String { "notebook.pageNote.\(page)" }
        static func nbHighlight(_ page: Int, _ index: Int) -> String { "notebook.highlight.\(page).\(index)" }
        static func nbHandwriting(_ page: Int) -> String { "notebook.handwriting.\(page)" }
    }

    static let headingTitle = "Journey Heading"
    static let pageNoteText = "Journey page note"
    static let sectionNoteText = "Journey section note"
    static let phrase = "the quick amber fox annotates margins"

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: The journey

    func testMainJourneySurvivesRelaunch() throws {
        // Import, then open from the Library.
        var app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-inkAnyInput"])
        let cell = app.buttons[ID.book].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "imported book in the Library")
        cell.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "reader open")
        XCTAssertTrue(wait(pill, "label == %@", ["Page 1 of 12"]), pill.label)

        // Read: go to page 3.
        SidebarUITests.goToPage(app, 3)
        XCTAssertTrue(wait(pill, "label == %@", ["Page 3 of 12"]), pill.label)

        // Markup on; draw on the page.
        let toggle = app.buttons[ID.markupToggle].firstMatch
        toggle.tap()
        XCTAssertTrue(wait(toggle, "label == %@", ["Done with Markup"]), "markup on: \(toggle.label)")
        let pdf = app.otherElements[ID.pdfView].firstMatch
        let start = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 220, dy: 8)))
        let pageInk = pdf.images[ID.pageInk(3)].firstMatch
        XCTAssertTrue(wait(pageInk, "exists == true AND value == %@", ["1 stroke"]), "stroke on page 3")

        // Markup off (the ink saves); highlight a phrase with a finger selection.
        toggle.tap()
        XCTAssertTrue(wait(toggle, "label == %@", ["Markup"]), "markup off: \(toggle.label)")
        sleep(1)
        select(from: "the", to: "margins", onLineContaining: "amber fox", app: app)
        try chooseHighlight("Yellow", app: app)
        let highlight = app.buttons[ID.highlight(3, 0)].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 10), "highlight shown")
        XCTAssertEqual(highlight.value as? String, Self.phrase)

        // Page note (the notes panel shows by default at this width; open it if it is hidden).
        let pageTab = tab(app, "Page note")
        XCTAssertTrue(app.setPanel(.notes, shown: true), "notes panel")
        XCTAssertTrue(pageTab.waitForExistence(timeout: 10), "notes panel")
        if !pageTab.isSelected { pageTab.tap() }
        let listed = app.buttons["notesPanel.highlight"].firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10), "the highlight in Highlights on this page")
        XCTAssertEqual(listed.value as? String, Self.phrase)
        typeNote(app, Self.pageNoteText)

        // Ink the note (markup on, a finger stroke in the blank space below the text).
        toggle.tap()
        XCTAssertTrue(wait(toggle, "label == %@", ["Done with Markup"]), "markup on again")
        drawOnNote(app, y: 110)
        XCTAssertTrue(wait(noteInk(app), "exists == true AND value == %@", ["1 stroke"]), "stroke on the note")
        toggle.tap()
        XCTAssertTrue(wait(toggle, "label == %@", ["Markup"]), "markup off again")
        XCTAssertTrue(wait(app.buttons["notes.deleteNote"].firstMatch, "isEnabled == true", []), "note ink saved")
        Thread.sleep(forTimeInterval: 1.2)

        // A heading of the reader's own at page 3 (More menu), then its section note.
        let more = app.buttons[ID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let addHeading = app.buttons["Add Heading at This Page…"].firstMatch
        XCTAssertTrue(addHeading.waitForExistence(timeout: 5))
        addHeading.tap()
        SidebarUITests.fillHeadingSheet(app, title: Self.headingTitle)
        XCTAssertTrue(wait(pill, "label == %@", ["Page 3 of 12"]), "adding a heading never moves the page")
        tab(app, "Section note").tap()
        XCTAssertTrue(wait(app.staticTexts[ID.notesTitle].firstMatch, "label == %@", [Self.headingTitle]),
                      "the Section tab shows the reader's heading")
        typeNote(app, Self.sectionNoteText)

        // The Notebook (in place, from the More menu) shows each item.
        more.tap()
        let notebookItem = app.buttons["Notebook"].firstMatch
        XCTAssertTrue(notebookItem.waitForExistence(timeout: 5))
        notebookItem.tap()
        assertNotebookShowsEverything(app)

        // Export Markdown and PDF.
        export(app, "Markdown")
        export(app, "PDF")

        // Relaunch (same store): the Notebook first, then the reader from a row.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-pagePillStaysVisible", "-screen", "notebook", "-openBook", "small", "-inkAnyInput"]
        app.launch()
        assertNotebookShowsEverything(app)

        row(app, ID.nbPageNote(3)).tap()
        let pillAgain = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pillAgain.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pillAgain, "label == %@", ["Page 3 of 12"]), pillAgain.label)
        let pdfAgain = app.otherElements[ID.pdfView].firstMatch
        XCTAssertTrue(wait(pdfAgain.images[ID.pageInk(3)].firstMatch, "exists == true AND value == %@", ["1 stroke"]),
                      "page ink after relaunch")
        let highlightAgain = app.buttons[ID.highlight(3, 0)].firstMatch
        XCTAssertTrue(highlightAgain.waitForExistence(timeout: 10), "highlight after relaunch")
        XCTAssertEqual(highlightAgain.value as? String, Self.phrase)

        XCTAssertTrue(app.setPanel(.notes, shown: true), "notes panel after relaunch")
        XCTAssertTrue(tab(app, "Page note").waitForExistence(timeout: 10))
        tab(app, "Page note").tap()
        XCTAssertTrue(wait(noteText(app), "value == %@", [Self.pageNoteText]), "page note after relaunch")
        XCTAssertTrue(wait(noteInk(app), "exists == true AND value == %@", ["1 stroke"]), "note ink after relaunch")
        tab(app, "Section note").tap()
        XCTAssertTrue(wait(app.staticTexts[ID.notesTitle].firstMatch, "label == %@", [Self.headingTitle]))
        XCTAssertTrue(wait(noteText(app), "value == %@", [Self.sectionNoteText]), "section note after relaunch")

        XCTAssertTrue(app.setPanel(.contents, shown: true), "Contents after relaunch")
        SidebarUITests.selectTab(app, "Contents")
        let heading = app.buttons[ID.heading(Self.headingTitle)].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the reader's heading in Contents after relaunch")
        XCTAssertTrue((heading.value as? String ?? "").contains("your heading"), "marked as the reader's own")
    }

    // MARK: Notebook

    private func assertNotebookShowsEverything(_ app: XCUIApplication) {
        let header = row(app, ID.nbHeader(Self.headingTitle))
        XCTAssertTrue(header.waitForExistence(timeout: 30), "the reader's heading in the Notebook")
        let headingNote = row(app, ID.nbHeadingNote(Self.headingTitle))
        let pageNote = row(app, ID.nbPageNote(3))
        let highlight = row(app, ID.nbHighlight(3, 0))
        let handwriting = row(app, ID.nbHandwriting(3))
        for element in [headingNote, pageNote, highlight, handwriting] {
            XCTAssertTrue(element.waitForExistence(timeout: 15), "\(element.identifier) in the Notebook")
        }
        XCTAssertTrue(headingNote.label.contains(Self.sectionNoteText), headingNote.label)
        XCTAssertTrue(pageNote.label.contains(Self.pageNoteText), pageNote.label)
        XCTAssertTrue(pageNote.label.contains("Has handwriting"), pageNote.label)
        XCTAssertTrue(highlight.label.contains("amber fox"), highlight.label)
        XCTAssertEqual(handwriting.label, "Handwriting, page 3")
        // All under the reader's heading, in feed order.
        let order = [header, headingNote, pageNote, highlight, handwriting]
        for (upper, lower) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(upper.frame.minY, lower.frame.minY, "\(upper.identifier) above \(lower.identifier)")
        }
        // The Handwriting filter keeps the inked page only.
        let filter = app.segmentedControls[ID.typeFilter].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.buttons["Handwriting"].tap()
        XCTAssertTrue(wait(pageNote, "exists == false", []), "page notes filtered out")
        XCTAssertTrue(handwriting.exists)
        filter.buttons["All"].tap()
        XCTAssertTrue(pageNote.waitForExistence(timeout: 5))
    }

    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    /// Export from the Notebook's menu; the share sheet appears and is dismissed.
    private func export(_ app: XCUIApplication, _ format: String) {
        let menu = app.buttons[ID.export].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(menu, "isEnabled == true", []), "export enabled")
        menu.tap()
        let identifiers = ["Markdown": "notebook.export.markdown", "Markdown (ZIP)": "notebook.export.markdownZip",
                           "PDF": "notebook.export.pdf"]
        // A menu item reads as its title and its subtitle ("Markdown, Text only").
        let item = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                                                    identifiers[format] ?? format, format, format + ",")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(format) menu item")
        item.tap()
        if format == "Markdown" {
            // With a handwritten note or handwriting in the Notebook, plain Markdown first says it
            // leaves images out and offers the ZIP.
            let textOnly = app.alerts["Images Are Not Included"].buttons["Export Text Only"].firstMatch
            if textOnly.waitForExistence(timeout: 3) { textOnly.tap() }
        }
        XCTAssertTrue(waitForShareSheet(app), "share sheet for \(format)")
        let close = app.navigationBars["UIActivityContentView"].buttons.firstMatch
        if app.buttons["Close"].exists {
            app.buttons["Close"].firstMatch.tap()
        } else if close.exists, close.isHittable, close.label == "Close" {
            close.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        }
        XCTAssertTrue(wait(menu, "isEnabled == true", [], timeout: 15), "export available again after \(format)")
    }

    private func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists
                || app.cells["Save to Files"].exists || app.buttons["Save to Files"].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    // MARK: Notes panel

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.segmentedControls[ID.notesTabs].buttons[name].firstMatch
    }

    private func noteText(_ app: XCUIApplication) -> XCUIElement { app.textViews[ID.noteText].firstMatch }
    private func noteInk(_ app: XCUIApplication) -> XCUIElement {
        app.otherElements[ID.noteEditor].firstMatch.images[ID.noteInk].firstMatch
    }
    private func status(_ app: XCUIApplication) -> XCUIElement { app.staticTexts[ID.noteStatus].firstMatch }

    private func typeNote(_ app: XCUIApplication, _ text: String) {
        let view = noteText(app)
        XCTAssertTrue(view.waitForExistence(timeout: 10), "note text view")
        view.tap()
        view.typeText(text)
        XCTAssertTrue(wait(view, "value == %@", [text]), "typed \(text)")
        XCTAssertTrue(wait(app.buttons["notes.deleteNote"].firstMatch, "isEnabled == true", []), "saved \(text)")
        Thread.sleep(forTimeInterval: 1.2)
    }

    /// A horizontal finger stroke on the note page, `y` note-page points from its top.
    private func drawOnNote(_ app: XCUIApplication, y: CGFloat) {
        let view = noteText(app)
        let zoom = view.frame.width / 320
        let origin = view.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 40 * zoom, dy: y * zoom))
            .press(forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: 220 * zoom, dy: (y + 2) * zoom)))
    }

    // MARK: Highlights (as in HighlightsUITests)

    private func line(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text))
        let hittable = (0..<lines.count).map { lines.element(boundBy: $0) }.first { $0.isHittable }
        return hittable ?? lines.firstMatch
    }

    private func point(of word: String, in line: XCUIElement, app: XCUIApplication, atEnd: Bool = false) -> XCUICoordinate {
        let label = line.label as NSString
        let font = UIFont(name: "TimesNewRomanPSMT", size: 11) ?? UIFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let full = label.size(withAttributes: attributes).width
        let range = label.range(of: word)
        let before = label.substring(to: range.location).size(withAttributes: attributes).width
        let width = (word as NSString).size(withAttributes: attributes).width
        let scale = line.frame.width / max(full, 1)
        let x = line.frame.minX + (before + (atEnd ? width + 0.7 : width / 2)) * scale
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: line.frame.midY))
    }

    private func menuItem(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let button = app.buttons[label].firstMatch
            if button.exists { return button }
            let item = app.menuItems[label].firstMatch
            if item.exists { return item }
            usleep(250_000)
        } while Date() < deadline
        return nil
    }

    private func select(from first: String, to last: String, onLineContaining text: String, app: XCUIApplication) {
        let element = line(app, containing: text)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "line '\(text)' not found")
        point(of: first, in: element, app: app)
            .press(forDuration: 1.2, thenDragTo: point(of: last, in: element, app: app, atEnd: true))
        sleep(1)
    }

    private func chooseHighlight(_ colour: String, app: XCUIApplication) throws {
        guard let submenu = menuItem(app, "Highlight") else { return XCTFail("no 'Highlight' in the edit menu") }
        submenu.tap()
        guard let item = menuItem(app, colour) else { return XCTFail("no '\(colour)' in the Highlight submenu") }
        item.tap()
    }

    // MARK: Waiting

    private func wait(_ element: XCUIElement, _ format: String, _ arguments: [Any], timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
