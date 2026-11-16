import UIKit
import XCTest

/// Text highlights: make one from a text selection through the edit menu, see it, find it
/// again after a relaunch, recolour and delete it from the tap menu, without the reading
/// position moving; a second window on the same book shows it; screenshots of the four colours
/// and both menus (`build/shots/highlights-*.png`).
@MainActor
final class HighlightsUITests: XCTestCase {
    /// The fixture phrase on page 3 of `small.pdf` (its first body line reads "Remember that
    /// the quick amber fox annotates margins.").
    static let phrase = "the quick amber fox annotates margins"

    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func launch(fresh: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let arguments = ["-openBook", "small", "-openPage", "3", "-exposeViewportAnchor"] + extra
        let app: XCUIApplication
        if fresh {
            app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + arguments)
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-pagePillStaysVisible"] + arguments
            app.launch()
        }
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["reader.viewportAnchor"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        return app
    }

    /// The reading anchor once it has stopped changing ("page N x X y Y scale S").
    private func settledAnchor(_ app: XCUIApplication) -> String {
        let probe = app.buttons["reader.viewportAnchor"].firstMatch
        var last = probe.value as? String ?? ""
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            usleep(400_000)
            let next = probe.value as? String ?? ""
            if next == last, !next.isEmpty { break }
            last = next
        }
        return last
    }

    /// The page-text element holding `text` (PDFKit exposes page text one paragraph per static
    /// text; the phrase is a one-line paragraph).
    private func line(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text))
        let hittable = (0..<lines.count).map { lines.element(boundBy: $0) }.first { $0.isHittable }
        return hittable ?? lines.firstMatch
    }

    /// The screen point of the middle of `word` (its first occurrence) in a line element, or of
    /// its end with `atEnd`, from the fixture's font metrics (Times-Roman 11) scaled to the
    /// element's width.
    private func point(of word: String, in line: XCUIElement, app: XCUIApplication,
                       atEnd: Bool = false) -> XCUICoordinate {
        let label = line.label as NSString
        let font = UIFont(name: "TimesNewRomanPSMT", size: 11) ?? UIFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let full = label.size(withAttributes: attributes).width
        let range = label.range(of: word)
        let before = label.substring(to: range.location).size(withAttributes: attributes).width
        let width = (word as NSString).size(withAttributes: attributes).width
        let scale = line.frame.width / max(full, 1)
        let x = line.frame.minX + (before + (atEnd ? width + 0.7 : width / 2)) * scale
        let y = line.frame.midY
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// An edit-menu item (the horizontal edit menu exposes items as buttons or menu items).
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

    /// Selects from `first` to the end of `last` on one line (a long press selects the first
    /// word; dragging on extends the selection by characters, to the end of the last word).
    private func select(from first: String, to last: String, onLineContaining text: String, app: XCUIApplication) {
        let element = line(app, containing: text)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "line '\(text)' not found")
        let start = point(of: first, in: element, app: app)
        if first == last {
            start.press(forDuration: 1.2)
        } else {
            start.press(forDuration: 1.2, thenDragTo: point(of: last, in: element, app: app, atEnd: true))
        }
        sleep(1)
    }

    /// Chooses a colour in the selection menu (its "Highlight" submenu).
    private func chooseHighlight(_ colour: String, app: XCUIApplication, shot: String? = nil) throws {
        guard let submenu = menuItem(app, "Highlight") else {
            try save("highlights-missing-menu")
            return XCTFail("no 'Highlight' in the edit menu")
        }
        if let shot { try save(shot) }
        submenu.tap()
        guard let item = menuItem(app, colour) else {
            try save("highlights-missing-colours")
            return XCTFail("no '\(colour)' in the Highlight submenu")
        }
        if let shot { try save(shot + "-colours") }
        item.tap()
        sleep(1)
    }

    private func highlights(_ app: XCUIApplication, page: Int) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reader.highlight.\(page)."))
    }

    private func save(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18 ? "-ios17" : ""
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("\(name)\(suffix).png"))
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            usleep(250_000)
        }
        return true
    }

    // MARK: Tests

    /// Highlight the phrase in yellow, relaunch, recolour to green, delete; the reading position
    /// never moves.
    func testHighlightRelaunchRecolourDelete() throws {
        var app = launch()
        let anchor = settledAnchor(app)
        select(from: "the", to: "margins", onLineContaining: "amber fox", app: app)
        try chooseHighlight("Yellow", app: app, shot: "highlights-edit-menu")

        let element = app.buttons["reader.highlight.3.0"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "the highlight is not shown")
        XCTAssertEqual(element.label, "Yellow highlight, page 3")
        XCTAssertEqual(element.value as? String, Self.phrase)
        XCTAssertEqual(highlights(app, page: 3).count, 1)
        XCTAssertEqual(settledAnchor(app), anchor, "making a highlight moved the page")

        // Relaunch (same store): the highlight is still there.
        app.terminate()
        app = launch(fresh: false)
        let anchorAfterRelaunch = settledAnchor(app)
        let relaunched = app.buttons["reader.highlight.3.0"].firstMatch
        XCTAssertTrue(relaunched.waitForExistence(timeout: 10), "the highlight did not survive a relaunch")
        XCTAssertEqual(relaunched.value as? String, Self.phrase)

        // Tap it: recolour to green.
        relaunched.tap()
        guard let green = menuItem(app, "Green") else {
            try save("highlights-missing-tap-menu")
            return XCTFail("tap menu did not open")
        }
        try save("highlights-tap-menu")
        XCTAssertNotNil(menuItem(app, "Delete", timeout: 1))
        XCTAssertNotNil(menuItem(app, "Copy", timeout: 1))
        green.tap()
        XCTAssertTrue(waitFor { app.buttons["reader.highlight.3.0"].firstMatch.label == "Green highlight, page 3" },
                      "recolour did not apply")
        XCTAssertEqual(settledAnchor(app), anchorAfterRelaunch, "recolouring moved the page")

        // Tap it again: delete.
        app.buttons["reader.highlight.3.0"].firstMatch.tap()
        guard let delete = menuItem(app, "Delete") else { return XCTFail("tap menu did not open") }
        delete.tap()
        XCTAssertTrue(waitFor { self.highlights(app, page: 3).count == 0 }, "delete did not remove the highlight")
        XCTAssertEqual(settledAnchor(app), anchorAfterRelaunch, "deleting moved the page")
    }

    /// A tap on the page that is not on a highlight opens no highlight menu (and is not consumed).
    func testTapOutsideHighlightOpensNothing() throws {
        let app = launch()
        select(from: "the", to: "margins", onLineContaining: "amber fox", app: app)
        try chooseHighlight("Pink", app: app)
        XCTAssertTrue(app.buttons["reader.highlight.3.0"].firstMatch.waitForExistence(timeout: 10))
        // A word two lines below, away from the highlight.
        let other = line(app, containing: "Inverse then")
        point(of: "Inverse", in: other, app: app).tap()
        XCTAssertNil(menuItem(app, "Delete", timeout: 2), "a tap off the highlight opened the highlight menu")
    }

    /// A second window on the same book shows a highlight made in the first.
    func testSecondWindowShowsHighlight() throws {
        let app = launch(["-alsoOpenWindow", "small", "-alsoOpenWindowPage", "3"])
        let pills = app.buttons.matching(identifier: "reader.pagePill")
        XCTAssertTrue(waitFor(30) { pills.count >= 2 }, "second window did not open")
        sleep(2)
        select(from: "the", to: "margins", onLineContaining: "amber fox", app: app)
        try chooseHighlight("Blue", app: app)
        let shown = app.buttons.matching(identifier: "reader.highlight.3.0")
        XCTAssertTrue(waitFor { shown.count == 2 }, "expected the highlight in both windows, found \(shown.count)")
        for index in 0..<shown.count {
            XCTAssertEqual(shown.element(boundBy: index).label, "Blue highlight, page 3")
        }
        // Leave one window (system Close Window, ⌘W).
        app.typeKey("w", modifierFlags: .command)
        sleep(2)
        if app.buttons.matching(identifier: "reader.pagePill").count > 1 {
            app.typeKey("w", modifierFlags: .command)
            sleep(2)
        }
    }

    /// Screenshot: the four colours on page 3 (left in the store for the dark-mode shot that
    /// `scripts/shot.sh` takes after this test).
    func testScreenshotFourColours() throws {
        let app = launch()
        select(from: "the", to: "margins", onLineContaining: "amber fox", app: app)
        try chooseHighlight("Yellow", app: app)
        // The other paragraphs are justified and exposed as one element each, so a long press
        // selects their first word (top-left of the element).
        for (start, colour) in [("Inverse then hence", "Green"), ("Eigenvalue we kernel", "Blue"),
                                ("Obtain show product", "Pink")] {
            let paragraph = line(app, containing: start)
            XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: paragraph.frame.minX + 12, dy: paragraph.frame.minY + 6))
                .press(forDuration: 1.2)
            sleep(1)
            try chooseHighlight(colour, app: app)
        }
        XCTAssertTrue(waitFor { self.highlights(app, page: 3).count == 4 }, "found \(highlights(app, page: 3).count)")
        sleep(1)
        try save("highlights-four-colours")
    }
}
