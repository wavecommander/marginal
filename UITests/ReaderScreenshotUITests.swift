import XCTest

/// Captures reader screenshots in orientations `scripts/shot.sh` cannot set (it has no
/// rotation), written to `build/shots/<name><suffix>.png` (suffix `-ios17` on iOS 17).
/// Not assertions about pixels: the files are for comparing against the mockups.
@MainActor
final class ReaderScreenshotUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    private var suffix: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18 ? "-ios17" : ""
    }

    private func save(_ name: String) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("\(name)\(suffix).png"))
    }

    private func launch(_ orientation: UIDeviceOrientation, _ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large)
                                              + ["-openBook", "large", "-openPage", "312"] + extra)
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30))
        sleep(3)
        return app
    }

    func testReaderLandscapeBothPanels() throws {
        _ = launch(.landscapeLeft, [])
        try save("reader-landscape")
    }

    func testReaderMarkupMode() throws {
        _ = launch(.landscapeLeft, ["-markup"])
        try save("reader-markup")
    }

    func testReaderPortraitNarrow() throws {
        _ = launch(.portrait, [])
        try save("reader-portrait")
    }

    func testReaderLandscapeSectionNote() throws {
        _ = launch(.landscapeLeft, ["-notesPanel", "section"])
        try save("reader-landscape-section")
    }
}
