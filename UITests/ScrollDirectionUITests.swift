import XCTest

/// Per-book scroll direction: the More menu turns a book's pages sideways (or back), the reader
/// stays on its page, the choice survives a relaunch, and other books keep their own direction.
/// Reads `reader.markupState` (`scroll=…`) and `reader.viewportAnchor` ("page N x X y Y scale S").
@MainActor
final class ScrollDirectionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    private static let probes = ["-exposeMarkupState", "-exposeViewportAnchor"]

    private func waitForReader(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 30), "reader open")
        XCTAssertTrue(app.buttons["reader.markupState"].firstMatch.waitForExistence(timeout: 10))
    }

    private func waitForScroll(_ app: XCUIApplication, _ direction: String, _ message: String) {
        let probe = app.buttons["reader.markupState"].firstMatch
        let predicate = NSPredicate(format: "value CONTAINS %@", "scroll=\(direction)")
        let found = XCTNSPredicateExpectation(predicate: predicate, object: probe)
        XCTAssertEqual(XCTWaiter().wait(for: [found], timeout: 10), .completed,
                       "\(message): \(probe.value ?? "nil")")
    }

    private func choose(_ app: XCUIApplication, _ title: String) {
        let more = app.buttons["reader.toolbar.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) in the More menu")
        item.tap()
    }

    /// (page, x, y) of the reading anchor once it stops changing.
    private func settledAnchor(_ app: XCUIApplication) -> (page: Int, x: Double, y: Double) {
        func read() -> (page: Int, x: Double, y: Double)? {
            guard let value = app.buttons["reader.viewportAnchor"].firstMatch.value as? String else { return nil }
            let parts = value.split(separator: " ")
            guard parts.count == 8, let page = Int(parts[1]), let x = Double(parts[3]), let y = Double(parts[5])
            else { return nil }
            return (page, x, y)
        }
        var last = read()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            usleep(500_000)
            let next = read()
            if let next, let previous = last, next == previous { break }
            last = next
        }
        guard let last else {
            XCTFail("no viewport anchor")
            return (0, 0, 0)
        }
        return last
    }

    private func drag(_ app: XCUIApplication, dx: Double) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testHorizontalIsPerBookKeepsThePageAndSurvivesRelaunch() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + XCUIApplication.importing(Fixtures.noOutline)
                                              + ["-openBook", "small", "-openPage", "3"] + Self.probes)
        waitForReader(app)
        waitForScroll(app, "vertical", "a book starts vertical")
        XCTAssertEqual(settledAnchor(app).page, 3)

        choose(app, "Scroll Horizontally")
        waitForScroll(app, "horizontal", "the More menu turns the book sideways")
        let sideways = settledAnchor(app)
        XCTAssertEqual(sideways.page, 3, "switching keeps the page")
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.label.contains("3"), "pill on page 3")

        // A leftward drag moves along the row of pages, not down the page.
        drag(app, dx: -0.3)
        let moved = settledAnchor(app)
        XCTAssertTrue(moved.page > sideways.page || moved.x > sideways.x + 20,
                      "a sideways drag scrolls sideways: \(sideways) -> \(moved)")
        XCTAssertEqual(moved.y, sideways.y, accuracy: 1, "and not up or down")

        // Relaunch (no reset): the book reopens sideways.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-openBook", "small", "-openPage", "3"] + Self.probes
        again.launch()
        waitForReader(again)
        waitForScroll(again, "horizontal", "the choice is kept for this book")

        // A rightward drag on page 1 scrolls back, it never leaves the book (back swipe guard).
        again.terminate()
        let atStart = XCUIApplication()
        atStart.launchArguments = ["-openBook", "small", "-openPage", "1"] + Self.probes
        atStart.launch()
        waitForReader(atStart)
        drag(atStart, dx: 0.35)
        sleep(1)
        XCTAssertTrue(atStart.buttons["reader.pagePill"].firstMatch.exists, "still in the reader")

        // Another book keeps its own (default) direction.
        atStart.terminate()
        let other = XCUIApplication()
        other.launchArguments = ["-openBook", "no-outline"] + Self.probes
        other.launch()
        waitForReader(other)
        waitForScroll(other, "vertical", "other books are not affected")

        // Back to vertical on the first book.
        other.terminate()
        let back = XCUIApplication()
        back.launchArguments = ["-openBook", "small", "-openPage", "5"] + Self.probes
        back.launch()
        waitForReader(back)
        waitForScroll(back, "horizontal", "still sideways")
        choose(back, "Scroll Vertically")
        waitForScroll(back, "vertical", "the More menu turns it back")
        XCTAssertEqual(settledAnchor(back).page, 5, "switching back keeps the page")
    }
}
