import UIKit
import XCTest

/// Importing other formats end to end (F7), with the real converters (no `-stubConverters`).
///
/// The EPUB journey, on `Fixtures/out/small.epub` ("The Small Fixture Book": three chapters, a
/// nested table of contents with "The Lighthouse" targeted by fragment inside chapter 2, and the
/// phrase "The amber fox annotates margins." as a one-line paragraph right under that heading):
/// the Convert to PDF sheet and its EPUB block → Convert → the book in the Library → open it →
/// Contents is the EPUB's table of contents and its entries go to their pages → "Converted from
/// EPUB" in the More menu → highlight the phrase → a section note on the converted heading → the
/// Notebook lists both → back in the Library, the book's context menu says "Converted from EPUB".
///
/// The comic: `small.cbz` (five pictures stored out of order) with `-confirmConversions`, beside
/// `small.pdf`: five pages, the label for comics, and no label on the PDF.
///
/// Screenshots go to `build/shots/conversion-*.png`.
@MainActor
final class ConversionJourneyUITests: XCTestCase {
    /// Mirrors `SmallEPUB` in `Fixtures/make-fixtures.swift`.
    private enum EPUB {
        static let title = "The Small Fixture Book"
        static let chapter1 = "Chapter 1: Departure"
        static let chapter2 = "Chapter 2: The Crossing"
        static let chapter3 = "Chapter 3: Landfall"
        static let lighthouse = "The Lighthouse"
        static let log = "Keeper's Log"
        static let harbour = "The Harbour"
        static let phrase = "The amber fox annotates margins."
        static let highlighted = "amber fox annotates margins"
    }

    private enum ID {
        static let convert = "conversion.convert"
        static let epubBlock = "conversion.block.epub"
        static let commonBlock = "conversion.block.common"
        static func limitation(_ raw: String) -> String { "conversion.limitation.\(raw)" }
        static func book(_ title: String) -> String { "library.book.\(title)" }
        static let libraryConvertedFrom = "library.bookMenu.convertedFrom"
        static let readerConvertedFrom = "reader.more.convertedFrom"
        static let pagePill = "reader.pagePill"
        static let pdfView = "reader.pdfView"
        static let more = "reader.toolbar.more"
        static let notesTabs = "notesPanel.tabs"
        static let notesTitle = "notesPanel.title"
        static let noteText = "notePage.text"
        static let noteStatus = "notePage.status"
        static func highlight(_ page: Int, _ index: Int) -> String { "reader.highlight.\(page).\(index)" }
        static func nbHeader(_ title: String) -> String { "notebook.header.\(title)" }
        static func nbHeadingNote(_ title: String) -> String { "notebook.headingNote.\(title)" }
        static func nbHighlight(_ page: Int, _ index: Int) -> String { "notebook.highlight.\(page).\(index)" }
    }

    static let sectionNoteText = "Converted heading note"

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: The EPUB journey

    func testEPUBJourneyFromTheSheetToTheNotebook() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.path("small.epub")))

        // The Convert to PDF sheet, with the EPUB block.
        let convert = app.buttons[ID.convert]
        XCTAssertTrue(convert.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(any(app, ID.commonBlock).exists)
        XCTAssertTrue(any(app, ID.epubBlock).exists)
        XCTAssertTrue(app.staticTexts["small.epub"].exists, "the file is named in its block")
        let epubSentences = [
            "pageNumbersDiffer": "Page numbers won't match the print edition or other reading apps.",
            "contentsFromBook": "Contents come from the book's own table of contents.",
            "someLinksMayNotWork": "Some links inside the book may not work.",
            "mediaLeftOut": "Audio, video and interactive parts are left out.",
        ]
        for (raw, sentence) in epubSentences {
            let row = any(app, ID.limitation(raw))
            XCTAssertTrue(row.exists, "EPUB limitation \(raw)")
            XCTAssertEqual(row.label, sentence)
        }
        XCTAssertFalse(any(app, "conversion.block.comicsAndImages").exists)
        try save("conversion-journey-sheet")
        convert.tap()
        XCTAssertTrue(convert.waitForNonExistence(timeout: 10))

        // The real converter makes the book; it opens like any other.
        let cell = app.buttons[ID.book(EPUB.title)].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 120), "converted book in the Library\n\(app.debugDescription)")
        cell.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "reader open")
        XCTAssertTrue(wait(pill, "label BEGINSWITH %@", ["Page 1 of "]), pill.label)
        let pageCount = pageNumbers(pill.label)?.count ?? 0
        XCTAssertGreaterThanOrEqual(pageCount, 6, "several pages: \(pill.label)")

        // Contents is the EPUB's table of contents, nested as in its nav document.
        XCTAssertTrue(app.setPanel(.contents, shown: true), "Contents")
        SidebarUITests.selectTab(app, "Contents")
        for title in [EPUB.chapter1, EPUB.chapter2, EPUB.chapter3] {
            XCTAssertTrue(SidebarUITests.heading(app, title).waitForExistence(timeout: 10), "\(title) in Contents")
        }
        reveal(app, EPUB.lighthouse, under: EPUB.chapter2)
        reveal(app, EPUB.log, under: EPUB.lighthouse)
        reveal(app, EPUB.harbour, under: EPUB.chapter1)
        XCTAssertLessThan(SidebarUITests.heading(app, EPUB.chapter1).frame.minY, SidebarUITests.heading(app, EPUB.harbour).frame.minY)
        XCTAssertLessThan(SidebarUITests.heading(app, EPUB.chapter2).frame.minY, SidebarUITests.heading(app, EPUB.lighthouse).frame.minY)
        XCTAssertLessThan(SidebarUITests.heading(app, EPUB.lighthouse).frame.minY, SidebarUITests.heading(app, EPUB.log).frame.minY)
        XCTAssertLessThan(SidebarUITests.heading(app, EPUB.log).frame.minY, SidebarUITests.heading(app, EPUB.chapter3).frame.minY)
        try save("conversion-journey-contents")

        // Each entry goes to its page: the heading's text is on the page shown, and the pages
        // run in book order. "The Lighthouse" is a fragment target in the middle of chapter 2.
        let chapter3Page = try jump(app, to: EPUB.chapter3)
        let chapter2Page = try jump(app, to: EPUB.chapter2)
        let lighthousePage = try jump(app, to: EPUB.lighthouse)
        XCTAssertLessThan(1, chapter2Page)
        XCTAssertLessThan(chapter2Page, lighthousePage, "the fragment target is inside chapter 2, past its first page")
        XCTAssertLessThan(lighthousePage, chapter3Page)
        XCTAssertLessThanOrEqual(chapter3Page, pageCount)

        // The More menu says where the book came from.
        let more = app.buttons[ID.more].firstMatch
        more.tap()
        let readerLabel = convertedFrom(app, ID.readerConvertedFrom)
        XCTAssertTrue(readerLabel.waitForExistence(timeout: 5), "Converted from in the More menu\n\(app.debugDescription)")
        XCTAssertTrue(readerLabel.label.contains("Converted from EPUB"), readerLabel.label)
        XCTAssertFalse(readerLabel.isEnabled, "information only")
        try save("conversion-reader-more-menu")
        dismissMenu(app)

        // Highlight the phrase (one line, right under the heading) with a finger selection.
        select(from: "amber", to: "margins", onLineContaining: "amber fox", app: app)
        try chooseHighlight("Yellow", app: app)
        let highlight = app.buttons[ID.highlight(lighthousePage, 0)].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 10), "highlight shown on page \(lighthousePage)\n\(app.debugDescription)")
        XCTAssertEqual(highlight.value as? String, EPUB.highlighted)

        // A section note on the converted heading.
        let sectionTab = tab(app, "Section note")
        XCTAssertTrue(app.setPanel(.notes, shown: true), "notes panel")
        XCTAssertTrue(sectionTab.waitForExistence(timeout: 10), "notes panel")
        sectionTab.tap()
        XCTAssertTrue(wait(app.staticTexts[ID.notesTitle].firstMatch, "label == %@", [EPUB.lighthouse]),
                      "the Section tab shows the converted heading: \(app.staticTexts[ID.notesTitle].firstMatch.label)")
        typeNote(app, Self.sectionNoteText)

        // The Notebook lists the heading, its note and the highlight under it.
        more.tap()
        let notebookItem = app.buttons["Notebook"].firstMatch
        XCTAssertTrue(notebookItem.waitForExistence(timeout: 5))
        notebookItem.tap()
        let header = app.buttons[ID.nbHeader(EPUB.lighthouse)].firstMatch
        let headingNote = app.buttons[ID.nbHeadingNote(EPUB.lighthouse)].firstMatch
        let listed = app.buttons[ID.nbHighlight(lighthousePage, 0)].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30), "the converted heading in the Notebook\n\(app.debugDescription)")
        XCTAssertTrue(headingNote.waitForExistence(timeout: 10), "its note in the Notebook")
        XCTAssertTrue(listed.waitForExistence(timeout: 10), "the highlight in the Notebook")
        XCTAssertTrue(headingNote.label.contains(Self.sectionNoteText), headingNote.label)
        XCTAssertTrue(listed.label.contains("amber fox"), listed.label)
        XCTAssertLessThan(header.frame.minY, headingNote.frame.minY)
        XCTAssertLessThan(headingNote.frame.minY, listed.frame.minY)
        try save("conversion-journey-notebook")

        // Back in the Library, the context menu says "Converted from EPUB".
        backToLibrary(app)
        openContextMenu(app, of: EPUB.title)
        let libraryLabel = convertedFrom(app, ID.libraryConvertedFrom)
        XCTAssertTrue(libraryLabel.waitForExistence(timeout: 5), "Converted from in the context menu\n\(app.debugDescription)")
        XCTAssertTrue(libraryLabel.label.contains("Converted from EPUB"), libraryLabel.label)
        XCTAssertFalse(libraryLabel.isEnabled, "information only")
        try save("conversion-library-context-menu")
    }

    // MARK: The comic

    func testComicImportsWithItsPagesAndLabel() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.path("small.cbz"))
                                              + XCUIApplication.importing(Fixtures.small) + ["-confirmConversions"])
        let comic = app.buttons[ID.book("small")].firstMatch
        XCTAssertTrue(comic.waitForExistence(timeout: 60), app.debugDescription)
        // Both fixtures are called "small"; the PDF's title is its file name too, so tell them
        // apart by page count.
        let cells = app.buttons.matching(identifier: ID.book("small"))
        XCTAssertTrue(waitForCount(cells, 2, timeout: 60), "the comic and the PDF\n\(app.debugDescription)")
        let comicCell = try XCTUnwrap(cells.allElementsBoundByIndex.first { $0.label.contains("5 pages") },
                                      cells.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        let pdfCell = try XCTUnwrap(cells.allElementsBoundByIndex.first { $0.label.contains("12 pages") })
        XCTAssertFalse(app.buttons[ID.convert].exists, "-confirmConversions: no sheet")

        // The comic's menu says where it came from; the PDF's says nothing.
        openContextMenu(comicCell)
        let label = convertedFrom(app, ID.libraryConvertedFrom)
        XCTAssertTrue(label.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(label.label.contains("Converted from a comic archive"), label.label)
        try save("conversion-comic-context-menu")
        dismissMenu(app)
        openContextMenu(pdfCell)
        XCTAssertTrue(app.buttons["Rename…"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(convertedFrom(app, ID.libraryConvertedFrom).exists, "a PDF is not labelled")
        dismissMenu(app)

        // It opens with one page per picture.
        comicCell.tap()
        let pill = app.buttons[ID.pagePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", ["Page 1 of 5"]), pill.label)
        app.buttons[ID.more].firstMatch.tap()
        let readerLabel = convertedFrom(app, ID.readerConvertedFrom)
        XCTAssertTrue(readerLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(readerLabel.label.contains("Converted from a comic archive"), readerLabel.label)
        dismissMenu(app)
    }

    // MARK: Helpers

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The "Converted from …" menu item. SwiftUI does not pass accessibility identifiers on to
    /// menu items (XCUITest sees each item's symbol name as its identifier, or none when it is
    /// disabled), so it is found by its identifier if present, else by its words.
    private func convertedFrom(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", identifier, "Converted from")).firstMatch
    }

    private func wait(_ element: XCUIElement, _ format: String, _ arguments: [Any], timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while query.count < count {
            if Date() > deadline { return false }
            usleep(500_000)
        }
        return true
    }

    /// "Page 3 of 14" → (3, 14).
    private func pageNumbers(_ label: String) -> (page: Int, count: Int)? {
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }

    private func save(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Expands `parent` in Contents if `title` is not listed yet.
    private func reveal(_ app: XCUIApplication, _ title: String, under parent: String) {
        let row = SidebarUITests.heading(app, title)
        if row.waitForExistence(timeout: 2) { return }
        let disclosure = app.buttons["sidebar.disclosure.\(parent)"].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "disclosure of \(parent)")
        disclosure.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) under \(parent)")
    }

    /// Chooses a heading in Contents; returns the page it landed on, after checking that the
    /// heading's text is on the page shown.
    private func jump(_ app: XCUIApplication, to title: String) throws -> Int {
        let pill = app.buttons[ID.pagePill].firstMatch
        let before = pill.label
        SidebarUITests.heading(app, title).tap()
        _ = wait(pill, "label != %@", [before], timeout: 10)
        sleep(1)
        let page = try XCTUnwrap(pageNumbers(pill.label)?.page, pill.label)
        let pdf = app.otherElements[ID.pdfView].firstMatch
        let onPage = pdf.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title))
        let shown = (0..<onPage.count).map { onPage.element(boundBy: $0) }.contains { $0.isHittable }
        XCTAssertTrue(shown, "'\(title)' is on page \(page), the page Contents went to")
        return page
    }

    /// Closes an open menu (a tap away from it, on the navigation bar's title area).
    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        sleep(1)
    }

    private func backToLibrary(_ app: XCUIApplication) {
        let importButton = app.buttons["library.importButton"].firstMatch
        for _ in 0..<3 where !importButton.exists {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
            _ = importButton.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "back in the Library")
    }

    private func openContextMenu(_ app: XCUIApplication, of title: String) {
        let cell = app.buttons[ID.book(title)].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        openContextMenu(cell)
    }

    /// A long press on the title under the cover (as `LibraryUITests` does: the cover starts a
    /// drag).
    private func openContextMenu(_ cell: XCUIElement) {
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).press(forDuration: 1.0)
    }

    // MARK: Notes panel (as in JourneyUITests)

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.segmentedControls[ID.notesTabs].buttons[name].firstMatch
    }

    private func typeNote(_ app: XCUIApplication, _ text: String) {
        let view = app.textViews[ID.noteText].firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 10), "note text view")
        view.tap()
        view.typeText(text)
        XCTAssertTrue(wait(view, "value == %@", [text]), "typed \(text)")
        XCTAssertTrue(wait(app.staticTexts[ID.noteStatus].firstMatch, "label == %@", ["Saved"]), "saved \(text)")
    }

    // MARK: Highlights (as in HighlightsUITests, with the phrase's own font)

    private func line(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text))
        let hittable = (0..<lines.count).map { lines.element(boundBy: $0) }.first { $0.isHittable }
        return hittable ?? lines.firstMatch
    }

    /// The screen point of the middle of `word` in a line element (or of its end), from Times
    /// metrics scaled to the element's width (the phrase is set in Times New Roman).
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
        XCTAssertTrue(element.waitForExistence(timeout: 10), "line '\(text)' not found\n\(app.debugDescription)")
        point(of: first, in: element, app: app)
            .press(forDuration: 1.2, thenDragTo: point(of: last, in: element, app: app, atEnd: true))
        sleep(1)
    }

    private func chooseHighlight(_ colour: String, app: XCUIApplication) throws {
        guard let submenu = menuItem(app, "Highlight") else {
            try save("conversion-missing-highlight-menu")
            return XCTFail("no 'Highlight' in the edit menu")
        }
        submenu.tap()
        guard let item = menuItem(app, colour) else { return XCTFail("no '\(colour)' in the Highlight submenu") }
        item.tap()
        sleep(1)
    }
}
