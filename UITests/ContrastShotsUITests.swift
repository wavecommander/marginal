import XCTest

/// TEMPORARY (contrast review): screenshots of the backup, sync and export controls. Delete after.
@MainActor
final class ContrastShotsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private var accent: String { ProcessInfo.processInfo.environment["SHOT_ACCENT"] ?? "raspberry" }
    private var tag: String { ProcessInfo.processInfo.environment["SHOT_TAG"] ?? "dark-raspberry" }

    private func shot(_ name: String) {
        let dir = Fixtures.repoRoot.appendingPathComponent("build/shots/contrast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(tag)-\(name).png"))
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.waitForExistence(timeout: 1), element.isHittable { return }
            let lists = app.collectionViews
            let list = lists.count > 0 ? lists.element(boundBy: lists.count - 1) : app.windows.firstMatch
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
    }

    private func openCloud(_ app: XCUIApplication) {
        app.buttons["settings.open"].firstMatch.tap()
        let row = app.buttons["settings.backup"].firstMatch
        scrollTo(row, in: app); row.tap()
        _ = app.buttons["backup.file.save"].firstMatch.waitForExistence(timeout: 5)
        shot("backup-screen")
        let cloud = app.buttons["backup.destination.tactile-cloud"].firstMatch
        scrollTo(cloud, in: app); cloud.tap()
        _ = any(app, "cloud.status").waitForExistence(timeout: 20)
        sleep(2)
    }

    func testExport() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
            + ["-openBook", "small", "-accent", accent, "-exportPageDelayMs", "700"])
        XCTAssertTrue(app.otherElements["reader.pdfView"].firstMatch.waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["reader.toolbar.more"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@",
                                         "reader.more.exportMarkedUp", "Export Marked-Up PDF")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@",
                                         "reader.more.exportMarkedUp.bookOnly", "Book Only")).firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Export"].firstMatch.tap()
        let background = app.buttons["reader.exportMarkedUp.background"].firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        sleep(1)
        shot("export-progress")
        background.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        sleep(1)
        shot("export-background-pill")
        let share = app.buttons["reader.exportMarkedUp.status.share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 40))
        shot("export-ready-pill")
        app.buttons["reader.toolbar.more"].firstMatch.tap()
        app.buttons["Notebook"].firstMatch.tap()
        XCTAssertTrue(app.buttons["notebook.exportedPDFs.share"].firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        shot("export-notebook")
    }

    func testSyncJoin() {
        let folder = Fixtures.repoRoot.appendingPathComponent("build/sync-ui-test/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + XCUIApplication.importing(Fixtures.noOutline)
            + ["-accent", accent, "-cloudBackupUITest", "active", "-syncTestFolder", folder.path, "-syncTestSeedBook", Fixtures.links])
        XCTAssertTrue(app.buttons["library.book.small"].firstMatch.waitForExistence(timeout: 30))
        openCloud(app)
        shot("cloud-active")
        let toggle = app.switches["sync.toggle"].firstMatch
        scrollTo(toggle, in: app)
        shot("sync-section-off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["sync.join.confirm"].firstMatch.waitForExistence(timeout: 20))
        sleep(1)
        shot("sync-join")
    }

    func testCloudOffer() {
        let app = XCUIApplication.launchFresh(["-accent", accent, "-cloudBackupUITest", "notSubscribed"])
        _ = app.buttons["settings.open"].firstMatch.waitForExistence(timeout: 20)
        openCloud(app)
        shot("cloud-offer")
        app.swipeUp()
        sleep(1)
        shot("cloud-offer-scrolled")
    }
}
