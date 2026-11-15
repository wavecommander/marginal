import XCTest

/// Settings ▸ Supported Formats (F7): the row in Settings opens a screen with the PDF row, the
/// common conversion block, one block per kind of file the app can convert (with the Convert to
/// PDF sheet's sentences), and the kinds it can't import. Screenshots in light, dark and at the
/// largest text size (`build/shots/supported-formats-*.png`).
@MainActor
final class SupportedFormatsUITests: XCTestCase {
    private enum ID {
        static let settingsOpen = "settings.open"
        static let row = "settings.supportedFormats"
        static let screen = "supportedFormats.screen"
        static func group(_ raw: String) -> String { "supportedFormats.group.\(raw)" }
        static func format(_ raw: String) -> String { "supportedFormats.format.\(raw)" }
        static func limitation(_ raw: String) -> String { "supportedFormats.limitation.\(raw)" }
        static func notSupported(_ raw: String) -> String { "supportedFormats.notSupported.\(raw)" }
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCUIDevice.shared.appearance = .light
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.appearance = .light }
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openScreen(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchFresh(arguments)
        let gear = app.buttons[ID.settingsOpen].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15), app.debugDescription)
        gear.tap()
        let row = app.buttons[ID.row].firstMatch
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), app.debugDescription)
        reveal(app, row, in: "Settings")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Supported Formats row\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Supported Formats"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    /// Scrolls the screen until `element` is on screen (rows off screen are not in the tree).
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, in screen: String = "Supported Formats",
                        swipes: Int = 12) {
        let anchor = app.navigationBars[screen]
        for _ in 0..<swipes where !(element.exists && element.isHittable) {
            let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6))
            start.press(forDuration: 0.05, thenDragTo: anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.5)))
        }
    }

    private func save(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testListsWhatCanBeImportedAndWhatCannot() throws {
        let app = openScreen()
        XCTAssertTrue(any(app, ID.format("pdf")).exists)
        XCTAssertTrue(any(app, ID.limitation("fixedPages")).exists, app.debugDescription)
        XCTAssertEqual(any(app, ID.limitation("fixedPages")).label,
                       "The pages are fixed once converted. You can zoom, but you can't change the text size or layout afterwards.")
        try save("supported-formats-light")

        // The groups whose converters the app has (images and EPUB at least), each with its
        // formats and the sheet's sentences.
        for (format, limitation) in [("epub", "pageNumbersDiffer"), ("comicArchive", "pagesArePictures")] {
            let row = any(app, ID.format(format))
            reveal(app, row)
            XCTAssertTrue(row.exists, "format \(format)\n\(app.debugDescription)")
            let sentence = any(app, ID.limitation(limitation))
            reveal(app, sentence)
            XCTAssertTrue(sentence.exists, "limitation \(limitation)")
        }
        XCTAssertTrue(any(app, ID.format("image")).exists)
        XCTAssertTrue(any(app, ID.format("comicArchive")).label.contains(".cbz"), any(app, ID.format("comicArchive")).label)

        // What can't be imported, each with a reason.
        for kind in ["protectedEPUB", "kindle", "djvu", "comicRar", "fixedLayoutEPUB", "spreadsheet"] {
            let row = any(app, ID.notSupported(kind))
            reveal(app, row)
            XCTAssertTrue(row.exists, "not supported: \(kind)\n\(app.debugDescription)")
        }
        XCTAssertTrue(any(app, ID.notSupported("comicRar")).label.contains("CBZ"), any(app, ID.notSupported("comicRar")).label)
        try save("supported-formats-light-end")

        // Dark Mode.
        XCUIDevice.shared.appearance = .dark
        sleep(1)
        try save("supported-formats-dark-end")
        app.navigationBars["Supported Formats"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons[ID.row].firstMatch.waitForExistence(timeout: 5))
        app.buttons[ID.row].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Supported Formats"].waitForExistence(timeout: 5))
        sleep(1)
        try save("supported-formats-dark")
    }

    func testWorksAtTheLargestTextSize() throws {
        let app = openScreen(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let first = any(app, ID.format("pdf"))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        try save("supported-formats-largest-text")
        let last = any(app, ID.notSupported("spreadsheet"))
        reveal(app, last, swipes: 40)
        XCTAssertTrue(last.exists && last.isHittable, "the end of the screen is reachable\n\(app.debugDescription)")
        try save("supported-formats-largest-text-end")
    }
}
