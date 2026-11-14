import XCTest

/// Performance on `large.pdf` (1,500 pages) for WP12, through the DEBUG `-perfProbe` element
/// (`ReaderPerfProbe`): launch and open to first page, opening at page 1,200, continuous scroll
/// frame gaps and memory (`-perfAutoScroll`, driven by the app itself), and the time to open
/// Contents, the Pages grid and the Notebook (XCUITest wall clock from the tap to the first row,
/// which includes XCUITest's own snapshot time; compare runs, not absolute values).
///
/// Figures are printed (`PERF …`) and written to `build/perf-<test>.txt`. Bounds are generous:
/// the point is the numbers.
@MainActor
final class PerformanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func stats(_ app: XCUIApplication) -> XCUIElement { app.buttons["reader.perfStats"].firstMatch }

    /// The probe's value once the first page has been shown.
    private func firstPageStats(_ app: XCUIApplication, timeout: TimeInterval = 60) -> [String: Double] {
        let probe = stats(app)
        XCTAssertTrue(probe.waitForExistence(timeout: timeout), "perf probe")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let figures = Self.parse(probe.value as? String ?? "")
            if figures["openToFirstPageMS"] != nil { return figures }
            usleep(250_000)
        }
        XCTFail("no first page: \(probe.value ?? "nil")")
        return [:]
    }

    private func record(_ name: String, _ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print("PERF \(name):\n\(text)")
        try? text.write(to: Fixtures.repoRoot.appendingPathComponent("build/perf-\(name).txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static func parse(_ value: String) -> [String: Double] {
        let parts = value.split(separator: " ").map(String.init)
        var result: [String: Double] = [:]
        var index = 0
        while index + 1 < parts.count {
            if let number = Double(parts[index + 1]) {
                result[parts[index]] = number
                index += 2
            } else if parts[index + 1].contains("/") {
                // "a/b/c" footprints: keep the highest.
                let values = parts[index + 1].split(separator: "/").compactMap { Double($0) }
                result[parts[index]] = values.max()
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    private func launch(_ arguments: [String]) -> (XCUIApplication, TimeInterval) {
        let app = XCUIApplication()
        app.launchArguments = arguments
        let started = Date()
        app.launch()
        let pill = app.buttons["reader.pagePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 60))
        return (app, Date().timeIntervalSince(started))
    }

    // MARK: Tests

    /// Import once, then three cold launches straight into the reader at page 1, and three at
    /// page 1,200.
    func testLaunchAndOpenToFirstPage() {
        let importing = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large))
        XCTAssertTrue(importing.buttons["library.book.large"].firstMatch.waitForExistence(timeout: 60))
        importing.terminate()
        var lines: [String] = []
        for page in [1, 1200] {
            for run in 1...3 {
                let (app, wall) = launch(["-openBook", "large", "-openPage", "\(page)", "-perfProbe"])
                let figures = firstPageStats(app)
                lines.append(String(format: "page %d run %d: launchToFirstPageMS %.0f openToFirstPageMS %.0f (XCUITest launch→pill %.1f s) page %.0f footprintMB %.0f",
                                    page, run, figures["launchToFirstPageMS"] ?? -1, figures["openToFirstPageMS"] ?? -1,
                                    wall, figures["page"] ?? -1, figures["footprintMB"] ?? -1))
                XCTAssertEqual(figures["page"] ?? -1, Double(page), "opened at page \(page)")
                XCTAssertLessThan(figures["launchToFirstPageMS"] ?? .infinity, 10_000)
                app.terminate()
            }
        }
        record("launch", lines)
    }

    /// The app scrolls its own PDF view (no XCUITest input meanwhile): frame gaps and memory.
    func testContinuousScrollFrameGapsAndMemory() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large)
                                              + ["-openBook", "large", "-openPage", "100", "-perfProbe", "-perfAutoScroll"])
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 60))
        _ = firstPageStats(app)
        // 3 s wait + 8 s slow + 1 s pause + 8 s fast; no queries meanwhile.
        sleep(24)
        var value = stats(app).value as? String ?? ""
        let deadline = Date().addingTimeInterval(20)
        while !value.contains("phase done"), Date() < deadline {
            sleep(1)
            value = stats(app).value as? String ?? ""
        }
        record("scroll", [value])
        let figures = Self.parse(value)
        XCTAssertTrue(value.contains("phase done"), value)
        XCTAssertGreaterThan(figures["fastPages"] ?? 0, 20, "the fast phase crossed many pages")
        XCTAssertLessThan(figures["fastFootprintMB"] ?? .infinity, 1_500, "generous memory bound")
    }

    /// Contents (closed, then opened), the Pages tab, and the Notebook, at page 1,200.
    func testOpeningContentsPagesAndNotebook() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.large)
                                              + ["-openBook", "large", "-openPage", "1200", "-perfProbe"])
        _ = firstPageStats(app)
        sleep(3)
        var lines: [String] = []
        func timed(_ label: String, _ action: () -> Void, until element: XCUIElement) {
            let started = Date()
            action()
            let found = element.waitForExistence(timeout: 30)
            let elapsed = Date().timeIntervalSince(started)
            lines.append(String(format: "%@: %.2f s%@", label, elapsed, found ? "" : " (not found)"))
            XCTAssertTrue(found, label)
        }
        // XCUITest's own cost of a tap and a query on this screen: tapping the probe (it does
        // nothing) until an element that already exists is found.
        timed("baseline (tap on a no-op element, then a query)", { stats(app).tap() },
              until: app.buttons["reader.pagePill"].firstMatch)
        let contents = app.buttons["reader.toolbar.contents"].firstMatch
        let tabs = app.segmentedControls["sidebar.tabs"].firstMatch
        if tabs.waitForExistence(timeout: 5) {
            contents.tap()
            _ = tabs.waitForNonExistence(timeout: 10)
            sleep(1)
        }
        let anyHeading = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.heading.")).firstMatch
        timed("Contents opened (first heading row)", { contents.tap() }, until: anyHeading)
        sleep(1)
        timed("Pages tab (thumbnail cell of page 1200)", { tabs.buttons["Pages"].tap() },
              until: app.buttons["sidebar.page.1200"].firstMatch)
        sleep(1)
        tabs.buttons["Contents"].tap()
        sleep(1)
        let more = app.buttons["reader.toolbar.more"].firstMatch
        more.tap()
        let notebook = app.buttons["Notebook"].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        timed("Notebook (screen with its type filter)", { notebook.tap() },
              until: app.segmentedControls["notebook.typeFilter"].firstMatch)
        record("panels", lines)
    }
}
