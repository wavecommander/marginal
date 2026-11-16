import XCTest

/// Page ink (WP6): persistence across relaunch, undo/redo (through the markup responder's undo
/// manager, as the tool picker's buttons), read-only ink and scrolling
/// outside markup mode, two-finger scroll and pinch while a finger can draw, a second window on
/// the same book, registration under zoom, the page and note canvases in one markup session,
/// and the screenshots. Fingers draw through `-inkAnyInput` (the simulator cannot make Pencil
/// touches). Queries are typed and scoped to the PDF view (`.any` over PDFKit's element tree is
/// slow and floods XCTest's logging on iPadOS 17.5).
@MainActor
final class PageInkUITests: XCTestCase {
    // Mirrors `PageInkAccessibilityID` and `AccessibilityID.Reader` (the test target cannot
    // import the app).
    private enum ID {
        static func ink(_ n: Int) -> String { "pageInk.ink.\(n)" }
        static let pdfView = "reader.pdfView"
        static let undo = "reader.toolbar.undo"
        static let redo = "reader.toolbar.redo"
        static let markupToggle = "reader.toolbar.markup"
        static let notesToggle = "reader.toolbar.notes"
        /// `-exposeMarkupState` probe (`ReaderStateProbe`).
        static let markupState = "reader.markupState"
        static let markupUndo = "reader.markupUndo"
        static let markupRedo = "reader.markupRedo"
        static let noteText = "notePage.text"
        static let noteInk = "notePage.ink"
        static let noteEditor = "notePage.editor"
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    /// `small.pdf` at `page` (1-based).
    private func launch(fresh: Bool = true, page: Int = 3, _ extra: [String] = []) -> XCUIApplication {
        let arguments = ["-openBook", "small", "-openPage", "\(page)"] + extra
        let app: XCUIApplication
        if fresh {
            app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + arguments)
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-pagePillStaysVisible"] + arguments
            app.launch()
        }
        XCTAssertTrue(pdf(app).waitForExistence(timeout: 30), "PDF view")
        sleep(2)  // the first page is positioned and its overlay loaded
        if !extra.contains("-alsoOpenWindow") { closeStrayWindows(app) }
        return app
    }

    /// A reader window left open by an earlier failed multi-window test is restored by the
    /// system on every launch and can sit in front of the window under test: close it.
    private func closeStrayWindows(_ app: XCUIApplication) {
        var attempts = 0
        while app.otherElements.matching(identifier: ID.pdfView).count > 1 && attempts < 3 {
            app.typeKey("w", modifierFlags: .command)
            sleep(2)
            attempts += 1
        }
    }

    private func pdf(_ app: XCUIApplication) -> XCUIElement {
        app.otherElements[ID.pdfView].firstMatch
    }

    private func ink(_ app: XCUIApplication, page: Int = 3) -> XCUIElement {
        pdf(app).images[ID.ink(page)].firstMatch
    }

    /// A finger stroke across the page at normalised PDF-view position (x, y).
    private func drawLine(_ app: XCUIApplication, x: CGFloat = 0.3, y: CGFloat = 0.4, length: CGFloat = 200) {
        let start = pdf(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: length, dy: 6)))
    }

    private func wait(_ element: XCUIElement, _ format: String, _ arguments: [Any] = [], timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Undo / Redo of ink at regular width: the tool picker's own buttons are not reliably
    /// addressable, so the tests call `undo()` / `redo()` on the markup responder's undo manager
    /// (the call the picker's buttons make) through the `-exposeMarkupState` probe buttons.
    /// Not ⌘Z / ⇧⌘Z: XCTest's synthesized key events after a touch on the page are often lost
    /// on the iPadOS 27 simulator (the first ⌘Z after two strokes never reached the app in 2 of
    /// 3 runs; the next one did and undid correctly).
    private func undo(_ app: XCUIApplication) { app.buttons[ID.markupUndo].firstMatch.tap() }
    private func redo(_ app: XCUIApplication) { app.buttons[ID.markupRedo].firstMatch.tap() }

    /// The `-exposeMarkupState` probe: markup, tool picker, responder and undo state as
    /// `key=value` tokens (toolbar items carry no accessibility value to XCUITest).
    private func state(_ app: XCUIApplication, has token: String, timeout: TimeInterval = 10) -> Bool {
        wait(app.buttons[ID.markupState].firstMatch, "value CONTAINS %@", [token], timeout: timeout)
    }

    /// Leaves markup mode with the Markup toggle (there is no Done button).
    private func leaveMarkup(_ app: XCUIApplication) {
        let toggle = app.buttons[ID.markupToggle].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(wait(toggle, "isSelected == false"), "markup off")
    }

    private func strokes(_ element: XCUIElement, _ count: Int, timeout: TimeInterval = 10) -> Bool {
        wait(element, "exists == true AND value == %@", [count == 1 ? "1 stroke" : "\(count) strokes"], timeout: timeout)
    }

    // MARK: Persistence

    /// The WP6 "done when": draw on page 3 of `small.pdf`, relaunch, the stroke is still there.
    func testStrokeOnPage3IsThereAfterRelaunch() {
        let app = launch(["-markup", "-inkAnyInput"])
        drawLine(app)
        XCTAssertTrue(strokes(ink(app), 1), "stroke drawn on page 3")
        let before = ink(app).frame
        leaveMarkup(app)  // leaving markup flushes the ink
        sleep(1)
        app.terminate()

        let again = launch(fresh: false)
        XCTAssertTrue(strokes(ink(again), 1), "stroke restored")
        let after = ink(again).frame
        XCTAssertEqual(after.minX, before.minX, accuracy: 2)
        XCTAssertEqual(after.minY, before.minY, accuracy: 2)
        XCTAssertEqual(after.width, before.width, accuracy: 2)
    }

    // MARK: Undo and redo

    /// At regular width ink undo/redo are the tool picker's (no toolbar buttons). The picker
    /// drives them from the markup responder's undo manager (the routing proxy): the responder
    /// must be first responder, its manager must act on the page, and a listener of it must
    /// hear canUndo / canRedo.
    func testUndoAndRedoActOnThePage() throws {
        let app = launch(["-markup", "-inkAnyInput", "-exposeMarkupState"])
        XCTAssertFalse(app.buttons[ID.undo].exists, "no toolbar Undo at regular width")
        XCTAssertFalse(app.buttons[ID.redo].exists, "no toolbar Redo at regular width")
        XCTAssertTrue(state(app, has: "undo=no redo=no"), "nothing to undo yet")
        drawLine(app, y: 0.35)
        XCTAssertTrue(strokes(ink(app), 1))
        drawLine(app, y: 0.5)
        XCTAssertTrue(strokes(ink(app), 2))
        XCTAssertTrue(state(app, has: "responder=markup"), "the markup responder carries the picker")
        XCTAssertTrue(state(app, has: "undo=yes redo=no heardUndo=yes heardRedo=no"), "a listener hears canUndo")
        undo(app)
        XCTAssertTrue(strokes(ink(app), 1), "undo removed the last stroke")
        undo(app)
        XCTAssertTrue(wait(ink(app), "exists == false"), "undo removed the first stroke")
        XCTAssertTrue(state(app, has: "undo=no redo=yes heardUndo=no heardRedo=yes"), "a listener hears all undone")
        redo(app)
        XCTAssertTrue(strokes(ink(app), 1), "redo")
        redo(app)
        XCTAssertTrue(strokes(ink(app), 2), "redo again")
        redo(app)
        sleep(1)
        XCTAssertEqual(ink(app).value as? String, "2 strokes", "nothing left to redo")
        XCTAssertTrue(state(app, has: "undo=yes redo=no heardUndo=yes heardRedo=no"))
    }

    // MARK: Reading mode

    /// Outside markup mode the ink is read-only and the canvases take no touches: a finger
    /// drag scrolls the page and draws nothing.
    func testInkIsReadOnlyAndAFingerScrollsOutsideMarkupMode() {
        let app = launch(["-markup", "-inkAnyInput"])
        drawLine(app)
        XCTAssertTrue(strokes(ink(app), 1))
        leaveMarkup(app)
        let before = ink(app).frame
        // A sideways drag across text and a vertical drag: neither draws.
        drawLine(app, y: 0.55)
        let start = pdf(app).coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)))
        sleep(2)
        XCTAssertEqual(ink(app).value as? String, "1 stroke", "no ink outside markup mode")
        XCTAssertLessThan(ink(app).frame.minY, before.minY - 100, "the page scrolled under one finger")
    }

    // MARK: Fingers in markup mode

    /// With finger drawing allowed (`-inkAnyInput`), one finger draws and two fingers still
    /// scroll and zoom the PDF. Portrait with the notes sheet hidden: XCTest's synthesized
    /// multi-touch reaches the app only in portrait on these simulators.
    func testTwoFingersScrollAndZoomWhileAFingerDraws() throws {
        try XCTSkipUnless(MultiTouch.isAvailable, "XCTest's event synthesizer is not available")
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["-markup", "-inkAnyInput"])
        app.buttons[ID.notesToggle].firstMatch.tap()
        sleep(1)
        drawLine(app, x: 0.3, y: 0.45)
        XCTAssertTrue(strokes(ink(app), 1))
        let frame = pdf(app).frame
        let before = ink(app).frame
        try MultiTouch.drag(from: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.6), by: CGVector(dx: 0, dy: -150),
                            orientation: .portrait)
        sleep(2)
        let scrolled = ink(app).frame
        XCTAssertLessThan(scrolled.minY, before.minY - 60, "two fingers scrolled")
        XCTAssertEqual(ink(app).value as? String, "1 stroke", "two fingers drew nothing")
        try MultiTouch.spread(at: CGPoint(x: frame.midX, y: frame.midY), from: 100, to: 400, orientation: .portrait)
        sleep(2)
        XCTAssertGreaterThan(ink(app).frame.width, scrolled.width * 1.5, "a pinch zoomed")
        XCTAssertEqual(ink(app).value as? String, "1 stroke", "the pinch drew nothing")
    }

    // MARK: Two windows

    /// A stroke drawn in one window appears in a second window on the same book.
    func testStrokeAppearsInASecondWindowOnTheSameBook() throws {
        let app = launch(page: 1, ["-inkAnyInput", "-alsoOpenWindow", "small"])
        let views = app.otherElements.matching(identifier: ID.pdfView)
        // Always leave one window (system Close Window, ⌘W), as WP4's tests do, even when an
        // assertion fails: a window left open is restored into every later launch.
        addTeardownBlock { @MainActor in
            for _ in 0..<2 where app.otherElements.matching(identifier: ID.pdfView).count > 1 {
                app.typeKey("w", modifierFlags: .command)
                sleep(2)
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while views.count < 2 && Date() < deadline { usleep(250_000) }
        XCTAssertEqual(views.count, 2, "two reader windows")
        sleep(2)
        let toggles = app.buttons.matching(identifier: ID.markupToggle)
        let front = try XCTUnwrap((0..<toggles.count).map { toggles.element(boundBy: $0) }.first { $0.isHittable })
        front.tap()
        sleep(1)
        let target = try XCTUnwrap((0..<views.count).map { views.element(boundBy: $0) }.first { $0.isHittable })
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 200, dy: 6)))
        // Both windows show page 1 with the stroke: the drawing window at once, the other
        // after the debounced save.
        let inks = app.images.matching(NSPredicate(format: "identifier == %@ AND value == %@", ID.ink(1), "1 stroke"))
        let inkDeadline = Date().addingTimeInterval(15)
        while inks.count < 2 && Date() < inkDeadline { usleep(250_000) }
        XCTAssertEqual(inks.count, 2, "the stroke is in both windows")
    }

    // MARK: Zoom

    /// A stroke drawn over a phrase stays on it after zooming in (registration), and is
    /// re-rendered at the zoomed scale (the screenshot `pageink-zoomed-detail`).
    func testStrokeStaysOnTheSameWordsWhenZoomed() throws {
        let app = launch(["-markup", "-inkAnyInput"])
        let paragraph = pdf(app).staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Obtain show product")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        let p0 = paragraph.frame
        let start = paragraph.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p0.width * 0.25, dy: 10))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: p0.width * 0.4, dy: 1)))
        XCTAssertTrue(strokes(ink(app), 1))
        func relative(_ ink: CGRect, _ p: CGRect) -> (CGFloat, CGFloat, CGFloat) {
            ((ink.midX - p.minX) / p.width, (ink.midY - p.minY) / p.height, ink.width / p.width)
        }
        let before = relative(ink(app).frame, p0)
        for _ in 0..<4 { app.typeKey("+", modifierFlags: .command) }
        sleep(2)
        let p1 = paragraph.frame
        XCTAssertGreaterThan(p1.width, p0.width * 1.4, "zoomed in")
        let after = relative(ink(app).frame, p1)
        XCTAssertEqual(after.0, before.0, accuracy: 0.02, "same place along the line")
        XCTAssertEqual(after.1, before.1, accuracy: 0.03, "same line")
        XCTAssertEqual(after.2, before.2, accuracy: 0.02, "scaled with the text")
        try saveScreenshot("pageink-zoomed-detail")
    }

    // MARK: Page and note together

    /// One markup session inks the page and the note: both canvases take ink with the one
    /// picker, and Undo follows the surface last drawn on.
    func testPageAndNoteCanvasesBothTakeInk() throws {
        let app = launch(["-markup", "-inkAnyInput", "-notesPanel", "page", "-exposeMarkupState"])
        let noteText = app.textViews[ID.noteText].firstMatch
        XCTAssertTrue(noteText.waitForExistence(timeout: 15))
        drawLine(app)
        XCTAssertTrue(strokes(ink(app), 1), "page stroke")
        let note = noteText.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 160))
        note.press(forDuration: 0.2, thenDragTo: note.withOffset(CGVector(dx: 160, dy: 2)))
        let noteInk = app.otherElements[ID.noteEditor].firstMatch.images[ID.noteInk].firstMatch
        XCTAssertTrue(noteInk.waitForExistence(timeout: 5), "note stroke")
        XCTAssertTrue(state(app, has: "picker=shown"))
        // Undo goes to the note (last drawn on); the page keeps its stroke.
        undo(app)
        XCTAssertTrue(wait(noteInk, "exists == false"))
        XCTAssertEqual(ink(app).value as? String, "1 stroke")
    }

    // MARK: Appearance

    /// A live light/dark switch in markup mode re-shows the system tool picker (it would keep
    /// its old swatches until next shown), with the markup responder or the note's text view
    /// first responder. Saves `pageink-dark-page-and-note` and `pageink-light-again` to look at
    /// the swatches (pixels are not checked here).
    func testToolPickerFollowsALiveAppearanceSwitch() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        XCUIDevice.shared.appearance = .light
        // A hardware keyboard keeps the picker up while the note's text view has focus.
        let app = launch(["-markup", "-inkAnyInput", "-notesPanel", "page", "-exposeMarkupState",
                          "-hardwareKeyboard", "yes"])
        let noteText = app.textViews[ID.noteText].firstMatch
        XCTAssertTrue(noteText.waitForExistence(timeout: 15))
        XCTAssertTrue(state(app, has: "picker=shown"))

        XCUIDevice.shared.appearance = .dark
        sleep(2)
        XCTAssertTrue(state(app, has: "picker=shown"), "picker back after switching to dark")
        XCTAssertTrue(state(app, has: "responder=markup"))
        drawLine(app)
        XCTAssertTrue(strokes(ink(app), 1), "page stroke in dark mode")
        let note = noteText.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 160))
        note.press(forDuration: 0.2, thenDragTo: note.withOffset(CGVector(dx: 160, dy: 2)))
        sleep(1)
        try saveScreenshot("pageink-dark-page-and-note")

        // With the cursor in the note (an auxiliary responder of the picker).
        noteText.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.02)).tap()
        XCTAssertTrue(state(app, has: "responder=auxiliary"), "the note's text view is first responder")
        XCUIDevice.shared.appearance = .light
        sleep(2)
        XCTAssertTrue(state(app, has: "picker=shown"), "picker back after switching to light while typing")
        XCTAssertTrue(state(app, has: "responder=auxiliary"), "the cursor stays in the note")
        try saveScreenshot("pageink-light-again")
    }

    // MARK: Screenshots

    /// Not a check: saves `pageink-markup` (ink on the page and the system picker),
    /// `pageink-zoomed` (the same zoomed in) and `pageink-page-and-note` (the "Markup · page
    /// and note together" artboard: panel widened, page and note inked) to `build/shots`.
    func testScreenshots() throws {
        let app = launch(["-markup", "-inkAnyInput", "-notesPanel", "page"])
        let paragraph = pdf(app).staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Obtain show product")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        let p = paragraph.frame
        let origin = paragraph.coordinate(withNormalizedOffset: .zero)
        // Underline a phrase, two lines boxing a word, a margin note under the paragraph.
        origin.withOffset(CGVector(dx: p.width * 0.2, dy: 17)).press(forDuration: 0.15,
            thenDragTo: origin.withOffset(CGVector(dx: p.width * 0.62, dy: 18)))
        let box = origin.withOffset(CGVector(dx: p.width * 0.66, dy: 36))
        box.press(forDuration: 0.15, thenDragTo: box.withOffset(CGVector(dx: 70, dy: 0)))
        box.withOffset(CGVector(dx: 0, dy: 18)).press(forDuration: 0.15, thenDragTo: box.withOffset(CGVector(dx: 70, dy: 18)))
        origin.withOffset(CGVector(dx: p.width * 0.1, dy: p.height + 14)).press(forDuration: 0.15,
            thenDragTo: origin.withOffset(CGVector(dx: p.width * 0.5, dy: p.height + 30)))
        XCTAssertTrue(strokes(ink(app), 4))
        sleep(1)
        try saveScreenshot("pageink-markup")
        for _ in 0..<6 { app.typeKey("+", modifierFlags: .command) }
        sleep(2)
        try saveScreenshot("pageink-zoomed")
        app.typeKey("9", modifierFlags: .command)  // Fit Width
        sleep(1)

        // Widen the notes panel to half the window and ink the note too.
        let divider = app.descendants(matching: .any)["reader.notesDivider"].firstMatch
        if divider.waitForExistence(timeout: 5) {
            let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            handle.press(forDuration: 0.5, thenDragTo: handle.withOffset(CGVector(dx: -450, dy: 0)),
                         withVelocity: 300, thenHoldForDuration: 0.3)
            sleep(1)
        }
        // The narrower PDF re-fits and shows another page; ink the page now on screen.
        drawLine(app, x: 0.2, y: 0.2, length: 160)
        drawLine(app, x: 0.25, y: 0.32, length: 120)
        let noteText = app.textViews[ID.noteText].firstMatch
        if noteText.waitForExistence(timeout: 5) {
            // The editor's value is the zoom ("100%"); a widened pane widens the page instead.
            let value = (app.otherElements[ID.noteEditor].firstMatch.value as? String) ?? "100%"
            let zoom = CGFloat(Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 100) / 100
            let top = noteText.coordinate(withNormalizedOffset: .zero)
            let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(20, 40, 250, 42), (40, 200, 280, 198), (160, 260, 161, 140)]
            for (x0, y0, x1, y1) in lines {
                top.withOffset(CGVector(dx: x0 * zoom, dy: y0 * zoom)).press(forDuration: 0.15,
                    thenDragTo: top.withOffset(CGVector(dx: x1 * zoom, dy: y1 * zoom)))
            }
        }
        sleep(2)
        try saveScreenshot("pageink-page-and-note")
    }

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

// MARK: - Multi-touch

/// Multi-finger gestures for UI tests. XCUITest has no public two-finger pan, and its `pinch`
/// did not zoom the PDF view on these simulators, so this drives XCTest's own event
/// synthesizer (`XCSynthesizedEventRecord` / `XCPointerEventPath`, the classes behind
/// `XCUICoordinate` gestures) through the Objective-C runtime. Points are in the app's
/// interface coordinates; on the iPad simulators the events arrived only in portrait.
@MainActor
private enum MultiTouch {
    @objc private protocol EventPath {
        @objc(initForTouchAtPoint:offset:)
        func initForTouch(at point: CGPoint, offset: Double) -> NSObject
        @objc(moveToPoint:atOffset:)
        func move(to point: CGPoint, atOffset offset: Double)
        @objc(liftUpAtOffset:)
        func liftUp(atOffset offset: Double)
    }

    @objc private protocol EventRecord {
        @objc(initWithName:interfaceOrientation:)
        func initWithName(_ name: String, interfaceOrientation: Int) -> NSObject
        @objc(addPointerEventPath:)
        func add(_ path: NSObject)
        @objc(synthesizeWithError:)
        func synthesize() throws
    }

    static var isAvailable: Bool {
        NSClassFromString("XCPointerEventPath") != nil && NSClassFromString("XCSynthesizedEventRecord") != nil
    }

    private struct Path {
        let start: CGPoint
        let point: (CGFloat) -> CGPoint
    }

    /// Two fingers 60 points apart drag from around `start` by `offset`.
    static func drag(from start: CGPoint, by offset: CGVector, duration: Double = 0.6,
                     orientation: UIInterfaceOrientation) throws {
        let paths = [-30.0, 30.0].map { (dx: CGFloat) in
            Path(start: CGPoint(x: start.x + dx, y: start.y)) { t in
                CGPoint(x: start.x + dx + offset.dx * t, y: start.y + offset.dy * t)
            }
        }
        try synthesize(paths, duration: duration, name: "two-finger drag", orientation: orientation)
    }

    /// Two fingers `startSpacing` apart horizontally around `center` spread to `endSpacing`.
    static func spread(at center: CGPoint, from startSpacing: CGFloat, to endSpacing: CGFloat, duration: Double = 0.8,
                       orientation: UIInterfaceOrientation) throws {
        let paths = [-1.0, 1.0].map { (side: CGFloat) in
            Path(start: CGPoint(x: center.x + side * startSpacing / 2, y: center.y)) { t in
                CGPoint(x: center.x + side * (startSpacing + (endSpacing - startSpacing) * t) / 2, y: center.y)
            }
        }
        try synthesize(paths, duration: duration, name: "spread", orientation: orientation)
    }

    private static func synthesize(_ paths: [Path], duration: Double, name: String,
                                   orientation: UIInterfaceOrientation) throws {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type else {
            throw XCTSkip("XCTest's event synthesizer is not available")
        }
        let record = unsafeBitCast(recordClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue(),
                                   to: EventRecord.self).initWithName(name, interfaceOrientation: orientation.rawValue)
        let steps = 16
        let hold = 0.12
        for path in paths {
            let event = unsafeBitCast(pathClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue(),
                                      to: EventPath.self).initForTouch(at: path.start, offset: 0)
            let api = unsafeBitCast(event, to: EventPath.self)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                api.move(to: path.point(t), atOffset: hold + duration * Double(t))
            }
            api.liftUp(atOffset: hold + duration + 0.05)
            unsafeBitCast(record, to: EventRecord.self).add(event)
        }
        try unsafeBitCast(record, to: EventRecord.self).synthesize()
    }
}
