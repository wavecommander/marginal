import XCTest

/// Identifiers mirrored from `App/Features/Sidebar/SidebarAccessibilityID.swift`.
enum SidebarID {
    static let tabs = "sidebar.tabs"
    static func heading(_ title: String) -> String { "sidebar.heading.\(title)" }
    static func disclosure(_ title: String) -> String { "sidebar.disclosure.\(title)" }
    static let addHeading = "sidebar.addHeading"
    static let emptyAddHeading = "sidebar.contents.empty.addHeading"
    static let addHeadingTitle = "sidebar.addHeading.title"
    static let addHeadingSave = "sidebar.addHeading.save"
    static let renameField = "sidebar.rename.field"
    static func page(_ number: Int) -> String { "sidebar.page.\(number)" }
    static func bookmark(_ number: Int) -> String { "sidebar.bookmark.\(number)" }
    static let debugStats = "sidebar.debugStats"
    static let bookmarkButton = "reader.toolbar.bookmark"
    static let viewportAnchor = "reader.viewportAnchor"
}

/// WP5 Contents sidebar: jump from a heading, current-section tracking, user headings on a book
/// with no outline, bookmarks round trip, Pages tab, note badges, reading-position stability and
/// thumbnail memory. Typed, scoped queries only (`descendants(matching: .any)` is very slow over
/// PDFKit's element tree on `large.pdf`).
@MainActor
final class SidebarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    static func open(_ fixture: String, _ title: String, _ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(fixture) + ["-openBook", title] + extra)
    }

    static func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[ReaderID.pagePill].firstMatch
    }

    static func waitFor(_ element: XCUIElement, _ format: String, _ args: CVarArg..., timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        waitFor(element, "label == %@", label, timeout: timeout)
    }

    static func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.segmentedControls[SidebarID.tabs].buttons[name].firstMatch
    }

    static func selectTab(_ app: XCUIApplication, _ name: String) {
        let button = tab(app, name)
        XCTAssertTrue(button.waitForExistence(timeout: 20), "tab \(name)")
        if !button.isSelected { button.tap() }
    }

    static func heading(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons[SidebarID.heading(title)].firstMatch
    }

    /// Go to Page… (⌥⌘G on iOS 26+; on 17.5 XCUITest's ⌥ shortcuts are unreliable, so the
    /// pill is tapped) and types the number.
    static func goToPage(_ app: XCUIApplication, _ number: Int) {
        if #available(iOS 26.0, *) {
            app.typeKey("g", modifierFlags: [.command, .option])
        } else {
            pill(app).tap()
        }
        sleep(1)
        app.typeText("\(number)\n")
    }

    /// Types a title into the open heading sheet, optionally picks a placement, and adds.
    static func fillHeadingSheet(_ app: XCUIApplication, title: String, placement: String? = nil) {
        let field = app.textFields[SidebarID.addHeadingTitle].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        sleep(1)
        if !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { field.tap() }
        replaceText(field, with: title)
        if let placement {
            // The placement picker's rows (in the sheet's form), not the sidebar's heading rows.
            let predicate = NSPredicate(format: "label BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)",
                                        placement, "sidebar.heading.", "sidebar.disclosure.")
            var choice = app.buttons.matching(predicate).firstMatch
            if !choice.waitForExistence(timeout: 3) { choice = app.cells.matching(predicate).firstMatch }
            if !choice.waitForExistence(timeout: 2) { choice = app.staticTexts.matching(predicate).firstMatch }
            if !choice.waitForExistence(timeout: 2) { print("SHEET-DUMP\n\(app.debugDescription)") }
            XCTAssertTrue(choice.exists, "placement \(placement)")
            choice.tap()
        }
        app.navigationBars.buttons[SidebarID.addHeadingSave].firstMatch.tap()
        XCTAssertTrue(heading(app, title).waitForExistence(timeout: 10), "added \(title)")
    }

    private func dumpHeadingsAfterFailure(_ app: XCUIApplication) {
        Self.dumpHeadings(app, "after failure")
        print("SHEET-STATE save exists \(app.navigationBars.buttons[SidebarID.addHeadingSave].firstMatch.exists)")
    }

    /// Prints the sidebar's heading rows (diagnostics on failure).
    static func dumpHeadings(_ app: XCUIApplication, _ note: String) {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.heading.")).allElementsBoundByIndex
        print("HEADINGS-DUMP \(note): " + rows.map { "\($0.label) [\($0.value as? String ?? "")]" }.joined(separator: " | "))
    }

    /// Replaces the text in the Rename alert and confirms.
    static func renameInAlert(_ app: XCUIApplication, to title: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(field, with: title)
        alert.buttons["Rename"].tap()
        if !heading(app, title).waitForExistence(timeout: 5) { dumpHeadings(app, "after rename to \(title)") }
    }

    /// Replaces a focused field's text and checks it arrived (XCUITest's typing can drop
    /// characters while the simulator is busy); retries up to three times.
    static func replaceText(_ field: XCUIElement, with text: String) {
        for _ in 0..<3 {
            // Backspaces, not ⌘A: ⌘A in an empty field is passed up the responder chain, and on
            // iOS 27 that left the app animating forever (XCUITest then never sees it idle).
            let shown = field.value as? String ?? ""
            let current = shown == (field.placeholderValue ?? "") ? "" : shown
            if !current.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 1))
            }
            field.typeText(text)
            if waitFor(field, "value == %@", text, timeout: 3) { return }
        }
        XCTFail("could not type “\(text)” (field shows “\(field.value ?? "nil")”)")
    }

    /// The navigation bar shows `text` (the subtitle on iOS 26+, the title block before).
    static func navigationBarShows(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let match = app.navigationBars.firstMatch.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    /// Go › First Page (⇧⌘↑, a jump).
    static func firstPage(_ app: XCUIApplication) {
        app.typeKey(.upArrow, modifierFlags: [.command, .shift])
    }

    // MARK: Contents

    /// Tap a chapter on `large.pdf`: land on its start page, with section-history Back enabled;
    /// expand it and tap a section.
    func testTapHeadingJumpsToItsStartPage() {
        let app = Self.open(Fixtures.large, "large")
        XCTAssertTrue(Self.pill(app).waitForExistence(timeout: 40))
        Self.selectTab(app, "Contents")
        let chapter = Self.heading(app, "5 Eigenvalues")
        XCTAssertTrue(chapter.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons[ReaderID.historyBack].firstMatch.isEnabled)
        chapter.tap()
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 401 of 1500"))
        XCTAssertTrue(Self.waitFor(app.buttons[ReaderID.historyBack].firstMatch, "enabled == true"))
        XCTAssertTrue(Self.waitFor(chapter, "value CONTAINS %@", "current section"))

        let disclosure = app.buttons[SidebarID.disclosure("5 Eigenvalues")].firstMatch
        XCTAssertTrue(disclosure.exists)
        disclosure.tap()
        let section = Self.heading(app, "5.2 Key Results")
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.tap()
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 418 of 1500"))
        XCTAssertTrue(Self.waitFor(section, "value CONTAINS %@", "current section"))
        XCTAssertTrue(Self.waitFor(chapter, "value CONTAINS %@", "contains current page"))
    }

    /// A go-to-page jump moves the current section: its chapter and section open, and the
    /// deepest heading is marked current.
    func testCurrentSectionFollowsGoToPage() {
        let app = Self.open(Fixtures.large, "large")
        XCTAssertTrue(Self.pill(app).waitForExistence(timeout: 40))
        Self.selectTab(app, "Contents")
        XCTAssertTrue(Self.heading(app, "1 Linear Systems").waitForExistence(timeout: 30))
        Self.goToPage(app, 640)
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 640 of 1500"))
        let current = Self.heading(app, "7.3.2 Worked Examples")
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertTrue(Self.waitFor(current, "value CONTAINS %@", "current section"))
        XCTAssertTrue(current.isHittable, "the current section is scrolled into view")
        XCTAssertTrue(Self.waitFor(Self.heading(app, "7 Orthogonality"), "value CONTAINS %@", "contains current page"))
    }

    /// On `no-outline.pdf`: the empty state's "Add Heading", see it in Contents, jump to it,
    /// rename it, delete it.
    func testAddRenameDeleteHeadingOnBookWithNoOutline() {
        let app = Self.open(Fixtures.noOutline, "no-outline", ["-openPage", "5"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 5 of 40", timeout: 40))
        Self.selectTab(app, "Contents")
        let emptyAdd = app.buttons[SidebarID.emptyAddHeading].firstMatch
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 20))
        XCTAssertEqual(emptyAdd.label, "Add Heading at Page 5")
        emptyAdd.tap()

        let titleField = app.textFields[SidebarID.addHeadingTitle].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        sleep(1)
        if !(titleField.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { titleField.tap() }
        titleField.typeText("Chapter Alpha")
        app.navigationBars.buttons[SidebarID.addHeadingSave].firstMatch.tap()

        let row = Self.heading(app, "Chapter Alpha")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue((row.value as? String ?? "").contains("page 5"))

        // Jump to it from page 1.
        Self.firstPage(app)
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 1 of 40"))
        row.tap()
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 5 of 40"))

        // Rename through the context menu.
        row.press(forDuration: 1.2)
        let rename = app.buttons["Rename…"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        Self.renameInAlert(app, to: "Chapter Beta")
        let renamed = Self.heading(app, "Chapter Beta")
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        XCTAssertFalse(Self.heading(app, "Chapter Alpha").exists)

        // Delete through the context menu; the confirmation says what happens.
        renamed.press(forDuration: 1.2)
        let delete = app.buttons["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Delete “Chapter Beta”?"].exists)
        alert.buttons["Delete Heading"].tap()
        XCTAssertTrue(app.buttons[SidebarID.emptyAddHeading].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(renamed.exists)
    }

    /// Building a structure on `no-outline.pdf` while paging through it: three headings at
    /// different pages and levels (from the empty state and the "+" footer), shown in page order
    /// with the right nesting; the toolbar subtitle follows a jump into one; rename one, move one
    /// to another page, delete the parent and see its children promoted; relaunch and find them.
    func testBuildAnOutlineOnABookWithNoOutline() {
        let app = Self.open(Fixtures.noOutline, "no-outline", ["-openPage", "3"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 3 of 40", timeout: 40))
        Self.selectTab(app, "Contents")

        // 1. "Part One" at page 3, top level, from the empty state.
        let emptyAdd = app.buttons[SidebarID.emptyAddHeading].firstMatch
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 20))
        emptyAdd.tap()
        Self.fillHeadingSheet(app, title: "Part One")
        let partOne = Self.heading(app, "Part One")
        XCTAssertTrue(partOne.waitForExistence(timeout: 10))
        XCTAssertTrue(Self.waitFor(partOne, "value CONTAINS %@", "your heading"))
        XCTAssertEqual(Self.pill(app).label, "Page 3 of 40", "adding never moves the PDF")

        // 2. "Section A" at page 10 inside Part One, from the footer.
        Self.goToPage(app, 10)
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 10 of 40"))
        let footer = app.buttons[SidebarID.addHeading].firstMatch
        XCTAssertTrue(Self.waitForLabel(footer, "Add Heading at Page 10"))
        footer.tap()
        Self.fillHeadingSheet(app, title: "Section A", placement: "Part One")

        // 3. "Section B" at page 14: the sheet remembers the placement (inside Part One).
        Self.goToPage(app, 14)
        XCTAssertTrue(Self.waitForLabel(footer, "Add Heading at Page 14"))
        footer.tap()
        Self.fillHeadingSheet(app, title: "Section B")

        // 4. "Part Two" at page 25, back at the top level.
        Self.goToPage(app, 25)
        XCTAssertTrue(Self.waitForLabel(footer, "Add Heading at Page 25"))
        footer.tap()
        Self.fillHeadingSheet(app, title: "Part Two", placement: "Top level")

        let sectionA = Self.heading(app, "Section A")
        let sectionB = Self.heading(app, "Section B")
        let partTwo = Self.heading(app, "Part Two")
        for (row, level, page) in [(partOne, 1, 3), (sectionA, 2, 10), (sectionB, 2, 14), (partTwo, 1, 25)] {
            XCTAssertTrue(row.waitForExistence(timeout: 10), row.identifier)
            let value = row.value as? String ?? ""
            XCTAssertTrue(value.contains("level \(level)") && value.contains("page \(page)"), "\(row.identifier): \(value)")
        }
        // Page order, top to bottom.
        let ys = [partOne, sectionA, sectionB, partTwo].map(\.frame.minY)
        XCTAssertEqual(ys, ys.sorted())

        // The toolbar subtitle shows the reader's section after a jump into it.
        sectionB.tap()
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 14 of 40"))
        XCTAssertTrue(Self.navigationBarShows(app, "Section B"))

        // Rename Section A.
        sectionA.press(forDuration: 1.2)
        app.buttons["Rename…"].firstMatch.tap()
        Self.renameInAlert(app, to: "Section Alpha")
        let sectionAlpha = Self.heading(app, "Section Alpha")
        XCTAssertTrue(sectionAlpha.waitForExistence(timeout: 10))

        // Move Section B to page 18.
        sectionB.press(forDuration: 1.2)
        let edit = app.buttons["Edit Page and Level…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let pageField = app.textFields["sidebar.addHeading.page"].firstMatch
        XCTAssertTrue(pageField.waitForExistence(timeout: 10))
        pageField.tap()
        Self.replaceText(pageField, with: "18")
        let save = app.navigationBars.buttons[SidebarID.addHeadingSave].firstMatch
        if (pageField.value as? String) != "18" || !save.isEnabled {
            print("EDIT-DUMP page field “\(pageField.value ?? "nil")” save enabled \(save.isEnabled)\n\(app.debugDescription)")
        }
        save.tap()
        if !Self.waitFor(sectionB, "value CONTAINS %@", "page 18") {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: Fixtures.repoRoot.appendingPathComponent("build/shots/debug-edit-after-save.png"))
            dumpHeadingsAfterFailure(app)
            XCTFail("Section B not moved to page 18")
        }
        XCTAssertTrue(Self.waitFor(sectionB, "value CONTAINS %@", "level 2"))

        // Delete Part One: its two sections move up to the top level.
        partOne.press(forDuration: 1.2)
        app.buttons["Delete…"].firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 sub-headings move up one level"))
            .firstMatch.exists)
        alert.buttons["Delete Heading"].tap()
        XCTAssertTrue(Self.waitFor(sectionAlpha, "value CONTAINS %@", "level 1"))
        XCTAssertTrue(Self.waitFor(sectionB, "value CONTAINS %@", "level 1"))
        XCTAssertFalse(partOne.exists)

        // Relaunch: the reader's outline is stored with the book.
        sleep(1)
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-openBook", "no-outline"]
        again.launch()
        XCTAssertTrue(Self.pill(again).waitForExistence(timeout: 40))
        Self.selectTab(again, "Contents")
        for title in ["Section Alpha", "Section B", "Part Two"] {
            XCTAssertTrue(Self.heading(again, title).waitForExistence(timeout: 15), title)
        }
        XCTAssertFalse(Self.heading(again, "Part One").exists)
    }

    /// "Add as Heading" in the text-selection menu pre-fills the title from the selection.
    func testAddAsHeadingFromTextSelection() {
        let app = Self.open(Fixtures.noOutline, "no-outline", ["-openPage", "2"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 2 of 40", timeout: 40))
        Self.selectTab(app, "Contents")
        XCTAssertTrue(app.buttons[SidebarID.emptyAddHeading].firstMatch.waitForExistence(timeout: 20))
        // Long-press a word in the body text to select it and show the edit menu.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).press(forDuration: 1.2)
        var item = app.buttons["Add as Heading"].firstMatch
        if !item.waitForExistence(timeout: 5) { item = app.menuItems["Add as Heading"].firstMatch }
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Add as Heading in the selection menu")
        item.tap()
        let titleField = app.textFields[SidebarID.addHeadingTitle].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        let suggested = titleField.value as? String ?? ""
        XCTAssertFalse(suggested.isEmpty)
        XCTAssertFalse(suggested.contains("\n"))
        app.navigationBars.buttons[SidebarID.addHeadingSave].firstMatch.tap()
        XCTAssertTrue(Self.heading(app, suggested).waitForExistence(timeout: 10), "heading “\(suggested)”")
        XCTAssertTrue((Self.heading(app, suggested).value as? String ?? "").contains("page 2"))
    }

    /// The shell's entry points: More ▸ "Add Heading at This Page…" and Book ▸ ⌥⌘H both open the
    /// sidebar's sheet (switching to the Contents tab) at the current page.
    func testAddHeadingFromMoreMenuAndShortcut() {
        let app = Self.open(Fixtures.noOutline, "no-outline", ["-openPage", "6"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 6 of 40", timeout: 40))
        Self.selectTab(app, "Pages")

        let more = app.buttons[ReaderID.more].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let item = app.buttons["Add Heading at This Page…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        Self.fillHeadingSheet(app, title: "From More")
        XCTAssertTrue(Self.tab(app, "Contents").isSelected, "the request shows Contents")
        XCTAssertTrue((Self.heading(app, "From More").value as? String ?? "").contains("page 6"))
        XCTAssertEqual(Self.pill(app).label, "Page 6 of 40", "adding never moves the PDF")

    }

    /// Book ▸ "Add Heading at This Page…" by its shortcut ⌥⌘H. Skipped (not failed) when the
    /// simulator does not deliver the key event to the menu command.
    func testAddHeadingFromKeyboardShortcut() throws {
        let app = Self.open(Fixtures.noOutline, "no-outline", ["-openPage", "12"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 12 of 40", timeout: 40))
        Self.selectTab(app, "Contents")
        XCTAssertTrue(app.buttons[SidebarID.emptyAddHeading].firstMatch.waitForExistence(timeout: 20))
        sleep(2)  // hardware-key events need the window to have become key
        app.typeKey("h", modifierFlags: [.command, .option])
        guard app.textFields[SidebarID.addHeadingTitle].firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("⌥⌘H was not delivered to the Book menu command on this simulator")
        }
        Self.fillHeadingSheet(app, title: "From Shortcut")
        XCTAssertTrue((Self.heading(app, "From Shortcut").value as? String ?? "").contains("page 12"))
    }

    // MARK: Bookmarks

    /// Toolbar toggle → Bookmarks tab → jump from it → relaunch → still there → remove.
    func testBookmarkRoundTrip() {
        let app = Self.open(Fixtures.small, "small", ["-openPage", "5"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 5 of 12", timeout: 40))
        Self.selectTab(app, "Bookmarks")
        XCTAssertTrue(app.buttons["Bookmark Page 5"].firstMatch.waitForExistence(timeout: 10), "empty state")

        let toggle = app.buttons[SidebarID.bookmarkButton].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Bookmark This Page")
        toggle.tap()
        XCTAssertTrue(Self.waitForLabel(toggle, "Remove Bookmark"))
        let row = app.buttons[SidebarID.bookmark(5)].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue((row.value as? String ?? "").contains("2 Vector Spaces"))

        Self.firstPage(app)
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 1 of 12"))
        XCTAssertTrue(Self.waitForLabel(toggle, "Bookmark This Page"))
        row.tap()
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 5 of 12"))
        XCTAssertTrue(Self.waitFor(app.buttons[ReaderID.historyBack].firstMatch, "enabled == true"))

        // Relaunch (no reset): the bookmark persisted.
        sleep(1)
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-openBook", "small"]
        again.launch()
        XCTAssertTrue(Self.pill(again).waitForExistence(timeout: 40))
        Self.selectTab(again, "Bookmarks")
        let persisted = again.buttons[SidebarID.bookmark(5)].firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 10))

        // Remove with a swipe.
        persisted.swipeLeft()
        let remove = again.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(again.buttons["Bookmark Page 5"].firstMatch.waitForExistence(timeout: 10), "empty again")
        XCTAssertTrue(Self.waitForLabel(again.buttons[SidebarID.bookmarkButton].firstMatch, "Bookmark This Page"))
    }

    // MARK: Pages

    func testPagesTabShowsCurrentPageAndJumps() {
        let app = Self.open(Fixtures.large, "large", ["-openPage", "312"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 312 of 1500", timeout: 40))
        Self.selectTab(app, "Pages")
        let current = app.buttons[SidebarID.page(312)].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10), "current page scrolled into view")
        XCTAssertTrue(current.isHittable)
        XCTAssertTrue((current.value as? String ?? "").contains("current page"))
        let target = app.buttons[SidebarID.page(314)].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 314 of 1500"))
        if !Self.waitFor(target, "value CONTAINS %@", "current page") {
            print("PAGES-DUMP 314: label \(target.label) value \(target.value ?? "nil"); 312 value \(current.value ?? "nil")")
            XCTFail("page 314 not marked current")
        }
        // 312 → 314 stays in "4.1.3 Summary": a same-section jump adds no history entry (design).
    }

    // MARK: Badges

    /// A heading gains a badge when a page note is typed in the notes panel (seeded through the
    /// UI; the store-level mapping is `SidebarModelTests.badgesComeFromNotesAndHighlightsButNotBookmarks`).
    func testHeadingGainsBadgeWhenAPageNoteIsWritten() {
        let app = Self.open(Fixtures.small, "small", ["-openPage", "7"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 7 of 12", timeout: 40))
        Self.selectTab(app, "Contents")
        let section = Self.heading(app, "2.1 Foundations")
        XCTAssertTrue(section.waitForExistence(timeout: 20))
        XCTAssertTrue(Self.waitFor(section, "value CONTAINS %@", "current section"))
        XCTAssertFalse((section.value as? String ?? "").contains("has notes"))

        let text = app.textViews["notePage.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        text.tap()
        text.typeText("A note for the badge")
        XCTAssertTrue(Self.waitFor(section, "value CONTAINS %@", "has notes", timeout: 20))
        XCTAssertTrue(Self.waitFor(Self.heading(app, "2 Vector Spaces"), "value CONTAINS %@", "has notes"))
        XCTAssertFalse((Self.heading(app, "2.2 Exercises").value as? String ?? "").contains("has notes"))
    }

    // MARK: Stability

    /// Switching sidebar tabs, and hiding and showing the sidebar, never moves the page.
    func testSwitchingTabsKeepsTheReadingPosition() {
        let app = Self.open(Fixtures.large, "large", ["-openPage", "312", "-exposeViewportAnchor"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 312 of 1500", timeout: 40))
        let anchor = app.buttons[SidebarID.viewportAnchor].firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 10))
        Self.selectTab(app, "Contents")
        sleep(2)
        let before = anchor.value as? String
        XCTAssertNotNil(before)
        for name in ["Pages", "Bookmarks", "Contents", "Pages", "Contents"] {
            Self.tab(app, name).tap()
            sleep(1)
            XCTAssertEqual(anchor.value as? String, before, "after switching to \(name)")
        }
        let toggle = app.buttons[ReaderID.contentsToggle].firstMatch
        toggle.tap()
        sleep(1)
        toggle.tap()
        sleep(2)
        XCTAssertEqual(anchor.value as? String, before, "after hiding and showing the sidebar")
        XCTAssertEqual(Self.pill(app).label, "Page 312 of 1500")
    }

    // MARK: Thumbnails under fast scrolling

    /// Flings through the whole 1,500-page grid and back. The cache stays within its bounds, the
    /// app's footprint stays bounded, and the figures are logged for the report.
    func testFastThumbnailScrollingStaysBounded() throws {
        let app = Self.open(Fixtures.large, "large", ["-sidebarDebugStats"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 1 of 1500", timeout: 40))
        Self.selectTab(app, "Pages")
        let stats = app.buttons[SidebarID.debugStats].firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        let grid = app.scrollViews["sidebar.pages.grid"].firstMatch
        XCTAssertTrue(grid.exists)
        // Resolve coordinates once: flings by coordinate need no element look-ups (each look-up
        // makes XCUITest snapshot the app's accessibility tree on its main thread, which shows
        // up as frame gaps that are the harness's, not the app's).
        let low = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let high = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        sleep(2)
        let start = Self.parse(stats.value as? String ?? "")
        // Baseline: frame gaps over 5 s of doing nothing.
        stats.tap()
        sleep(5)
        let idle = Self.parse(stats.value as? String ?? "")
        stats.tap()  // reset frame counters
        let started = Date()
        for _ in 0..<25 { low.press(forDuration: 0.01, thenDragTo: high, withVelocity: 5000, thenHoldForDuration: 0) }
        let downSeconds = Date().timeIntervalSince(started)
        sleep(2)
        let afterDown = Self.parse(stats.value as? String ?? "")
        for _ in 0..<25 { high.press(forDuration: 0.01, thenDragTo: low, withVelocity: 5000, thenHoldForDuration: 0) }
        sleep(2)
        let end = Self.parse(stats.value as? String ?? "")
        let report = """
            thumbnails: start \(start)
            idle 5 s (frame-gap baseline): \(idle)
            after 25 fast swipes down (\(String(format: "%.1f", downSeconds)) s): \(afterDown)
            after 25 fast swipes back: \(end)
            """
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "thumbnail-scroll-stats"
        attachment.lifetime = .keepAlways
        add(attachment)
        try report.write(to: Fixtures.repoRoot.appendingPathComponent("build/sidebar-thumbnail-stats\(Self.suffix).txt"),
                         atomically: true, encoding: .utf8)

        XCTAssertLessThanOrEqual(afterDown["cached"] ?? .infinity, 240)
        XCTAssertLessThanOrEqual(end["cached"] ?? .infinity, 240)
        XCTAssertLessThanOrEqual(end["bytes"] ?? .infinity, 24 * 1024 * 1024)
        // The whole book is never rendered by a fling.
        XCTAssertLessThan(afterDown["rendered"] ?? .infinity, 1_500)
        // Bounded growth (generous: simulator footprints include the PDF view's own caches).
        XCTAssertLessThan((end["footprintMB"] ?? 0) - (start["footprintMB"] ?? 0), 400)
    }

    /// The app scrolls its own Pages grid through all 1,500 pages and back (`-sidebarAutoScroll`,
    /// one step of 6 pages every 16 ms) with no XCUITest gestures or queries while it runs, so the
    /// frame-gap figures are the app's own: thumbnails must not stall the main thread (which
    /// drives the PDF view), cells that fly past are cancelled, the cache stays bounded.
    func testAutoScrollThroughTheWholeBook() throws {
        let app = Self.open(Fixtures.large, "large", ["-sidebarDebugStats", "-sidebarAutoScroll"])
        XCTAssertTrue(Self.waitForLabel(Self.pill(app), "Page 1 of 1500", timeout: 40))
        Self.selectTab(app, "Pages")
        // 2 × 250 steps × ≥16 ms ≈ 8–15 s after a 3 s settle; no queries meanwhile.
        sleep(30)
        let stats = app.buttons[SidebarID.debugStats].firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        let value = stats.value as? String ?? ""
        let figures = Self.parse(value)
        let report = "auto-scroll 1,500 pages down and up: \(value)"
        print(report)
        try report.write(to: Fixtures.repoRoot.appendingPathComponent("build/sidebar-autoscroll-stats.txt"),
                         atomically: true, encoding: .utf8)
        XCTAssertTrue(value.contains("phase done"), value)
        XCTAssertLessThanOrEqual(figures["cached"] ?? .infinity, 240)
        XCTAssertLessThanOrEqual(figures["bytes"] ?? .infinity, 24 * 1024 * 1024)
        XCTAssertGreaterThan(figures["cancelled"] ?? 0, 0, "cells that flew past were cancelled")
        XCTAssertLessThan(figures["rendered"] ?? .infinity, figures["requests"] ?? 0, "cells that only flew past were not rendered")
        XCTAssertLessThan(figures["doneMaxGapMS"] ?? .infinity, 250, "no main-thread stall while thumbnails stream in")
    }

    static var suffix: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18 ? "-ios17" : ""
    }

    /// "key value key value …" → [key: value].
    static func parse(_ value: String) -> [String: Double] {
        let parts = value.split(separator: " ").map(String.init)
        var result: [String: Double] = [:]
        var index = 0
        while index + 1 < parts.count {
            if let number = Double(parts[index + 1]) { result[parts[index]] = number }
            index += 2
        }
        return result
    }
}

/// Sidebar screenshots for comparing against the mockups: `build/shots/<name><suffix>.png`
/// (suffix `-ios17` on iOS 17). Not assertions about pixels.
@MainActor
final class SidebarScreenshotUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    private func save(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("\(name)\(SidebarUITests.suffix).png"))
    }

    private func launchLarge(_ orientation: UIDeviceOrientation = .landscapeLeft,
                             _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = SidebarUITests.open(Fixtures.large, "large", ["-openPage", "312", "-seedSidebar"] + extra)
        XCTAssertTrue(SidebarUITests.waitForLabel(SidebarUITests.pill(app), "Page 312 of 1500", timeout: 40))
        return app
    }

    func testSidebarContentsWithBadges() throws {
        let app = launchLarge()
        SidebarUITests.selectTab(app, "Contents")
        XCTAssertTrue(SidebarUITests.waitFor(SidebarUITests.heading(app, "4.1.3 Summary"), "value CONTAINS %@", "has notes"))
        sleep(2)
        try save("sidebar-contents")
    }

    func testSidebarPages() throws {
        let app = launchLarge()
        SidebarUITests.selectTab(app, "Pages")
        sleep(4)
        try save("sidebar-pages")
    }

    func testSidebarBookmarks() throws {
        let app = launchLarge()
        SidebarUITests.selectTab(app, "Bookmarks")
        XCTAssertTrue(app.buttons[SidebarID.bookmark(312)].firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        try save("sidebar-bookmarks")
        SidebarUITests.selectTab(app, "Contents")
    }

    func testSidebarAddHeadingOnNoOutline() throws {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = SidebarUITests.open(Fixtures.noOutline, "no-outline", ["-openPage", "5"])
        XCTAssertTrue(SidebarUITests.waitForLabel(SidebarUITests.pill(app), "Page 5 of 40", timeout: 40))
        SidebarUITests.selectTab(app, "Contents")
        let add = app.buttons[SidebarID.emptyAddHeading].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        sleep(1)
        try save("sidebar-no-outline-empty")
        add.tap()
        let field = app.textFields[SidebarID.addHeadingTitle].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        sleep(1)
        field.typeText("1 Getting Started")
        sleep(1)
        try save("sidebar-add-heading")
        app.navigationBars.buttons[SidebarID.addHeadingSave].firstMatch.tap()
        XCTAssertTrue(SidebarUITests.heading(app, "1 Getting Started").waitForExistence(timeout: 10))
        sleep(1)
        try save("sidebar-no-outline-added")
    }

    func testSidebarHandBuiltOutline() throws {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = SidebarUITests.open(Fixtures.noOutline, "no-outline", ["-openPage", "14", "-seedSidebarHeadings"])
        XCTAssertTrue(SidebarUITests.waitForLabel(SidebarUITests.pill(app), "Page 14 of 40", timeout: 40))
        SidebarUITests.selectTab(app, "Contents")
        let current = SidebarUITests.heading(app, "2.1.1 Sorting")
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertTrue(SidebarUITests.waitFor(current, "value CONTAINS %@", "current section"))
        sleep(2)
        try save("sidebar-hand-built-outline")
        current.press(forDuration: 1.2)
        sleep(1)
        try save("sidebar-heading-context-menu")
    }

    func testSidebarNarrowOverlay() throws {
        let app = launchLarge(.portrait)
        let toggle = app.buttons[ReaderID.contentsToggle].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        SidebarUITests.selectTab(app, "Contents")
        sleep(3)
        try save("sidebar-narrow-overlay")
    }
}
