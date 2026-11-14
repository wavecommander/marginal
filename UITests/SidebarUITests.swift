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
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
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
        app.buttons[SidebarID.addHeadingSave].firstMatch.tap()

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
        let field = app.textFields[SidebarID.renameField].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText("Chapter Beta")
        app.alerts.buttons["Rename"].firstMatch.tap()
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
        XCTAssertTrue(app.buttons[ReaderID.historyBack].firstMatch.isEnabled)

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
        XCTAssertTrue(Self.waitFor(target, "value CONTAINS %@", "current page"))
        XCTAssertTrue(app.buttons[ReaderID.historyBack].firstMatch.isEnabled)
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
        sleep(2)
        let start = Self.parse(stats.value as? String ?? "")
        stats.tap()  // reset frame counters
        let grid = app.scrollViews["sidebar.pages.grid"].firstMatch
        XCTAssertTrue(grid.exists)
        let started = Date()
        for _ in 0..<25 { grid.swipeUp(velocity: .fast) }
        let downSeconds = Date().timeIntervalSince(started)
        sleep(2)
        let afterDown = Self.parse(stats.value as? String ?? "")
        for _ in 0..<25 { grid.swipeDown(velocity: .fast) }
        sleep(2)
        let end = Self.parse(stats.value as? String ?? "")
        let report = """
            thumbnails: start \(start)
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
        XCTAssertGreaterThan(afterDown["cancelled"] ?? 0, 0, "cells that flew past were cancelled")
        // The whole book is never rendered by a fling.
        XCTAssertLessThan(afterDown["rendered"] ?? .infinity, 1_500)
        // Bounded growth (generous: simulator footprints include the PDF view's own caches).
        XCTAssertLessThan((end["footprintMB"] ?? 0) - (start["footprintMB"] ?? 0), 400)
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
        XCUIDevice.shared.orientation = .landscapeLeft
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
        XCUIDevice.shared.orientation = .landscapeLeft
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
        app.buttons[SidebarID.addHeadingSave].firstMatch.tap()
        XCTAssertTrue(SidebarUITests.heading(app, "1 Getting Started").waitForExistence(timeout: 10))
        sleep(1)
        try save("sidebar-no-outline-added")
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
