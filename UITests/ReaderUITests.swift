import XCTest

/// Reader shell: first page, go to page, relaunch restore, subtitle, panes, narrow
/// layout, two windows, the selection-menu hook.
@MainActor
final class ReaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func openLarge(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large) + ["-openBook", "large"] + extra)
    }

    /// `small.pdf` for tests that query panes: identifier queries over "any"/"other" elements
    /// walk PDFKit's per-page accessibility elements, which takes many seconds on `large.pdf`.
    private func openSmall(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"] + extra)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Drags the page area upward (scrolls down) without tapping anything.
    private func scrollPage(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[ReaderID.pagePill].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens the go-to-page field through More ▸ Go to Page… (the pill can sit under the
    /// system's "Hidden Windows" chip left by earlier multi-window runs) and types the number.
    /// Go to Page… through its keyboard shortcut (⌥⌘G) and types into the focused field.
    /// (Querying text fields over `large.pdf` walks PDFKit's page elements and is very slow, and
    /// the pill can sit under the system's "Hidden Windows" chip after multi-window runs.)
    ///
    /// iPadOS 17.5 simulator: XCUITest's ⌥-modified `typeKey` never opens the field (⇧⌘ and ⌘
    /// shortcuts work), so there the pill is tapped instead (no "Hidden Windows" chip on 17).
    private func goToPage(_ app: XCUIApplication, _ number: Int) {
        openGoToPageField(app)
        app.typeText("\(number)\n")
    }

    /// ⌥⌘ shortcuts are not delivered reliably by XCUITest on the iPadOS 17.5 simulator (and can
    /// leave ⌥ applied to the next key), so there the equivalent button is tapped, or the step is
    /// skipped when the button is optional to the test.
    private func optionShortcut(_ app: XCUIApplication, _ key: String, orTap identifier: String?) {
        if #available(iOS 26.0, *) {
            app.typeKey(key, modifierFlags: [.command, .option])
        } else if let identifier {
            app.buttons[identifier].firstMatch.tap()
        }
    }

    private func openGoToPageField(_ app: XCUIApplication) {
        // A hardware-key event sent before the window has become key is dropped: press again
        // if the field did not appear. The field takes focus as it appears; typing before
        // that is lost.
        let field = app.textFields[ReaderID.goToPageField].firstMatch
        for _ in 0..<3 {
            if #available(iOS 26.0, *) {
                app.typeKey("g", modifierFlags: [.command, .option])
            } else {
                pill(app).tap()
            }
            if field.waitForExistence(timeout: 3) { break }
        }
        field.waitForKeyboardFocus()
    }

    /// The navigation bar shows `text` (the subtitle on iOS 26+, the title block before).
    private func navigationBarShows(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let match = app.navigationBars.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    // MARK: Tests

    func testLargeFirstPageAppearsQuickly() {
        let started = Date()
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 1500"))
        // Generous bound: launch + fixture import (5 MB copy) + open + first page.
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testGoToPageThenRelaunchLandsOnSamePage() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        goToPage(app, 1200)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1200 of 1500"))
        // Let the debounced last-read save run (1 s), then background to flush anyway.
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.terminate()

        let again = XCUIApplication()
        again.launchArguments = ["-pagePillStaysVisible", "-openBook", "large"]
        again.launch()
        XCTAssertTrue(pill(again).waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(pill(again), "Page 1200 of 1500"))
    }

    /// The exact user path: tap the pill, type with the software keyboard up, Return. The page
    /// must stay on N afterwards (the keyboard's dismissal must not restore the old page), and
    /// Back returns to page 1. Portrait, so the pill sits above the notes sheet and is tappable.
    func testPillGoToPageOnSmallDocumentStaysAndBackReturns() {
        XCUIDevice.shared.orientation = .portrait
        let app = openSmall()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        pill(app).tap()
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("9\n")
        XCTAssertTrue(waitForLabel(pill(app), "Page 9 of 12"))
        // Once the field and the keyboard have gone, the page still has to be 9.
        XCTAssertTrue(field.waitForGone(), "the go-to-page field closed")
        XCTAssertTrue(app.keyboards.firstMatch.waitForGone(), "the keyboard closed")
        XCTAssertEqual(UIWait.settled(interval: 0.5) { pill(app).label }, "Page 9 of 12")
        let back = app.buttons[ReaderID.historyBack].firstMatch
        XCTAssertTrue(waitForEnabled(back))
        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        XCTAssertEqual(UIWait.settled(interval: 0.5) { pill(app).label }, "Page 1 of 12")
    }

    /// Without `-pagePillStaysVisible` the pill fades once the page stands still, and scrolling
    /// brings it back (it fades again afterwards). The fade's state is read from the
    /// `-exposeMarkupState` probe: XCUITest keeps listing a fully transparent button and cannot
    /// always tell whether it is hittable.
    func testPagePillFadesWhenIdleAndReturnsOnScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"] + XCUIApplication.importing(Fixtures.small)
            + ["-openBook", "small", "-exposeMarkupState"]
        app.launch()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30), "reader open")
        let state = app.buttons["reader.markupState"].firstMatch
        XCTAssertTrue(waitForValue(state, containing: "pill=idle pillReturns=0", timeout: 10), "pill fades when idle")
        scrollPage(app)
        XCTAssertTrue(waitForValue(state, containing: "pillReturns=1", timeout: 5), "scrolling brings the pill back")
        XCTAssertTrue(waitForValue(state, containing: "pill=idle pillReturns=1", timeout: 10), "pill fades again")
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testSubtitleShowsSectionAfterJump() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        XCTAssertTrue(navigationBarShows(app, "1 Linear Systems"))
        // Page 1150 is where "12.4 Structure" starts (before its first subsection).
        goToPage(app, 1150)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1150 of 1500"))
        XCTAssertTrue(navigationBarShows(app, "12.4 Structure"))
        goToPage(app, 1152)
        XCTAssertTrue(navigationBarShows(app, "12.4.1 Definitions"))
    }

    /// A finger tap on the page maximizes it (no toolbar, no panes); markup can be turned on
    /// while maximized (⇧⌘A) and carries on with the tool picker up; ending maximize brings the
    /// panes, page pill, and Markup toggle back as they were.
    ///
    /// In markup mode, tapping the page (simulating a finger) accounts for whether "Draw with
    /// finger" is enabled:
    /// - Enabled (`-inkAnyInput`, `fingerDraws=yes`): a tap draws (`undo=yes`) and does not
    ///   maximize or un-maximize.
    /// - Disabled (`-inkPencilOnly`, `fingerDraws=no`): a tap does not draw (`undo=no`) and
    ///   maximizes / un-maximizes while keeping markup on.
    func testTapMaximizesAndKeepsMarkupOn() {
        verifyTapMaximize(extraArgs: ["-inkAnyInput"])
        verifyTapMaximize(extraArgs: ["-inkPencilOnly"])
    }

    private func verifyTapMaximize(extraArgs: [String]) {
        let app = openSmall(["-notesPanel", "page", "-exposeMarkupState"] + extraArgs)
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let contents = element(app, ReaderID.contentsPane)
        let notes = element(app, ReaderID.notesPane)
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        XCTAssertTrue(notes.exists)
        let state = app.buttons["reader.markupState"].firstMatch
        let markup = app.buttons[ReaderID.markupToggle].firstMatch
        let page = element(app, ReaderID.pdfView)

        page.tap()
        XCTAssertTrue(markup.waitForNonExistence(timeout: 5), "a tap on the page hides the toolbar")
        XCTAssertTrue(contents.waitForNonExistence(timeout: 5))
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        XCTAssertTrue(pill(app).waitForNonExistence(timeout: 5), "the page pill is hidden")

        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForValue(state, containing: "markup=on picker=shown", timeout: 10),
                      "markup comes on while the page is maximized")
        let fingerDraws = (state.value as? String)?.contains("fingerDraws=yes") == true

        if fingerDraws {
            page.tap()
            XCTAssertFalse(markup.waitForExistence(timeout: 2),
                           "with Draw with finger enabled, a finger tap draws and does not end maximize")
            XCTAssertTrue(waitForValue(state, containing: "undo=yes", timeout: 5),
                          "the finger tap drew on the page")

            // Asking for a pane (`⌃⌘S` Show Contents) ends maximize while keeping markup on.
            app.typeKey("s", modifierFlags: [.command, .control])
            XCTAssertTrue(markup.waitForExistence(timeout: 5), "the toolbar is back")
            XCTAssertTrue(contents.waitForExistence(timeout: 5), "Contents is back as it was")
            XCTAssertTrue(notes.waitForExistence(timeout: 5), "the notes pane is back as it was")
            XCTAssertTrue(pill(app).waitForExistence(timeout: 5), "the page pill is back")
            XCTAssertTrue(waitForValue(state, containing: "markup=on picker=shown", timeout: 5))

            page.tap()
            XCTAssertTrue(markup.exists,
                          "with Draw with finger enabled, a finger tap draws and does not maximize")
            XCTAssertFalse(markup.waitForNonExistence(timeout: 1.5))
        } else {
            page.tap()
            XCTAssertTrue(markup.waitForExistence(timeout: 5),
                          "with Draw with finger disabled, a tap on the maximized page ends maximize")
            XCTAssertTrue(contents.waitForExistence(timeout: 5))
            XCTAssertTrue(notes.waitForExistence(timeout: 5))
            XCTAssertTrue(pill(app).waitForExistence(timeout: 5))
            XCTAssertTrue(waitForValue(state, containing: "markup=on picker=shown", timeout: 5))
            XCTAssertTrue(waitForValue(state, containing: "undo=no", timeout: 2),
                          "the finger tap did not draw")

            page.tap()
            XCTAssertTrue(markup.waitForNonExistence(timeout: 5),
                          "with Draw with finger disabled, a finger tap maximizes even in markup mode")
            page.tap()
            XCTAssertTrue(markup.waitForExistence(timeout: 5), "and tapping again ends maximize")
        }

        markup.tap()
        XCTAssertTrue(waitForValue(state, containing: "markup=off", timeout: 10), "markup can be left")

        page.tap()
        XCTAssertTrue(markup.waitForNonExistence(timeout: 5), "a tap maximizes again")
        page.tap()
        XCTAssertTrue(markup.waitForExistence(timeout: 5), "and a tap on the maximized page ends it")
    }

    func testContentsAndNotesTogglesInWideLayout() {
        let app = openSmall(["-notesPanel", "page"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let contents = element(app, ReaderID.contentsPane)
        let notes = element(app, ReaderID.notesPane)
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        XCTAssertTrue(notes.exists)
        // Both are plain buttons with no selected state; the Notes label says the state.
        let contentsButton = app.buttons[ReaderID.contentsToggle].firstMatch
        let notesButton = app.buttons[ReaderID.notesToggle].firstMatch
        XCTAssertTrue(waitForLabel(notesButton, "Hide Notes"))
        XCTAssertFalse(notesButton.isSelected, "no selected state")

        contentsButton.tap()
        XCTAssertTrue(contents.waitForNonExistence(timeout: 5))
        notesButton.tap()
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(notesButton, "Show Notes"))
        contentsButton.tap()
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        notesButton.tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(notesButton, "Hide Notes"))

        // A jump from Contents updates the page (and is recorded: Back becomes enabled).
        let chapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "2 Vector Spaces")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        chapter.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 5 of 12"))
        XCTAssertTrue(waitForEnabled(app.buttons[ReaderID.historyBack].firstMatch))
    }

    func testNarrowWidthUsesOverlayAndSheet() {
        XCUIDevice.shared.orientation = .portrait
        let app = openSmall(["-notesPanel", "page"])
        XCTAssertTrue(app.buttons[ReaderID.contentsToggle].waitForExistence(timeout: 30))
        // Notes is a sheet; Contents starts hidden and opens as an overlay.
        let sheet = element(app, ReaderID.notesSheet)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, ReaderID.contentsPane).exists)
        let overlay = element(app, ReaderID.contentsOverlay)
        XCTAssertFalse(overlay.exists)
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        app.buttons[ReaderID.contentsToggle].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        // The page stays usable behind the sheet: the pill moves above it.
        XCTAssertTrue(pill(app).isHittable)
        goToPage(app, 9)
        XCTAssertTrue(waitForLabel(pill(app), "Page 9 of 12"))
        // A wide window turns them back into panes and keeps the page.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element(app, ReaderID.contentsPane).waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, ReaderID.notesPane).exists)
        // The rotation has finished when the pill has stopped moving; the page is still 9.
        pill(app).waitForStableFrame()
        XCTAssertTrue(waitForLabel(pill(app), "Page 9 of 12"))
    }

    /// Section history: scrolling never records; Back/Forward return to the exact page left in
    /// each section; a new jump drops the forward entries.
    func testSectionHistoryBackForward() {
        let app = openLarge()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let back = app.buttons[ReaderID.historyBack].firstMatch
        let forward = app.buttons[ReaderID.historyForward].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        scrollPage(app)
        scrollPage(app)
        XCTAssertFalse(waitForLabel(pill(app), "Page 1 of 1500", timeout: 2))  // it scrolled
        XCTAssertFalse(back.isEnabled)                                         // but recorded nothing

        // A: "4.1.3 Summary" (pp. 311–317). Scroll a little inside it.
        goToPage(app, 311)
        XCTAssertTrue(waitForLabel(pill(app), "Page 311 of 1500"))
        scrollPage(app)
        scrollPage(app)
        scrollPage(app)
        // The page once the scroll has come to rest.
        let leftInA = UIWait.settled(interval: 0.5) { currentPage(app) }
        XCTAssertTrue((312...317).contains(leftInA), "scrolled to \(leftInA)")
        // B: "10.1.1 Definitions"; C: "13.4 Structure".
        goToPage(app, 905)
        XCTAssertTrue(waitForLabel(pill(app), "Page 905 of 1500"))
        goToPage(app, 1250)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1250 of 1500"))
        XCTAssertTrue(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 905 of 1500"))
        back.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page \(leftInA) of 1500"))  // the page left, not 311
        XCTAssertTrue(forward.isEnabled)
        forward.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 905 of 1500"))
        XCTAssertTrue(forward.isEnabled)

        goToPage(app, 50)
        XCTAssertTrue(waitForLabel(pill(app), "Page 50 of 1500"))
        XCTAssertFalse(forward.isEnabled)
        XCTAssertTrue(back.isEnabled)
    }

    private func currentPage(_ app: XCUIApplication) -> Int {
        // "Page N of 1500"
        let parts = pill(app).label.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? -1 : -1
    }

    /// `openReaderInNewWindow(bookID:pageIndex:)`: the new window opens at that page, once, and
    /// the book's stored last-read page is not touched to get there.
    func testNewWindowOpensAtRequestedPage() {
        let app = openSmall(["-alsoOpenWindow", "small", "-alsoOpenWindowPage", "9"])
        let pills = app.buttons.matching(identifier: ReaderID.pagePill)
        pills.waitForCount(atLeast: 2)
        XCTAssertEqual(pills.count, 2)
        // Both windows have their documents once neither pill changes any more.
        let labels = UIWait.settled(timeout: 10, interval: 0.5) {
            Set((0..<pills.count).map { pills.element(boundBy: $0).label })
        }
        XCTAssertEqual(labels, ["Page 1 of 12", "Page 9 of 12"])
        closeFrontWindow(app)
        if app.buttons.matching(identifier: ReaderID.pagePill).count > 1 { closeFrontWindow(app) }
    }

    /// Find (⇧⌘F) works in markup mode: the search panel opens and markup stays on.
    func testFindWorksInMarkupMode() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("hardware-key events (see the menu test)") }
        let app = openSmall(["-markup"])
        let toggle = app.buttons[ReaderID.markupToggle].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(toggle, "Done with Markup"), "markup on")
        // A hardware-key event sent before the window has become key is dropped: press again
        // if search did not open.
        let done = app.buttons["search.done"].firstMatch
        var opened = false
        for _ in 0..<3 where !opened {
            app.typeKey("f", modifierFlags: [.command, .shift])
            opened = done.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(opened, "search did not open")
        done.tap()
        XCTAssertTrue(waitForLabel(toggle, "Done with Markup"), "markup stays on after search")
        // The toolbar's search button is there in markup mode too.
        XCTAssertTrue(app.buttons["reader.toolbar.search"].firstMatch.exists)
    }

    /// Narrow width, iPadOS 26+: opening search makes the notes sheet step aside, and closing
    /// search brings it back (the notes stay "shown").
    func testSearchAndNarrowNotesSheetCoexist() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("the system notes sheet is iPadOS 26+") }
        XCUIDevice.shared.orientation = .portrait
        let app = openSmall(["-notesPanel", "page"])
        let sheet = element(app, ReaderID.notesSheet)
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        app.buttons["reader.toolbar.search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["search.done"].firstMatch.waitForExistence(timeout: 10), "search did not open")
        app.buttons["search.done"].firstMatch.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the notes sheet did not come back")
        // One tap on the search button opens search again over the returned sheet.
        app.buttons["reader.toolbar.search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["search.done"].firstMatch.waitForExistence(timeout: 10),
                      "search did not reopen after the notes sheet came back")
        app.buttons["search.done"].firstMatch.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the notes sheet did not come back a second time")
    }

    func testAlsoOpenWindowShowsSecondReaderWithIndependentPage() {
        let app = openSmall(["-openPage", "7", "-alsoOpenWindow", "small"])
        // Each reader window has its own page pill; both are in the hierarchy once the second opens.
        let pills = app.buttons.matching(identifier: ReaderID.pagePill)
        pills.waitForCount(atLeast: 2)
        XCTAssertEqual(pills.count, 2)
        // Move the front window only; the other keeps its page.
        let mores = app.buttons.matching(identifier: ReaderID.more)
        func frontMore() -> XCUIElement? {
            (0..<mores.count).map { mores.element(boundBy: $0) }.first { $0.isHittable }
        }
        XCTAssertTrue(UIWait.until { frontMore() != nil }, "the front window's More button")
        let front = frontMore()
        // Both windows have their documents once neither pill changes any more.
        let before = UIWait.settled(timeout: 10, interval: 0.5) {
            Set((0..<pills.count).map { pills.element(boundBy: $0).label })
        }
        front?.tap()
        let item = app.buttons["Go to Page…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        app.textFields[ReaderID.goToPageField].firstMatch.waitForKeyboardFocus()
        app.typeText("3\n")
        func labels() -> [String] { (0..<pills.count).map { pills.element(boundBy: $0).label } }
        XCTAssertTrue(UIWait.until { labels().contains("Page 3 of 12") }, "\(labels())")
        let after = labels()
        XCTAssertTrue(after.contains("Page 3 of 12"), "\(after)")
        XCTAssertEqual(after.count, 2)
        // The window not moved still shows a page it had before.
        XCTAssertFalse(Set(after.filter { $0 != "Page 3 of 12" }).isDisjoint(with: before), "\(before) → \(after)")
        XCTAssertEqual(app.state, .runningForeground)
        // Leave one window behind for later tests (system Close Window, ⌘W).
        // Best effort: if the first ⌘W reached no window (focus still settling), try once more.
        closeFrontWindow(app)
        if app.buttons.matching(identifier: ReaderID.pagePill).count > 1 { closeFrontWindow(app) }
    }

    /// Closes the focused window with the system Close command (test isolation: a window left
    /// open would be restored as a "hidden window" on later launches).
    private func closeFrontWindow(_ app: XCUIApplication) {
        let pills = app.buttons.matching(identifier: ReaderID.pagePill)
        let before = pills.count
        app.typeKey("w", modifierFlags: .command)
        // Closed when a reader has gone (callers press again if the key reached no window), or
        // when the app has left the foreground because that was its last window (it cannot be
        // queried then).
        _ = UIWait.until(timeout: 3) { app.state != .runningForeground || pills.count < before }
    }

    /// Regression for the main-menu crash ("Replacement elements contain duplicates", a reader
    /// shortcut equal to a system one): drive every state through keyboard shortcuts, which
    /// forces UIKit to rebuild and re-enumerate the main menu each time, and check the app is
    /// still alive afterwards (the crash was delayed and silent to earlier assertions).
    func testMenuCommandsStayStableAcrossStates() throws {
        // Driven by hardware-key events, which XCUITest does not deliver reliably on the iPadOS
        // 17.5 simulator (unverified on a real iPadOS 17 keyboard); routine 17 testing is
        // suspended, so below iOS 18 this test is skipped rather than left red.
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("hardware-key events are unreliable on the iPadOS 17.5 simulator")
        }
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        sleep(2)  // hardware-key events need the window to have become key
        app.typeKey("g", modifierFlags: [.command, .control])         // Next Result (no search: disabled)
        app.typeKey("g", modifierFlags: [.command, .control, .shift]) // Previous Result (disabled)
        app.typeKey("h", modifierFlags: [.command, .option])          // Add Heading at This Page…
        app.typeKey("a", modifierFlags: [.command, .shift])          // Markup
        XCTAssertTrue(waitForLabel(app.buttons[ReaderID.markupToggle].firstMatch, "Done with Markup"))
        app.typeKey("a", modifierFlags: [.command, .shift])          // Done with Markup
        XCTAssertTrue(waitForLabel(app.buttons[ReaderID.markupToggle].firstMatch, "Markup"))
        openGoToPageField(app)                                       // Go to Page… (a text field)
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("7\n")
        XCTAssertTrue(waitForLabel(pill(app), "Page 7 of 12"))
        app.typeKey("s", modifierFlags: [.command, .control])        // Contents
        optionShortcut(app, "0", orTap: ReaderID.notesToggle)        // Notes
        // The command is enabled from the same state as the toolbar button; wait for it.
        XCTAssertTrue(waitForEnabled(app.buttons[ReaderID.historyBack].firstMatch))
        sleep(1)
        app.typeKey("[", modifierFlags: .command)                    // Back (section history)
        XCTAssertTrue(waitForLabel(pill(app), "Page 1 of 12"))
        optionShortcut(app, XCUIKeyboardKey.downArrow.rawValue, orTap: nil)  // Next Page
        app.typeKey("l", modifierFlags: [.command, .shift])          // Back to Library
        let book = app.buttons["library.book.small"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)                    // disabled without a reader
        book.tap()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 15))
        optionShortcut(app, "n", orTap: nil)                         // Open in New Window
        sleep(3)
        app.typeKey("s", modifierFlags: [.command, .control])
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground)
        closeFrontWindow(app)

        let two = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-openBook", "small", "-alsoOpenWindow", "small"])
        XCTAssertTrue(pill(two).waitForExistence(timeout: 30))
        sleep(3)
        two.typeKey("a", modifierFlags: [.command, .shift])
        two.typeKey("a", modifierFlags: [.command, .shift])
        two.typeKey("l", modifierFlags: [.command, .shift])
        sleep(2)
        XCTAssertEqual(two.state, .runningForeground)
        closeFrontWindow(two)
    }

    /// Markup mode shows the window's system tool picker; tapping the Markup toggle again hides
    /// it. Also from launch (-markup). Each entry shows it exactly once (TSOFT-219: no hide and
    /// show while the first show settles, nor while the reader is pushed at launch).
    func testMarkupModeShowsToolPicker() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-openBook", "small", "-exposeMarkupState"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let toggle = app.buttons[ReaderID.markupToggle].firstMatch
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Done with Markup"), "markup on")
        XCTAssertTrue(waitForState(app, "picker=shown"))
        settle(app)
        XCTAssertTrue(waitForState(app, "shows=1 "), "first entry shows the picker once")
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Markup"), "markup off")
        XCTAssertTrue(waitForState(app, "picker=hidden"))
        toggle.tap()
        XCTAssertTrue(waitForState(app, "picker=shown"), "shown again")
        settle(app)
        XCTAssertTrue(waitForState(app, "shows=2 "), "second entry shows it once more")

        let launched = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                                   + ["-openBook", "small", "-markup", "-exposeMarkupState"])
        let toggleAtLaunch = launched.buttons[ReaderID.markupToggle].firstMatch
        XCTAssertTrue(toggleAtLaunch.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(toggleAtLaunch, "Done with Markup"), "markup on at launch")
        XCTAssertTrue(waitForState(launched, "picker=shown"))
        settle(launched)
        XCTAssertTrue(waitForState(launched, "shows=1 "), "shown once at launch, after the reader is pushed")
    }

    /// Taps the markup probe's Undo button (nothing to undo; it never moves first responder). An
    /// action makes XCUITest wait for the app to go idle first, so the reader's push and the
    /// picker's own animations have finished when the probe is read next.
    private func settle(_ app: XCUIApplication) {
        app.buttons["reader.markupUndo"].firstMatch.tap()
    }

    /// On a portrait phone, markup mode swaps the section Back / Forward out of the toolbar for
    /// the ink Undo / Redo, and turning markup off brings them back (design, "Section history").
    func testPortraitPhoneMarkupHidesSectionHistoryButtons() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("the swap is for a portrait phone-shaped window")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let back = app.buttons["reader.toolbar.historyBack"].firstMatch
        let forward = app.buttons["reader.toolbar.historyForward"].firstMatch
        let undo = app.buttons["reader.toolbar.undo"].firstMatch
        let toggle = app.buttons[ReaderID.markupToggle].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back shows while reading")
        XCTAssertTrue(forward.exists, "Forward shows while reading")

        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Done with Markup"))
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo shows in markup mode")
        XCTAssertTrue(app.buttons["reader.toolbar.redo"].firstMatch.exists, "Redo shows in markup mode")
        XCTAssertFalse(back.exists, "Back steps aside in markup mode")
        XCTAssertFalse(forward.exists, "Forward steps aside in markup mode")

        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Markup"))
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is back after markup")
        XCTAssertTrue(forward.exists, "Forward is back after markup")
        XCTAssertFalse(undo.exists, "Undo leaves with markup")
    }

    /// The Markup toggle is the only switch (design, "Markup controls"): the same button in
    /// both modes, its filled glyph (no selected background) while markup is on, no Done button, and at regular width
    /// no toolbar Undo/Redo (the tool picker has its own); the rest of the toolbar stays, and
    /// the subtitle keeps showing only the place.
    func testMarkupToggleIsSelectedInMarkupModeWithNoDoneButton() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-openBook", "small"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let toggle = app.buttons[ReaderID.markupToggle].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Markup", "outlined while off")

        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Done with Markup"), "filled while on")
        XCTAssertFalse(toggle.isSelected, "no selected background")
        XCTAssertFalse(app.buttons["reader.toolbar.done"].exists, "no Done button")
        XCTAssertFalse(app.navigationBars.buttons["Done"].exists, "no Done button")
        XCTAssertFalse(app.buttons["reader.toolbar.undo"].exists, "Undo is the tool picker's at regular width")
        XCTAssertFalse(app.buttons["reader.toolbar.redo"].exists, "Redo is the tool picker's at regular width")
        XCTAssertTrue(app.buttons[ReaderID.more].firstMatch.exists, "same toolbar in markup mode")
        XCTAssertTrue(app.buttons[ReaderID.notesToggle].firstMatch.exists, "same toolbar in markup mode")
        let markupPrefix = app.navigationBars.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Markup ·", "Markup ·"))
        XCTAssertEqual(markupPrefix.count, 0, "the subtitle has no Markup prefix")

        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Markup"), "outlined again")
    }

    /// Trailing toolbar icons appear left-to-right as: Markup, Notes, Bookmark, Search, More.
    func testTrailingToolbarButtonOrder() {
        let app = openSmall()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let markup = app.buttons[ReaderID.markupToggle].firstMatch
        let notes = app.buttons[ReaderID.notesToggle].firstMatch
        let bookmark = app.buttons[ReaderID.bookmark].firstMatch
        let search = app.buttons[ReaderID.search].firstMatch
        let more = app.buttons[ReaderID.more].firstMatch
        for button in [markup, notes, bookmark, search, more] {
            XCTAssertTrue(button.waitForExistence(timeout: 5))
        }
        XCTAssertLessThanOrEqual(markup.frame.maxX, notes.frame.minX, "Markup before Notes")
        XCTAssertLessThanOrEqual(notes.frame.maxX, bookmark.frame.minX, "Notes before Bookmark")
        XCTAssertLessThanOrEqual(bookmark.frame.maxX, search.frame.minX, "Bookmark before Search")
        XCTAssertLessThanOrEqual(search.frame.maxX, more.frame.minX, "Search before More")
    }

    /// With a registered surface that takes first responder (as a canvas does), the picker stays.
    func testToolPickerStaysWithRegisteredSurface() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-openBook", "small", "-markupProbeSurface", "-exposeMarkupState"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        let toggle = app.buttons[ReaderID.markupToggle].firstMatch
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Done with Markup"))
        XCTAssertTrue(waitForState(app, "responder=surface"), "the probe canvas is first responder")
        XCTAssertTrue(waitForState(app, "picker=shown"))
        // It stays: still so once the probe has stopped changing.
        let probe = app.buttons["reader.markupState"].firstMatch
        let settled = UIWait.settled(interval: 0.5) { probe.value as? String ?? "" }
        XCTAssertTrue(settled.contains("responder=surface") && settled.contains("picker=shown"), settled)
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        let suffix = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18 ? "-ios17" : ""
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("reader-markup-surface\(suffix).png"))
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Markup"))
    }

    private func waitForEnabled(_ element: XCUIElement, _ enabled: Bool = true, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the `-exposeMarkupState` probe (`reader.markupState`) to hold `token` (e.g.
    /// "picker=shown"). Toolbar items carry no accessibility value to XCUITest on iPadOS 26+.
    private func waitForState(_ app: XCUIApplication, _ token: String, timeout: TimeInterval = 10) -> Bool {
        let probe = app.buttons["reader.markupState"].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", token), object: probe)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testSelectionMenuHookAddsAction() {
        let app = openSmall(["-selectionMenuProbe"])
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        // Long-press a word in the body text to select it and show the edit menu.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Probe"].firstMatch.waitForExistence(timeout: 5)
                      || app.menuItems["Probe"].firstMatch.waitForExistence(timeout: 2))
    }

    func testSingleTapOffSelectedTextDeselectsWithoutMaximizing() {
        let app = openSmall(["-openPage", "3", "-exposeSelection"])
        XCTAssertTrue(selectionProbe(app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(pill(app), "Page 3 of 12"), "opened at page 3")
        let markup = app.buttons[ReaderID.markupToggle].firstMatch
        let pdfView = app.otherElements[ReaderID.pdfView].firstMatch

        let wordPoint = selectAmber(app)
        XCTAssertNotEqual(selectionProbe(app).label, "none")
        XCTAssertTrue(markup.exists, "long-pressing to select text does not maximize the page")

        // Tapping on the selected word keeps the selection.
        wordPoint.tap()
        XCTAssertFalse(UIWait.until(timeout: 0.6) { selectionProbe(app).label == "none" },
                       "tapping on selected text keeps the selection")
        XCTAssertTrue(markup.exists, "tapping on selected text does not maximize")

        // Single-tapping blank page space off the text clears the selection without maximizing.
        pdfView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertTrue(UIWait.until(timeout: 5) { selectionProbe(app).label == "none" },
                      "single tap on blank space deselects")
        XCTAssertTrue(markup.exists, "deselecting tap does not maximize the page")

        // With nothing selected, the next single tap on the page maximizes it (and back).
        pdfView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertTrue(markup.waitForNonExistence(timeout: 5), "tap with no selection maximizes")
        pdfView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertTrue(markup.waitForExistence(timeout: 5), "tap on maximized page exits")

        // Single-tapping in the margin outside the page also clears the selection without maximizing.
        selectAmber(app)
        XCTAssertNotEqual(selectionProbe(app).label, "none")
        pdfView.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertTrue(UIWait.until(timeout: 5) { selectionProbe(app).label == "none" },
                      "single tap in the margin deselects")
        XCTAssertTrue(markup.exists)
    }

    // MARK: Select All selects the paragraph

    private func selectionProbe(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["reader.selectionProbe"].firstMatch
    }

    /// Long-presses the word "amber" on page 3 of `small.pdf` (the one-line paragraph "Remember
    /// that the quick amber fox annotates margins.") and waits for the selection.
    @discardableResult
    private func selectAmber(_ app: XCUIApplication) -> XCUICoordinate {
        let pdfView = app.otherElements[ReaderID.pdfView].firstMatch
        let line = pdfView.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "quick amber fox")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "page 3's special line is not exposed")
        let frame = line.frame
        print("SELECT-ALL line element frame: \(frame)")
        // A line element: "amber" is about 45 % along it. A page element: the line is the first
        // body line, about 12 % down the page at 22 % across.
        let point = frame.height < 60
            ? CGVector(dx: 0.53, dy: 0.5)
            : CGVector(dx: 0.30, dy: (792 - 690) / 792.0)
        // A long press right after the previous selection was cleared is sometimes taken for
        // something else; press again until a word is selected.
        for _ in 0..<3 {
            line.coordinate(withNormalizedOffset: point).press(forDuration: 1.2)
            if UIWait.until(timeout: 4, poll: 0.2, { selectionProbe(app).label != "none" }) { break }
        }
        print("SELECT-ALL selected: \(selectionProbe(app).label) [\(selectionProbe(app).value ?? "")]")
        return line.coordinate(withNormalizedOffset: point)
    }

    private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
        for candidate in [app.buttons[title].firstMatch, app.menuItems[title].firstMatch] where candidate.exists {
            return candidate
        }
        return nil
    }

    /// Select All in the edit menu grows a word to its paragraph, on its page only, and the
    /// result is a normal selection (the edit menu still offers Copy); ⌘A does the same; in the
    /// go-to-page field ⌘A keeps its normal meaning.
    func testSelectAllSelectsTheParagraph() throws {
        let app = openSmall(["-openPage", "3", "-exposeSelection"])
        XCTAssertTrue(selectionProbe(app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(pill(app), "Page 3 of 12"), "opened at page 3")
        let pillBefore = pill(app).label
        selectAmber(app)
        let word = selectionProbe(app).label
        XCTAssertTrue(word != "none" && !word.contains(" ")
                      && "Remember that the quick amber fox annotates margins.".contains(word),
                      "no word of the line selected: \(word)")
        // The edit menu's Select All (behind the menu's "more" arrow if it is not on the first row).
        var selectAll = menuItem(app, "Select All")
        if selectAll == nil, let more = menuItem(app, "Forward") ?? menuItem(app, "Show more items") {
            more.tap()
            selectAll = menuItem(app, "Select All")
        }
        let item = try XCTUnwrap(selectAll, "Select All is not in the edit menu")
        item.tap()
        let paragraph = "Remember that the quick amber fox annotates margins."
        _ = UIWait.until(timeout: 5, poll: 0.2) { selectionProbe(app).label.contains(paragraph) }
        let label = selectionProbe(app).label.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = selectionProbe(app).value as? String ?? ""
        print("SELECT-ALL after menu: \(label) [\(value)]")
        XCTAssertEqual(label, paragraph)
        XCTAssertTrue(value.hasPrefix("pages 2;"), "the selection touches other pages: \(value)")
        XCTAssertEqual(pill(app).label, pillBefore, "the page moved")
        XCTAssertFalse(app.buttons[ReaderID.historyBack].firstMatch.isEnabled, "Select All recorded history")

        // ⌘A on a fresh word selection.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.6)).tap()
        XCTAssertTrue(UIWait.until(timeout: 5) { selectionProbe(app).label == "none" },
                      "the tap cleared the selection")
        let wordPoint = selectAmber(app)
        // After a long press, XCUITest's synthesized ⌘A reaches the app only with the next touch
        // on the page (measured with a route trace: the app then runs Select All on
        // PDFDocumentView, before that touch's own effect). A tap on the selected word, which
        // only toggles the edit menu, delivers it (up to three taps: one is not always enough).
        print("SELECT-ALL before ⌘A: \(selectionProbe(app).label)")
        app.typeKey("a", modifierFlags: .command)
        for _ in 0..<3 where !selectionProbe(app).label.contains(paragraph) {
            sleep(1)
            wordPoint.tap()
            _ = UIWait.until(timeout: 5, poll: 0.2) { selectionProbe(app).label.contains(paragraph) }
        }
        print("SELECT-ALL after ⌘A: \(selectionProbe(app).label) [\(selectionProbe(app).value ?? "")]")
        // Not held against the test: after a long press the synthesized key is delivered in some
        // runs and not others (delivered in 2 of 5 runs on iOS 27; when delivered, the result was
        // always the paragraph through PDFDocumentView's selectAll:). Not verified on a device.
        XCTExpectFailure("XCUITest's synthesized ⌘A after a long press on the PDF is not always delivered",
                         strict: false) {
            XCTAssertEqual(selectionProbe(app).label.trimmingCharacters(in: .whitespacesAndNewlines), paragraph, "⌘A")
        }

        // In a real text field ⌘A selects the field's text: typing replaces it.
        pill(app).tap()
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("12")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("7")
        XCTAssertEqual(field.value as? String, "7", "⌘A in the go-to-page field")
    }

    func testMoreMenuNewWindowOptionsFollowMultiWindowSupport() {
        let app = openSmall()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        app.buttons[ReaderID.more].firstMatch.tap()
        XCTAssertTrue(app.buttons["Notebook"].firstMatch.waitForExistence(timeout: 5), "Notebook in the More menu")
        let openInNewWindow = app.buttons["Open in New Window"].firstMatch
        let openNotebookInNewWindow = app.buttons["Open Notebook in New Window"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(openInNewWindow.exists, "Open in New Window is hidden on iPhone")
            XCTAssertFalse(openNotebookInNewWindow.exists, "Open Notebook in New Window is hidden on iPhone")
        } else {
            XCTAssertTrue(openInNewWindow.exists, "Open in New Window is shown on iPad")
            XCTAssertTrue(openNotebookInNewWindow.exists, "Open Notebook in New Window is shown on iPad")
        }
    }

    func testGoToPageFieldUsesNumberPadAndRejectsNonDigits() {
        XCUIDevice.shared.orientation = .portrait
        let app = openSmall()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 30))
        pill(app).tap()
        let field = app.textFields[ReaderID.goToPageField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        sleep(1)
        let shotDir = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("numpad-ipad-uitextfield.png"))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "number pad appears")
        XCTAssertTrue(keyboard.keys["1"].exists || keyboard.buttons["1"].exists, "num pad has digit keys")
        XCTAssertFalse(keyboard.keys["A"].exists || keyboard.keys["a"].exists || keyboard.keys["Q"].exists || keyboard.keys["q"].exists,
                       "num pad does not show letter keys")
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(keyboard.keys["."].exists || keyboard.keys["-"].exists || keyboard.keys["/"].exists,
                           "num pad does not show punctuation keys")
        }

        let goButton = app.buttons[ReaderID.goToPageGo].firstMatch
        XCTAssertTrue(goButton.exists)
        XCTAssertFalse(goButton.isEnabled, "Go is disabled while the field is empty")

        field.typeText("1")
        field.typeText("a")
        field.typeText("-")
        field.typeText("2")
        XCTAssertEqual(field.value as? String, "12", "non-digits are stripped")
        XCTAssertTrue(goButton.isEnabled)
        goButton.tap()
        XCTAssertTrue(waitForLabel(pill(app), "Page 12 of 12"))
    }
}

/// Mirrors `AccessibilityID.Reader` in the app (the test target cannot import it).
enum ReaderID {
    static let pdfView = "reader.pdfView"
    static let contentsToggle = "reader.toolbar.contents"
    static let historyBack = "reader.toolbar.historyBack"
    static let historyForward = "reader.toolbar.historyForward"
    static let notesToggle = "reader.toolbar.notes"
    static let markupToggle = "reader.toolbar.markup"
    static let bookmark = "reader.toolbar.bookmark"
    static let search = "reader.toolbar.search"
    static let more = "reader.toolbar.more"
    static let pagePill = "reader.pagePill"
    static let goToPageField = "reader.goToPageField"
    static let goToPageGo = "reader.goToPageGo"
    static let contentsPane = "reader.pane.contents"
    static let contentsOverlay = "reader.pane.contentsOverlay"
    static let notesPane = "reader.pane.notes"
    static let notesSheet = "reader.pane.notesSheet"
}
