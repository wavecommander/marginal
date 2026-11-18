import UIKit
import XCTest

/// Sync (C4b) with no network: `-cloudBackupUITest active` gives a signed-in subscriber on the
/// app's fakes, `-syncTestFolder` puts the sync account in a folder on the host, and
/// `-syncTestSeedBook` has a second "device" (its own temporary library, the real engine) put
/// books in that account before launch work ends.
///
/// The device imports `small` and `no-outline`; the account holds `small` and `links`. So the
/// join finds one book only here, one only in the account and one on both.
@MainActor
final class SyncUITests: XCTestCase {
    /// Mirrors `AccessibilityID.Sync` and the screens on the way.
    private enum ID {
        static let settingsOpen = "settings.open"
        static let settingsRow = "settings.backup"
        static let saveFile = "backup.file.save"
        static let backupDone = "backup.done"
        static let cloudRow = "backup.destination.tactile-cloud"
        static let cloudStatus = "cloud.status"
        static let toggle = "sync.toggle"
        static let status = "sync.status"
        static let syncNow = "sync.now"
        static let pdfPolicy = "sync.pdfPolicy"
        static let rounds = "sync.debug.rounds"
        static let joinOnlyHere = "sync.join.onlyHere"
        static let joinOnlyInAccount = "sync.join.onlyInAccount"
        static let joinInBoth = "sync.join.inBoth"
        static let joinConfirm = "sync.join.confirm"
        static let recentlyDeletedOpen = "sync.recentlyDeleted.open"
        static let recentlyDeletedEmpty = "sync.recentlyDeleted.empty"
        static func recentlyDeletedRow(_ title: String) -> String { "sync.recentlyDeleted.\(title)" }
        static func recentlyDeletedRestore(_ title: String) -> String { "sync.recentlyDeleted.\(title).restore" }
        static let recentlyDeletedConfirm = "sync.recentlyDeleted.confirm"
        static func book(_ title: String) -> String { "library.book.\(title)" }
        static func download(_ title: String) -> String { "library.book.\(title).download" }
        static func pdfMissing(_ title: String) -> String { "library.book.\(title).pdfMissing" }
        static let pagePill = "reader.pagePill"
        static let notesToggle = "reader.toolbar.notes"
        static let noteText = "notePage.text"
        static let noteStatus = "notePage.status"
    }

    /// Each test's own account folder on the host (the simulator reads host paths).
    private nonisolated let folder = Fixtures.repoRoot.appendingPathComponent("build/sync-ui-test/\(UUID().uuidString)",
                                                                             isDirectory: true)

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func launch(sync: Bool = true, seed: [String] = [Fixtures.small, Fixtures.links]) -> XCUIApplication {
        var arguments = XCUIApplication.importing(Fixtures.small) + XCUIApplication.importing(Fixtures.noOutline)
        if sync {
            arguments += ["-cloudBackupUITest", "active", "-syncTestFolder", folder.path]
            for path in seed { arguments += ["-syncTestSeedBook", path] }
        }
        let app = XCUIApplication.launchFresh(arguments)
        XCTAssertTrue(app.buttons[ID.book("small")].firstMatch.waitForExistence(timeout: 30), "the Library")
        return app
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, _ args: any CVarArg..., timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: args)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func openCloud(_ app: XCUIApplication) {
        let gear = app.buttons[ID.settingsOpen].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        gear.tap()
        let row = app.buttons[ID.settingsRow].firstMatch
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let cloud = app.buttons[ID.cloudRow].firstMatch
        scrollTo(cloud, in: app)
        cloud.tap()
        XCTAssertTrue(any(app, ID.cloudStatus).waitForExistence(timeout: 20), app.debugDescription)
    }

    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons[ID.backupDone].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons[ID.settingsOpen].firstMatch.waitForExistence(timeout: 10))
    }

    /// Swipes the front list up until `element` is there and hittable.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.waitForExistence(timeout: 1), element.isHittable { return }
            let lists = app.collectionViews
            let list = lists.count > 0 ? lists.element(boundBy: lists.count - 1) : app.windows.firstMatch
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
    }

    private func syncSwitch(_ app: XCUIApplication) -> XCUIElement { app.switches[ID.toggle].firstMatch }

    /// Flips the Sync switch (taps the control itself, at the trailing end of its row).
    private func flipSwitch(_ app: XCUIApplication) {
        let toggle = syncSwitch(app)
        scrollTo(toggle, in: app)
        let control = toggle.switches.firstMatch
        if control.exists { control.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
    }

    private func status(_ app: XCUIApplication) -> XCUIElement { any(app, ID.status) }

    private func rounds(_ app: XCUIApplication) -> Int {
        let element = any(app, ID.rounds)
        scrollTo(element, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        return Int((element.value as? String) ?? "") ?? -1
    }

    private func choosePDFsOnlyOnOpen(_ app: XCUIApplication) {
        let picker = app.buttons[ID.pdfPolicy].firstMatch
        scrollTo(picker, in: app)
        picker.tap()
        let option = app.buttons["Only when I open a book"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
        XCTAssertTrue(waitFor(picker, "value CONTAINS %@ OR label CONTAINS %@", "Only when", "Only when", timeout: 5),
                      "picked: \(picker.debugDescription)")
    }

    private func typeNote(_ app: XCUIApplication, _ text: String) {
        app.setPanel(.notes, shown: true)
        let field = app.textViews[ID.noteText].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "note text view")
        field.tap()
        field.typeText(text)
        XCTAssertTrue(waitFor(app.staticTexts[ID.noteStatus].firstMatch, "label == %@", "Saved", timeout: 10), "saved")
    }

    private func backToLibrary(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Library"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(app.buttons[ID.settingsOpen].firstMatch.waitForExistence(timeout: 10))
    }

    // MARK: Tests

    /// Turning Sync on asks to join with the right counts; joining brings the account's second
    /// book without its PDF, in the download state; opening it downloads and opens it; a note
    /// then syncs with Sync Now; turning the switch off stops the rounds.
    func testJoinBringsABookThatDownloadsWhenOpenedThenANoteSyncsAndOffStopsRounds() {
        let app = launch()
        openCloud(app)
        choosePDFsOnlyOnOpen(app)
        XCTAssertTrue(syncSwitch(app).waitForExistence(timeout: 5))
        XCTAssertEqual(syncSwitch(app).value as? String, "0", "off until the reader turns it on")
        XCTAssertTrue(waitFor(status(app), "value == %@", "off"))

        flipSwitch(app)
        let confirm = app.buttons[ID.joinConfirm].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the join sheet: \(app.debugDescription)")
        XCTAssertEqual(any(app, ID.joinOnlyHere).value as? String, "1", "no-outline")
        XCTAssertEqual(any(app, ID.joinOnlyInAccount).value as? String, "1", "links")
        XCTAssertEqual(any(app, ID.joinInBoth).value as? String, "1", "small")
        confirm.tap()
        XCTAssertTrue(waitFor(status(app), "value == %@", "upToDate", timeout: 30), "joined: \(status(app).debugDescription)")
        XCTAssertEqual(syncSwitch(app).value as? String, "1")

        // The account's book is here without its PDF, in the download state (not "PDF missing").
        closeSettings(app)
        let links = app.buttons[ID.book("links")].firstMatch
        XCTAssertTrue(links.waitForExistence(timeout: 15), "the second book arrived")
        let badge = any(app, ID.download("links"))
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "download state: \(app.debugDescription)")
        XCTAssertEqual(badge.value as? String, "notDownloaded")
        XCTAssertFalse(any(app, ID.pdfMissing("links")).exists)
        XCTAssertFalse(any(app, ID.download("small")).exists, "books with their PDFs show nothing")

        // Tapping it downloads the PDF and opens the book.
        links.tap()
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "opened: \(app.debugDescription)")

        // A note, then Sync Now: up to date.
        typeNote(app, "From the second device")
        backToLibrary(app)
        XCTAssertFalse(any(app, ID.download("links")).exists, "downloaded")
        openCloud(app)
        let now = app.buttons[ID.syncNow].firstMatch
        scrollTo(now, in: app)
        now.tap()
        XCTAssertTrue(waitFor(status(app), "value == %@", "upToDate", timeout: 30), "\(status(app).debugDescription)")
        XCTAssertTrue((status(app).label).contains("Up to date"), status(app).label)

        // Off: no further rounds, even after a change has had time to settle.
        let before = rounds(app)
        flipSwitch(app)
        XCTAssertTrue(waitFor(status(app), "value == %@", "off"))
        closeSettings(app)
        app.buttons[ID.book("links")].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30))
        typeNote(app, " and more")
        // Longer than the settle time (three seconds) for a round that must not come.
        sleep(6)
        backToLibrary(app)
        openCloud(app)
        XCTAssertEqual(rounds(app), before, "no rounds while off")
        XCTAssertEqual(syncSwitch(app).value as? String, "0")
    }

    /// C5: a synced book deleted here is in Recently Deleted (the Delete confirmation says so);
    /// Restore brings it back to the Library.
    func testADeletedSyncedBookIsInRecentlyDeletedAndRestoringBringsItBack() {
        let app = launch()
        openCloud(app)
        flipSwitch(app)
        let confirm = app.buttons[ID.joinConfirm].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the join sheet: \(app.debugDescription)")
        confirm.tap()
        XCTAssertTrue(waitFor(status(app), "value == %@", "upToDate", timeout: 30), "joined: \(status(app).debugDescription)")

        // Nothing deleted yet: the empty state.
        let open = app.buttons[ID.recentlyDeletedOpen].firstMatch
        scrollTo(open, in: app)
        open.tap()
        XCTAssertTrue(any(app, ID.recentlyDeletedEmpty).waitForExistence(timeout: 20), app.debugDescription)
        app.navigationBars["Recently Deleted"].buttons.element(boundBy: 0).tap()
        closeSettings(app)

        // Delete the synced book "small", reading what the confirmation says.
        let cell = app.buttons[ID.book("small")].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15))
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).press(forDuration: 1.0)
        let delete = app.buttons["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Recently Deleted'")).firstMatch.exists,
                      app.debugDescription)
        alert.buttons["Delete"].tap()
        XCTAssertTrue(cell.waitForNonExistence(timeout: 10))

        // Sync the deletion, then find it in Recently Deleted and restore it.
        openCloud(app)
        let now = app.buttons[ID.syncNow].firstMatch
        scrollTo(now, in: app)
        now.tap()
        XCTAssertTrue(waitFor(status(app), "value == %@", "upToDate", timeout: 30), "\(status(app).debugDescription)")
        scrollTo(open, in: app)
        open.tap()
        let row = any(app, ID.recentlyDeletedRow("small"))
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(row.label.contains("Deleted on this iPad"), row.label)
        XCTAssertTrue(row.label.contains("days left") || row.label.contains("Last day"), row.label)
        app.buttons[ID.recentlyDeletedRestore("small")].firstMatch.tap()
        let confirmAlert = app.alerts.firstMatch
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirmAlert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'other devices'")).firstMatch.exists,
                      app.debugDescription)
        let byID = confirmAlert.buttons[ID.recentlyDeletedConfirm].firstMatch
        (byID.exists ? byID : confirmAlert.buttons["Restore"].firstMatch).tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "restored: \(app.debugDescription)")

        // Back in the Library.
        app.navigationBars["Recently Deleted"].buttons.element(boundBy: 0).tap()
        closeSettings(app)
        XCTAssertTrue(app.buttons[ID.book("small")].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
    }

    /// Not Now on the join sheet leaves the switch off and changes nothing.
    func testNotNowLeavesSyncOff() {
        let app = launch()
        openCloud(app)
        flipSwitch(app)
        let notNow = app.buttons["sync.join.notNow"].firstMatch
        XCTAssertTrue(notNow.waitForExistence(timeout: 20))
        notNow.tap()
        XCTAssertTrue(waitFor(status(app), "value == %@", "off"))
        XCTAssertEqual(syncSwitch(app).value as? String, "0")
        closeSettings(app)
        XCTAssertFalse(app.buttons[ID.book("links")].firstMatch.waitForExistence(timeout: 3), "nothing joined")
    }

    /// A build without the service (the default) shows no sync anywhere.
    func testADefaultBuildShowsNoSync() {
        let app = launch(sync: false)
        XCTAssertFalse(any(app, ID.download("small")).exists)
        let gear = app.buttons[ID.settingsOpen].firstMatch
        gear.tap()
        let row = app.buttons[ID.settingsRow].firstMatch
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[ID.cloudRow].firstMatch.exists, "no Tactile Texts Cloud")
        XCTAssertFalse(syncSwitch(app).exists, "no Sync switch")
    }
}
