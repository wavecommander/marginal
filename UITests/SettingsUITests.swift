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
        app.launchArguments = ["-pagePillStaysVisible", "-exposeAccent"]
        app.launch()
        waitForAccent(app, "indigo", timeout: 20)
    }

    func testCommandCommaOpensSettingsAndResetRestoresRaspberry() {
        let app = XCUIApplication.launchFresh(["-exposeAccent", "-accent", "aubergine"])
        waitForAccent(app, "aubergine")
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 10))
        // Settings… is disabled until the window is the focused one, and a hardware-key event
        // sent before that is dropped; nothing on screen says when it is, so press again if
        // Settings did not open.
        let reset = app.buttons["settings.accent.reset"]
        var opened = false
        for _ in 0..<3 where !opened {
            app.typeKey(",", modifierFlags: .command)
            opened = reset.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(opened, app.debugDescription)
        XCTAssertEqual(app.buttons["settings.accent.aubergine"].value as? String, "selected")
        reset.tap()
        XCTAssertEqual(app.buttons["settings.accent.raspberry"].value as? String, "selected")
        app.buttons["settings.done"].tap()
        waitForAccent(app, "raspberry")
    }

    /// Settings ▸ About shows this build's version, branch, commit and build time, stamped by
    /// `scripts/stamp-build-info.sh`. Saves `build/shots/settings-about.png`.
    func testAboutShowsTheBuild() throws {
        let app = XCUIApplication.launchFresh([])
        openSettingsFromLibrary(app)
        let rows = ["settings.about.version", "settings.about.branch", "settings.about.commit", "settings.about.built"]
            .map { app.descendants(matching: .any)[$0].firstMatch }
        let copy = app.buttons["settings.about.copy"].firstMatch
        // Rows off screen are not in the tree: drag the form up until Copy is on screen.
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 where !(copy.exists && copy.isHittable) {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        for row in rows {
            XCTAssertTrue(row.exists, app.debugDescription)
        }
        // The tests build from a git checkout, so every value is known (the branch reads
        // "Detached" on a detached HEAD).
        XCTAssertTrue(rows[0].label.contains("0.1"), rows[0].label)
        for row in rows {
            XCTAssertFalse(row.label.contains("Unknown"), row.label)
        }

        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("settings-about.png"))
    }

    func testResetStateClearsTheStoredAccent() {
        var app = XCUIApplication.launchFresh(["-exposeAccent", "-accent", "onyx"])
        waitForAccent(app, "onyx")
        app.terminate()
        app = XCUIApplication.launchFresh(["-exposeAccent"])
        waitForAccent(app, "raspberry")
    }
}
