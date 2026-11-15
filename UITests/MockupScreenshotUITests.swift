import UIKit
import XCTest

/// One screenshot per mockup artboard (`docs/MOCKUP_DIFFERENCES.md`), written to
/// `build/shots/mockup-<artboard><suffix>.png`. Not assertions about pixels.
///
/// The reader states use `no-outline.pdf` seeded by `-seedNotebook -seedNotebookPageInk` (user
/// headings "5 Eigenvalues and Eigenvectors" › "5.2 The Characteristic Equation" from p. 23, an
/// inked page note on p. 25 with highlights, page ink on p. 25), which mirrors the mockups'
/// page 312. The seed is applied when the Notebook first appears, so the class's first test
/// opens the Notebook; the others relaunch on the same store (tests run in name order).
///
/// Appearance is the simulator's (`xcrun simctl ui <udid> appearance dark`); pass
/// `TEST_RUNNER_MOCKUP_SUFFIX=-dark` in the environment of `scripts/test.sh` so the dark run
/// writes its own files.
@MainActor
final class MockupScreenshotUITests: XCTestCase {
    private var suffix: String { ProcessInfo.processInfo.environment["MOCKUP_SUFFIX"] ?? "" }
    /// Extra launch arguments for every launch (`TEST_RUNNER_MOCKUP_ARGS`), e.g. the largest text
    /// size: `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`.
    private var extraArguments: [String] {
        (ProcessInfo.processInfo.environment["MOCKUP_ARGS"] ?? "").split(separator: " ").map(String.init)
    }

    override func setUp() {
        continueAfterFailure = true
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    /// Saves the screenshot, and the accessibility tree beside it in `build/a11y/` (for the
    /// accessibility audit: labels, values and traits of every element on the screen).
    private func save(_ name: String, _ app: XCUIApplication) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Drawn through a renderer so the file is upright in landscape (the raw PNG is the
        // display's portrait buffer; `image` carries the interface orientation).
        let image = XCUIScreen.main.screenshot().image
        let upright = UIGraphicsImageRenderer(size: image.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            return format
        }()).image { _ in image.draw(at: .zero) }
        try upright.pngData()?.write(to: directory.appendingPathComponent("mockup-\(name)\(suffix).png"))
        let tree = Fixtures.repoRoot.appendingPathComponent("build/a11y", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try app.debugDescription.write(to: tree.appendingPathComponent("mockup-\(name)\(suffix).txt"),
                                       atomically: true, encoding: .utf8)
    }

    /// The seeded book in the reader, on the same store as `test1Notebook`.
    private func reader(page: Int = 25, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openBook", "no-outline", "-openPage", "\(page)", "-inkAnyInput"] + extra + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30))
        sleep(3)
        return app
    }

    // MARK: Artboards

    func test0Library() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + XCUIApplication.importing(Fixtures.large)
                                              + XCUIApplication.importing(Fixtures.noOutline)
                                              + ["-openBook", "large", "-openPage", "312"] + extraArguments)
        // Open one book so the Continue reading card has something to show, then go back.
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30))
        sleep(2)
        app.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(app.buttons["library.book.large"].firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        try save("library", app)
    }

    func test1Notebook() throws {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.noOutline)
                                              + ["-screen", "notebook", "-seedNotebook", "-seedNotebookPageInk"] + extraArguments)
        XCTAssertTrue(app.buttons["notebook.header.3 Matrices and Linear Maps"].firstMatch.waitForExistence(timeout: 30))
        let chapter = app.collectionViews["notebook.scopes"].otherElements["notebook.scope.5 Eigenvalues and Eigenvectors"].firstMatch
        if chapter.waitForExistence(timeout: 5) { chapter.tap() }
        sleep(3)
        try save("notebook", app)
    }

    func test2ReaderPageNote() throws {
        let app = reader(["-notesPanel", "page"])
        try save("reader-page-note", app)
    }

    func test3ReaderSectionNote() throws {
        let app = reader(["-notesPanel", "section"])
        try save("reader-section-note", app)
    }

    func test4Markup() throws {
        let app = reader(["-markup"])
        // Close the notes panel as in the artboard (page only, tool picker).
        let notes = app.buttons["reader.toolbar.notes"].firstMatch
        if notes.exists, notes.label == "Hide Notes" { notes.tap() }
        sleep(2)
        try save("markup", app)
    }

    func test5MarkupPageAndNote() throws {
        let app = reader(["-markup", "-notesPanel", "page"])
        // Widen the notes panel towards half the window (the note keeps its zoom and line breaks).
        let divider = app.descendants(matching: .any)["reader.notesDivider"].firstMatch
        if divider.waitForExistence(timeout: 5) {
            let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.5, thenDragTo: start.withOffset(CGVector(dx: -300, dy: 0)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        sleep(2)
        try save("markup-page-and-note", app)
    }

    func test6PortraitNotesSheet() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = reader(["-notesPanel", "page"])
        sleep(1)
        try save("portrait-notes-sheet", app)
    }
}
