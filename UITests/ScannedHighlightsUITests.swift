import UIKit
import XCTest

/// Scanned-page highlights (S4) on `scanned.pdf` (page 1 typed, pages 2 to 30 pictures of text
/// with no text layer; "The quiet heron measures tidewater." is the first body line of page 17):
/// - a seeded Live Text highlight (`-seedScannedHighlight`) is drawn in place, and again after a
///   relaunch before PDFKit has read the page; it recolours, shows a crop row in the Notebook,
///   and deletes;
/// - a highlight made from a **real** selection on the scanned page, once PDFKit's Live Text has
///   read it, records the Live Text source (the reader's element then says "on a scanned page",
///   which it takes from the stored highlight).
///
/// Screenshots go to `build/shots/scanned-highlight-*.png`.
@MainActor
final class ScannedHighlightsUITests: XCTestCase {
    static let phrase = "The quiet heron measures tidewater."
    static let element = "reader.highlight.17.0"

    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func launchReader(fresh: Bool, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let arguments = ["-openBook", "scanned", "-openPage", "17"] + extra
        let app: XCUIApplication
        if fresh {
            app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.scanned) + arguments)
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-pagePillStaysVisible"] + arguments
            app.launch()
        }
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 40), "the reader did not open")
        return app
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            usleep(250_000)
        }
        return true
    }

    private func save(_ name: String) {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    /// Pixels of an element's screenshot, as (r, g, b), at points of `rect` (in the element's own
    /// coordinates, interface orientation; the whole element by default). The simulator's
    /// screenshots are in the device's portrait orientation: with the iPad in landscape, the
    /// image is the element turned a quarter turn (the interface's top on the image's right).
    private func pixels(of element: XCUIElement, in rect: CGRect? = nil, step: CGFloat = 2) -> [(r: Int, g: Int, b: Int)] {
        let image = element.screenshot().image
        guard let cg = image.cgImage else { return [] }
        let frame = element.frame
        let width = cg.width, height = cg.height
        let rotated = (CGFloat(width) > CGFloat(height)) != (frame.width > frame.height)
        let scale = CGFloat(rotated ? height : width) / max(frame.width, 1)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        let area = rect ?? CGRect(origin: .zero, size: frame.size)
        var result: [(r: Int, g: Int, b: Int)] = []
        var y = max(area.minY, 0)
        while y < min(area.maxY, frame.height) {
            var x = max(area.minX, 0)
            while x < min(area.maxX, frame.width) {
                // Memory rows run top to bottom.
                let px = rotated ? width - 1 - Int(y * scale) : Int(x * scale)
                let py = rotated ? Int(x * scale) : Int(y * scale)
                let i = (min(max(py, 0), height - 1) * width + min(max(px, 0), width - 1)) * 4
                result.append((Int(data[i]), Int(data[i + 1]), Int(data[i + 2])))
                x += step
            }
            y += step
        }
        return result
    }

    /// A share of the highlight's frame is tinted with its colour (paper under the fill).
    private func isTinted(_ element: XCUIElement, yellow: Bool) -> Bool {
        let samples = pixels(of: element, step: 1)
        guard !samples.isEmpty else { return false }
        let tinted = samples.filter { p in
            yellow ? (p.r > 200 && p.g > 180 && p.b < 175) : (p.g > p.r + 25 && p.g > p.b + 10)
        }
        return Double(tinted.count) / Double(samples.count) > 0.2
    }

    // MARK: Seeded highlight

    /// A seeded Live Text highlight is drawn in place, survives a relaunch (drawn before PDFKit
    /// reads the page again), recolours, shows a crop row in the Notebook, and deletes.
    func testSeededLiveTextHighlightIsDrawnRecoloursShowsACropAndDeletes() throws {
        var app = launchReader(fresh: true, ["-seedScannedHighlight"])
        let element = app.buttons[Self.element].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the seeded highlight is not shown")
        XCTAssertEqual(element.label, "Yellow highlight on a scanned page, page 17")
        XCTAssertEqual(element.value as? String, Self.phrase)
        sleep(1)
        XCTAssertTrue(isTinted(element, yellow: true), "the highlight is not drawn over the line")
        save("scanned-highlight-seeded")

        // Relaunch (same store, no seeding): drawn from its rects at once.
        app.terminate()
        let relaunchedAt = Date()
        app = launchReader(fresh: false)
        let relaunched = app.buttons[Self.element].firstMatch
        XCTAssertTrue(relaunched.waitForExistence(timeout: 15), "the highlight did not survive a relaunch")
        XCTAssertTrue(waitFor(5) { self.isTinted(relaunched, yellow: true) }, "not drawn after the relaunch")
        print("ScannedHighlightsUITests: drawn \(String(format: "%.1f", Date().timeIntervalSince(relaunchedAt))) s after relaunch")
        save("scanned-highlight-relaunched")

        // Recolour to green from the tap menu.
        relaunched.tap()
        guard let green = menuItem(app, "Green") else {
            save("scanned-highlight-missing-tap-menu")
            return XCTFail("tap menu did not open")
        }
        XCTAssertNotNil(menuItem(app, "Copy", timeout: 1))
        XCTAssertNotNil(menuItem(app, "Delete", timeout: 1))
        green.tap()
        XCTAssertTrue(waitFor { app.buttons[Self.element].firstMatch.label == "Green highlight on a scanned page, page 17" },
                      "recolour did not apply")
        sleep(1)
        XCTAssertTrue(isTinted(app.buttons[Self.element].firstMatch, yellow: false), "not drawn green")

        // The Notebook: a row with the crop and its caption.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-pagePillStaysVisible", "-openBook", "scanned", "-screen", "notebook"]
        app.launch()
        let row = app.buttons["notebook.highlight.17.0"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Notebook row for the highlight")
        XCTAssertEqual(row.label, "Green highlight on a scanned page, page 17. \(Self.phrase)")
        sleep(2)
        // The crop (about 250 × 30 points: the line at 1.5 times) sits above its caption.
        XCTAssertGreaterThan(row.frame.height, 55, "row \(row.frame)")
        let cropZone = CGRect(x: 0, y: 4, width: row.frame.width, height: 30)
        let dark = pixels(of: row, in: cropZone, step: 1).filter { $0.r < 110 && $0.g < 110 && $0.b < 110 }.count
        XCTAssertGreaterThan(dark, 60, "no page text in the crop zone of \(row.frame)")
        save("scanned-highlight-notebook")

        // Back in the reader: delete.
        app.terminate()
        app = launchReader(fresh: false)
        let shown = app.buttons[Self.element].firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 15))
        shown.tap()
        guard let delete = menuItem(app, "Delete") else { return XCTFail("tap menu did not open") }
        delete.tap()
        XCTAssertTrue(waitFor { !app.buttons[Self.element].firstMatch.exists }, "delete did not remove the highlight")
    }

    // MARK: Real selection

    /// A highlight from a real finger selection on the scanned page. PDFKit reads the page a few
    /// seconds after it appears (up to 15 s on a cold start; docs/SCANNED_BOOKS_FINDINGS.md) and
    /// gives no sign of it: until then the page has no text and a long press selects nothing. So
    /// the test long-presses "heron" again and again until the edit menu offers Highlight (S0
    /// polled the on-screen page's text, which a UI test cannot see; PDFKit does not expose the
    /// recognised text to accessibility either, which was tried first).
    ///
    /// Where the line is on screen comes from a seeded highlight over it (the reader's
    /// accessibility element is framed on its rects), deleted before selecting.
    func testRealSelectionOnAScannedPageRecordsLiveText() throws {
        let app = launchReader(fresh: true, ["-seedScannedHighlight"])
        let seeded = app.buttons[Self.element].firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 15), "the seeded highlight is not shown")
        let frame = seeded.frame
        seeded.tap()
        guard let delete = menuItem(app, "Delete") else { return XCTFail("tap menu did not open") }
        delete.tap()
        XCTAssertTrue(waitFor { !app.buttons[Self.element].firstMatch.exists }, "the seeded highlight was not deleted")

        // "The quiet heron measures tidewater." is set in 11 pt Times: "heron" starts about 27%
        // along the line and ends about 43%.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let heron = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.35, dy: frame.midY))
        let started = Date()
        var menu: XCUIElement?
        var attempts = 0
        while Date().timeIntervalSince(started) < 60, menu == nil {
            attempts += 1
            heron.press(forDuration: 1.2)
            menu = menuItem(app, "Highlight", timeout: 1.5)
            if menu == nil { sleep(2) }
        }
        print("ScannedHighlightsUITests: selectable after \(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(attempts) long presses")
        guard menu != nil else {
            save("scanned-highlight-never-selectable")
            return XCTFail("the scanned page never became selectable (no Highlight in the edit menu after 60 s)")
        }
        // Grow the word to the whole line: press on "The" and drag to the end of "tidewater.".
        app.tap()   // dismiss the menu and the word selection
        sleep(1)
        let start = origin.withOffset(CGVector(dx: frame.minX + 3, dy: frame.midY))
        let end = origin.withOffset(CGVector(dx: frame.maxX - 1, dy: frame.midY))
        start.press(forDuration: 1.2, thenDragTo: end)
        sleep(1)
        guard let submenu = menuItem(app, "Highlight") else {
            save("scanned-highlight-missing-menu")
            return XCTFail("no 'Highlight' in the edit menu after selecting the line")
        }
        save("scanned-highlight-edit-menu")
        submenu.tap()
        guard let green = menuItem(app, "Green") else { return XCTFail("no 'Green' in the Highlight submenu") }
        green.tap()

        let element = app.buttons[Self.element].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "the highlight is not shown")
        // The label comes from the stored highlight: "on a scanned page" is its Live Text source.
        XCTAssertTrue(waitFor(5) { element.label == "Green highlight on a scanned page, page 17" },
                      "stored without the Live Text source: \(element.label)")
        let value = element.value as? String ?? ""
        XCTAssertTrue(value.contains("heron"), "stored text: \(value)")
        print("ScannedHighlightsUITests: stored text '\(value)'")
        save("scanned-highlight-from-selection")
    }
}
