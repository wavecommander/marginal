import UIKit
import XCTest

/// Tactile Texts Cloud (C5) on the app's debug fakes: `-cloudBackupUITest <state>` builds the
/// service from a scripted StoreKit, a fake Worker and a folder standing in for R2
/// (`CloudBackupUITestMode`), since UI tests can reach neither the App Store nor a Worker.
///
/// The seeded states hold two empty backups made with the key whose recovery key is
/// `Keys.right`.
@MainActor
final class CloudBackupUITests: XCTestCase {
    /// Mirrors `AccessibilityID.CloudBackup` and the Backup screen's IDs.
    private enum ID {
        static let settingsOpen = "settings.open"
        static let settingsRow = "settings.backup"
        static let saveFile = "backup.file.save"
        static let footnote = "backup.footnote"
        static let cloudRow = "backup.destination.tactile-cloud"
        static let backUpNow = "backup.destinationScreen.backUpNow"
        static let destinationResult = "backup.destinationScreen.result"
        static let offer = "cloud.offer"
        static let subscribe = "cloud.subscribe.software.tactile.texts.backup.standard"
        static let restorePurchases = "cloud.restorePurchases"
        static let status = "cloud.status"
        static let banner = "cloud.banner"
        static let bannerEnterKey = "cloud.banner.enterKey"
        static let bannerTryAgain = "cloud.banner.tryAgain"
        static let plan = "cloud.plan"
        static let usage = "cloud.usage"
        static let keyReminder = "cloud.keyReminder"
        static let showKey = "cloud.showKey"
        static let deleteAll = "cloud.deleteAll"
        static let notice = "cloud.notice"
        static let keyScreen = "cloud.recoveryKey"
        static let keyText = "cloud.recoveryKey.text"
        static let keySaved = "cloud.recoveryKey.saved"
        static let keyClose = "cloud.recoveryKey.close"
        static let enterScreen = "cloud.enterKey"
        static let enterField = "cloud.enterKey.field"
        static let enterSubmit = "cloud.enterKey.submit"
        static let enterError = "cloud.enterKey.error"
        static let enterTryAgain = "cloud.enterKey.tryAgain"
        static let enterStartOver = "cloud.enterKey.startOver"
        static let restoreHeader = "restore.header"
        static let restoreCancel = "restore.cancel"
    }

    /// `CloudBackupUITestMode.recoveryKey` and `.otherRecoveryKey`.
    private enum Keys {
        static let right = "0C51-260Z-4RPK-8ET2-9585-EQK5-DHSQ-N0C8-HYB9-V95B-PAWW-1HYE-TQE0-045G"
        static let other = "CNS7-Z34S-MTSW-1KET-WZT0-23GV-50TM-4KTW-D5V8-744X-NAVW-9MEY-XFW0-R2A5"
        /// `right` with one character changed: caught by the check characters.
        static let mistyped = "0C51-260Z-4RPK-8ET2-9585-EQK5-DHSQ-N0C8-HYB9-V95B-PAWW-1HYE-TQE0-045H"
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func launch(_ state: String?, fixtures: [String] = []) -> XCUIApplication {
        var arguments = fixtures.flatMap { XCUIApplication.importing($0) }
        if let state { arguments += ["-cloudBackupUITest", state] }
        return XCUIApplication.launchFresh(arguments + shotArguments)
    }

    /// Extra launch arguments for the screenshot runs (`TEST_RUNNER_CLOUD_SHOT_ARGS`).
    private var shotArguments: [String] {
        (ProcessInfo.processInfo.environment["CLOUD_SHOT_ARGS"] ?? "").split(separator: " ").map(String.init)
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func snapshotRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'backup.snapshot.'"))
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openBackupScreen(_ app: XCUIApplication) {
        let gear = app.buttons[ID.settingsOpen].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        gear.tap()
        let row = app.buttons[ID.settingsRow].firstMatch
        XCTAssertTrue(app.buttons["settings.done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func openCloud(_ app: XCUIApplication) {
        openBackupScreen(app)
        let row = app.buttons[ID.cloudRow].firstMatch
        scrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
    }

    /// Opens the cloud screen and waits for its status page.
    private func openStatus(_ app: XCUIApplication) {
        openCloud(app)
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
    }

    /// Swipes the front list up until `element` is there and hittable (see BackupUITests).
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1), element.isHittable { return }
            let lists = app.collectionViews
            let list = lists.count > 0 ? lists.element(boundBy: lists.count - 1) : app.windows.firstMatch
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
    }

    /// Scrolls down the list until at least `count` backup rows have been seen (rows off screen
    /// are not in the tree), and returns how many were seen.
    @discardableResult
    private func seeSnapshots(_ count: Int, in app: XCUIApplication) -> Int {
        var seen = Set<String>()
        for _ in 0..<8 {
            for row in snapshotRows(app).allElementsBoundByIndex where row.exists { seen.insert(row.identifier) }
            if seen.count >= count { break }
            let lists = app.collectionViews
            guard lists.count > 0 else { break }
            let list = lists.element(boundBy: lists.count - 1)
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        return seen.count
    }

    private func scrollToTop(_ app: XCUIApplication) {
        let lists = app.collectionViews
        guard lists.count > 0 else { return }
        let list = lists.element(boundBy: lists.count - 1)
        for _ in 0..<3 {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
    }

    /// Replaces the recovery key field's text with `text`.
    private func enterKey(_ text: String, in app: XCUIApplication) {
        let field = any(app, ID.enterField)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty, current != "Recovery key" {
            // Select everything typed so far, wherever the tap put the cursor; typing replaces it.
            field.typeKey("a", modifierFlags: .command)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
        let submit = app.buttons[ID.enterSubmit].firstMatch
        submit.tap()
        // A tap that lands while the field is still editing is sometimes taken as ending the
        // editing only: if nothing happened (no error, still open), tap once more.
        let error = any(app, ID.enterError), screen = any(app, ID.enterScreen)
        var answered = false
        for _ in 0..<16 where !answered {
            answered = error.exists || screen.waitForNonExistence(timeout: 0.5)
        }
        if !answered, submit.exists, submit.isEnabled { submit.tap() }
    }

    // MARK: Tests

    /// The offer shows the App Store's price and period; subscribing leads to the status page.
    func testOfferShowsThePriceAndSubscribingShowsTheStatus() {
        let app = launch("notSubscribed")
        openCloud(app)
        XCTAssertTrue(any(app, ID.offer).waitForExistence(timeout: 15), app.debugDescription)
        let subscribe = app.buttons[ID.subscribe].firstMatch
        scrollTo(subscribe, in: app)
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(subscribe.label.contains("£2.99"), subscribe.label)
        XCTAssertTrue(subscribe.label.contains("a month"), subscribe.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "encrypted on this \(Fixtures.deviceName)")).count > 0,
                      "says backups are encrypted on the device")
        let restorePurchases = app.buttons[ID.restorePurchases].firstMatch
        scrollTo(restorePurchases, in: app)
        XCTAssertTrue(restorePurchases.exists, app.debugDescription)
        scrollToTop(app)

        subscribe.tap()
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(any(app, ID.plan), "value CONTAINS 'Cloud Backup'"), String(describing: any(app, ID.plan).value))
        XCTAssertFalse(any(app, ID.banner).exists, "an active subscription has no banner")
        let backUp = app.buttons[ID.backUpNow].firstMatch
        scrollTo(backUp, in: app)
        XCTAssertTrue(waitFor(backUp, "isEnabled == true"), "Back Up Now works once subscribed")
    }

    /// The first backup makes the key and asks the reader to save its recovery key; "Not Now"
    /// keeps a quiet reminder until "I’ve Saved It".
    func testFirstBackupPromptsForTheRecoveryKeyUntilSaved() {
        let app = launch("active", fixtures: [Fixtures.small])
        openStatus(app)
        XCTAssertFalse(any(app, ID.keyReminder).exists, "no key yet, so nothing to save")
        let backUp = app.buttons[ID.backUpNow].firstMatch
        scrollTo(backUp, in: app)
        XCTAssertTrue(waitFor(backUp, "isEnabled == true"), app.debugDescription)
        backUp.tap()

        // The prompt follows the backup that made the key.
        XCTAssertTrue(any(app, ID.keyScreen).waitForExistence(timeout: 60), app.debugDescription)
        let key = any(app, ID.keyText)
        XCTAssertTrue(key.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual((key.value as? String)?.components(separatedBy: "Group ").count, 15, "14 groups")
        app.buttons[ID.keyClose].firstMatch.tap()
        XCTAssertTrue(any(app, ID.keyScreen).waitForNonExistence(timeout: 5))

        // Not saved yet: a reminder stays, and the backup is listed.
        let reminder = any(app, ID.keyReminder)
        scrollTo(reminder, in: app)
        XCTAssertTrue(reminder.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(seeSnapshots(1, in: app), 1, "the backup is listed: \(app.debugDescription)")
        let show = app.buttons[ID.showKey].firstMatch
        scrollTo(show, in: app)
        show.tap()
        let saved = app.buttons[ID.keySaved].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), app.debugDescription)
        saved.tap()
        XCTAssertTrue(any(app, ID.keyScreen).waitForNonExistence(timeout: 5))
        XCTAssertTrue(reminder.waitForNonExistence(timeout: 5), "the reminder goes once the key is saved")
        XCTAssertTrue(app.buttons[ID.showKey].exists, "the key can still be shown")
    }

    /// Read-only: a banner with dates, Back Up Now off, and the backups can still be restored.
    func testReadOnlyShowsItsBannerRefusesABackupAndOffersRestore() {
        let app = launch("readOnly", fixtures: [Fixtures.small])
        openStatus(app)
        let banner = any(app, ID.banner)
        XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(banner.label.contains("You can restore from your backups until"), banner.label)
        XCTAssertTrue(banner.label.contains("deleted after"), banner.label)

        let backUp = app.buttons[ID.backUpNow].firstMatch
        scrollTo(backUp, in: app)
        XCTAssertTrue(backUp.exists, app.debugDescription)
        XCTAssertFalse(backUp.isEnabled, "no new backups while read-only")

        XCTAssertEqual(seeSnapshots(2, in: app), 2, app.debugDescription)
        let row = snapshotRows(app).firstMatch
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(any(app, ID.restoreHeader).waitForExistence(timeout: 20), "the backup opens for restore: \(app.debugDescription)")
        app.buttons[ID.restoreCancel].firstMatch.tap()
    }

    /// Needs the recovery key: a valid key that isn't the backups' is refused, a mistyped one
    /// says so, and the right one (in lower case with spaces) opens the backups.
    func testNeedsRecoveryKeyRejectsAWrongKeyAndAcceptsTheRightOne() {
        let app = launch("needsRecoveryKey")
        openStatus(app)
        let banner = any(app, ID.banner)
        XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(banner.label.contains("iCloud Keychain"), "says first that the key may still be arriving: \(banner.label)")
        XCTAssertTrue(app.buttons[ID.bannerTryAgain].exists)
        app.buttons[ID.bannerEnterKey].firstMatch.tap()
        XCTAssertTrue(any(app, ID.enterScreen).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons[ID.enterTryAgain].exists, "Try Again first, the key may be on its way")

        enterKey(Keys.other, in: app)
        let error = any(app, ID.enterError)
        XCTAssertTrue(error.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(error.label.contains("isn’t the one"), error.label)

        enterKey(Keys.mistyped, in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(error, "label CONTAINS 'typing mistake'"), error.label)

        enterKey("0c51 260z 4rpk 8et2 9585 eqk5 dhsq n0c8 hyb9 v95b paww 1hye tqe0 045g", in: app)
        XCTAssertTrue(any(app, ID.enterScreen).waitForNonExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "no banner once the key is entered")
        XCTAssertEqual(seeSnapshots(2, in: app), 2, app.debugDescription)
    }

    /// Delete My Cloud Backups asks first, says the subscription isn't cancelled, and deletes
    /// everything when confirmed.
    func testDeleteMyCloudBackupsAsksForConfirmation() {
        let app = launch("overAllowance")
        openStatus(app)
        XCTAssertTrue(any(app, ID.banner).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(seeSnapshots(2, in: app), 2, app.debugDescription)
        let delete = app.buttons[ID.deleteAll].firstMatch
        scrollTo(delete, in: app)
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'subscription isn’t cancelled'")).count > 0,
                      alert.debugDescription)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(snapshotRows(app).count, 0, "nothing deleted after Cancel")

        scrollTo(delete, in: app)
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete My Cloud Backups"].tap()
        let notice = any(app, ID.notice)
        scrollTo(notice, in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), app.debugDescription)
        scrollToTop(app)
        XCTAssertEqual(seeSnapshots(1, in: app), 0, "every backup is gone")
        // The Account section below can push the empty list's row out of view.
        scrollToTop(app)
        let empty = any(app, "backup.snapshots.empty")
        scrollTo(empty, in: app)
        XCTAssertTrue(empty.exists, app.debugDescription)
    }

    /// Without the launch argument (the default build has no service configured) the Backup
    /// screen has no cloud row, and its footnote says backups aren't encrypted.
    func testDefaultBuildHasNoCloudRow() {
        let app = launch(nil)
        openBackupScreen(app)
        let footnote = any(app, ID.footnote)
        scrollTo(footnote, in: app)
        XCTAssertTrue(footnote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons[ID.cloudRow].exists, "no Tactile Texts Cloud row")
        XCTAssertTrue(footnote.label.hasPrefix("Backups aren’t encrypted."), footnote.label)
    }

    // MARK: Screenshots

    /// Each state's page to `build/c5-screens/<name><suffix>.png`, when `TEST_RUNNER_CLOUD_SHOTS`
    /// is set (`TEST_RUNNER_CLOUD_SHOT_SUFFIX`, e.g. `-dark` after
    /// `xcrun simctl ui <device> appearance dark`). Checks nothing of its own.
    func testScreenshots() throws {
        guard ProcessInfo.processInfo.environment["CLOUD_SHOTS"] != nil else {
            throw XCTSkip("set TEST_RUNNER_CLOUD_SHOTS=1 to save the Tactile Texts Cloud screenshots")
        }
        var app = launch("notSubscribed")
        openCloud(app)
        XCTAssertTrue(any(app, ID.offer).waitForExistence(timeout: 15))
        sleep(1)
        try save("offer", app)
        app.terminate()

        app = launch("active", fixtures: [Fixtures.small])
        openStatus(app)
        let backUp = app.buttons[ID.backUpNow].firstMatch
        scrollTo(backUp, in: app)
        XCTAssertTrue(waitFor(backUp, "isEnabled == true"))
        backUp.tap()
        XCTAssertTrue(any(app, ID.keyText).waitForExistence(timeout: 60))
        sleep(1)
        try save("recovery-key-prompt", app)
        app.buttons[ID.keyClose].firstMatch.tap()
        XCTAssertTrue(any(app, ID.keyScreen).waitForNonExistence(timeout: 5))
        scrollToTop(app)
        sleep(1)
        try save("active", app)
        let delete = app.buttons[ID.deleteAll].firstMatch
        scrollTo(delete, in: app)
        delete.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        try save("delete-confirmation", app)
        app.alerts.firstMatch.buttons["Cancel"].tap()
        app.terminate()

        for state in ["readOnly", "overAllowance", "lapsed", "unreachable"] {
            app = launch(state)
            openStatus(app)
            XCTAssertTrue(any(app, ID.banner).waitForExistence(timeout: 15), state)
            sleep(1)
            try save(state, app)
            app.terminate()
        }

        app = launch("needsRecoveryKey")
        openStatus(app)
        XCTAssertTrue(any(app, ID.banner).waitForExistence(timeout: 15))
        sleep(1)
        try save("needsRecoveryKey", app)
        app.buttons[ID.bannerEnterKey].firstMatch.tap()
        XCTAssertTrue(any(app, ID.enterScreen).waitForExistence(timeout: 5))
        enterKey(Keys.mistyped, in: app)
        XCTAssertTrue(any(app, ID.enterError).waitForExistence(timeout: 15))
        // Hide the keyboard so the error shows.
        app.navigationBars["Enter Recovery Key"].staticTexts["Enter Recovery Key"].firstMatch.tap()
        let hide = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard'")).firstMatch
        if app.keyboards.count > 0, hide.exists { hide.tap() }
        sleep(1)
        try save("enter-recovery-key", app)
        app.buttons[ID.enterStartOver].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        try save("start-over-confirmation", app)
        app.alerts.firstMatch.buttons["Cancel"].tap()
        app.terminate()

        // Portrait, narrow: the offer.
        XCUIDevice.shared.orientation = .portrait
        app = launch("notSubscribed")
        openCloud(app)
        XCTAssertTrue(any(app, ID.offer).waitForExistence(timeout: 15))
        sleep(2)
        try save("offer-portrait", app)
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func save(_ name: String, _ app: XCUIApplication) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/c5-screens", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = ProcessInfo.processInfo.environment["CLOUD_SHOT_SUFFIX"] ?? ""
        let image = XCUIScreen.main.screenshot().image
        let upright = UIGraphicsImageRenderer(size: image.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            return format
        }()).image { _ in image.draw(at: .zero) }
        try upright.pngData()?.write(to: directory.appendingPathComponent("\(name)\(suffix).png"))
    }
}
