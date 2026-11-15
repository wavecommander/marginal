import XCTest

/// Settings ▸ Appearance: the accent preset. Every window's `settings.accentProbe`
/// (`-exposeAccent`) reports the environment accent and the preset matching that window's
/// `UIWindow.tintColor`, so these tests check the SwiftUI and UIKit tints in each window.
@MainActor
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: Helpers

    private func probes(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "settings.accentProbe").allElementsBoundByIndex
    }

    /// Waits until there are at least `windows` probes and every one reads `preset` for both
    /// the environment and the window tint.
    private func waitForAccent(_ app: XCUIApplication, _ preset: String, windows: Int = 1,
                               timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let expected = "theme=\(preset) window=\(preset)"
        let deadline = Date().addingTimeInterval(timeout)
        var values: [String] = []
        repeat {
            values = probes(app).map { ($0.value as? String) ?? "" }
            if values.count >= windows, values.allSatisfy({ $0 == expected }) { return }
            usleep(200_000)
        } while Date() < deadline
        XCTFail("expected \(windows) window(s) with \(expected), got \(values)", file: file, line: line)
    }

    private func openSettingsFromLibrary(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settings.open"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // With two Library windows, the one in front (the other's gear is covered).
        let gears = app.buttons.matching(identifier: "settings.open").allElementsBoundByIndex
        let gear = gears.first(where: \.isHittable) ?? gears[0]
        gear.tap()
        XCTAssertTrue(app.buttons["settings.accent.raspberry"].waitForExistence(timeout: 5), app.debugDescription)
    }

    // MARK: Tests

    func testPickingASwatchRetintsEveryWindowAndPersists() {
        var app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-exposeAccent", "-alsoOpenWindow", "small"])
        XCTAssertTrue(app.buttons["reader.toolbar.contents"].firstMatch.waitForExistence(timeout: 20),
                      app.debugDescription)
        waitForAccent(app, "raspberry", windows: 2)

        // The reader window is in front, covering the first window's Library. Go back to the
        // Library in the front window (the tap also makes it the key window) and use its gear.
        app.navigationBars["small"].buttons["BackButton"].firstMatch.tap()
        openSettingsFromLibrary(app)
        XCTAssertEqual(app.buttons["settings.accent.raspberry"].value as? String, "selected")
        XCTAssertFalse(app.buttons["settings.accent.reset"].isEnabled)

        app.buttons["settings.accent.indigo"].tap()
        XCTAssertEqual(app.buttons["settings.accent.indigo"].value as? String, "selected")
        XCTAssertEqual(app.buttons["settings.accent.raspberry"].value as? String, "")
        XCTAssertTrue(app.buttons["settings.accent.reset"].isEnabled)
        XCTAssertTrue(app.otherElements["settings.accent.preview"].exists
                      || app.descendants(matching: .any)["settings.accent.preview"].exists)

        app.buttons["settings.done"].tap()
        // Both windows, the one that changed it and the other, follow without a relaunch.
        waitForAccent(app, "indigo", windows: 2)

        // Relaunch without -resetState: the choice is kept.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-exposeAccent"]
        app.launch()
        waitForAccent(app, "indigo", timeout: 20)
    }

    func testCommandCommaOpensSettingsAndResetRestoresRaspberry() {
        let app = XCUIApplication.launchFresh(["-exposeAccent", "-accent", "teal"])
        waitForAccent(app, "teal")
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let reset = app.buttons["settings.accent.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["settings.accent.teal"].value as? String, "selected")
        reset.tap()
        XCTAssertEqual(app.buttons["settings.accent.raspberry"].value as? String, "selected")
        app.buttons["settings.done"].tap()
        waitForAccent(app, "raspberry")
    }

    func testResetStateClearsTheStoredAccent() {
        var app = XCUIApplication.launchFresh(["-exposeAccent", "-accent", "graphite"])
        waitForAccent(app, "graphite")
        app.terminate()
        app = XCUIApplication.launchFresh(["-exposeAccent"])
        waitForAccent(app, "raspberry")
    }
}
