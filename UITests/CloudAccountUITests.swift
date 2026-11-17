import XCTest

/// Signing in to Tactile Texts Cloud (C2) on the app's debug fakes (`-cloudBackupUITest
/// <state>`: a scripted StoreKit, Apple and Google that answer at once, and a fake Worker), so no
/// Apple, Google or Cloudflare account is needed.
///
/// The rule under every test (owner decision 7): signing out, signing out everywhere, changing
/// the sign-in, an ended session and a deleted account leave the library on the device exactly as
/// it was. After each, a book is opened and its note edited.
@MainActor
final class CloudAccountUITests: XCTestCase {
    /// Mirrors `AccessibilityID.CloudBackup` and the Backup screen's and reader's IDs.
    private enum ID {
        static let settingsOpen = "settings.open"
        static let settingsRow = "settings.backup"
        static let saveFile = "backup.file.save"
        static let done = "backup.done"
        static let cloudRow = "backup.destination.tactile-cloud"
        static let backUpNow = "backup.destinationScreen.backUpNow"
        static let offer = "cloud.offer"
        static let subscribe = "cloud.subscribe.software.tactile.texts.backup.standard"
        static let restorePurchases = "cloud.restorePurchases"
        static let status = "cloud.status"
        static let signInApple = "cloud.signIn.apple"
        static let signInGoogle = "cloud.signIn.google"
        static let signedOutNotice = "cloud.signedOut"
        static let accountSignIn = "cloud.account.signIn"
        static let device0 = "cloud.account.device.0"
        static let changeSignIn = "cloud.account.change"
        static let signOut = "cloud.account.signOut"
        static let signOutAll = "cloud.account.signOutAll"
        static let deleteAccount = "cloud.account.delete"
        static let keyScreen = "cloud.recoveryKey"
        static let keyClose = "cloud.recoveryKey.close"
        static let book = "library.book.small"
        static let pagePill = "reader.pagePill"
        static let noteText = "notePage.text"
        static let noteStatus = "notePage.status"
    }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    // MARK: Helpers

    private func launch(_ state: String) -> XCUIApplication {
        XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small) + ["-cloudBackupUITest", state])
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openCloud(_ app: XCUIApplication) {
        let gear = app.buttons[ID.settingsOpen].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()
        XCTAssertTrue(app.buttons["settings.done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let row = app.buttons[ID.settingsRow].firstMatch
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let cloud = app.buttons[ID.cloudRow].firstMatch
        scrollTo(cloud, in: app)
        XCTAssertTrue(cloud.waitForExistence(timeout: 5), app.debugDescription)
        cloud.tap()
    }

    private func closeSettings(_ app: XCUIApplication) {
        app.buttons[ID.done].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.book].firstMatch.waitForExistence(timeout: 10), "back in the Library: \(app.debugDescription)")
    }

    /// Swipes the front list up until `element` is there and hittable.
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

    private func scrollToTop(_ app: XCUIApplication) {
        let lists = app.collectionViews
        guard lists.count > 0 else { return }
        let list = lists.element(boundBy: lists.count - 1)
        for _ in 0..<3 {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier].firstMatch
        scrollTo(button, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(identifier): \(app.debugDescription)")
        button.tap()
    }

    /// Confirms the alert on screen with `button`, after checking its message says `contains`.
    private func confirm(_ app: XCUIApplication, _ button: String, saying contains: [String], thenAnotherAlert: Bool = false) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        for text in contains {
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).count > 0,
                          "the confirmation says “\(text)”: \(alert.debugDescription)")
        }
        alert.buttons[button].tap()
        if !thenAnotherAlert { XCTAssertTrue(alert.waitForNonExistence(timeout: 5)) }
    }

    /// Signs in with `button` on the offer and waits for the page to follow.
    private func signIn(_ app: XCUIApplication, _ button: String) {
        let element = any(app, button)
        XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription)
        element.tap()
        XCTAssertTrue(any(app, ID.signInApple).waitForNonExistence(timeout: 15), "signed in: \(app.debugDescription)")
    }

    /// The Account section's sign-in row, scrolled to.
    private func accountRow(_ app: XCUIApplication) -> XCUIElement {
        let row = any(app, ID.accountSignIn)
        scrollTo(row, in: app)
        return row
    }

    /// The signed-out offer: both sign-in buttons, no Subscribe or Restore Purchases.
    private func expectSignedOut(_ app: XCUIApplication) {
        XCTAssertTrue(any(app, ID.offer).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(any(app, ID.signInApple).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons[ID.signInGoogle].exists, "both sign-ins at equal weight")
        let apple = any(app, ID.signInApple).frame, google = app.buttons[ID.signInGoogle].firstMatch.frame
        XCTAssertEqual(apple.width, google.width, accuracy: 1)
        XCTAssertEqual(apple.height, google.height, accuracy: 1)
        XCTAssertFalse(app.buttons[ID.subscribe].exists, "subscribing needs an account")
        XCTAssertFalse(app.buttons[ID.restorePurchases].exists)
        XCTAssertFalse(any(app, ID.accountSignIn).exists)
    }

    /// The library is intact: the book opens, and its page note takes an edit and saves it.
    private func editNote(_ app: XCUIApplication, _ text: String) {
        let cell = app.buttons[ID.book].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "the book is still in the Library: \(app.debugDescription)")
        cell.tap()
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "the book opens")
        XCTAssertTrue(app.setPanel(.notes, shown: true), "notes panel")
        let note = app.textViews[ID.noteText].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "note text view")
        let before = (note.value as? String) ?? ""
        note.tap()
        note.typeText(text)
        XCTAssertTrue(waitFor(note, "value CONTAINS %@".replacingOccurrences(of: "%@", with: "'\(text)'")), "typed: \(String(describing: note.value))")
        XCTAssertTrue(waitFor(app.staticTexts[ID.noteStatus].firstMatch, "label == 'Saved'"), "the note saves")
        if !before.isEmpty, before != "Write a note…" {
            XCTAssertTrue((note.value as? String)?.contains(before) == true, "what was there is still there")
        }
        app.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
    }

    private func backUpNow(_ app: XCUIApplication) {
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
        let backUp = app.buttons[ID.backUpNow].firstMatch
        scrollTo(backUp, in: app)
        XCTAssertTrue(waitFor(backUp, "isEnabled == true", timeout: 15), app.debugDescription)
        backUp.tap()
    }

    /// Scrolls down until at least `count` backup rows have been seen (rows off screen are not
    /// in the tree), waiting for the list to load; returns how many were seen.
    private func seeSnapshots(_ count: Int, in app: XCUIApplication) -> Int {
        var seen = Set<String>()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'backup.snapshot.'"))
        for _ in 0..<12 {
            for row in rows.allElementsBoundByIndex where row.exists { seen.insert(row.identifier) }
            if seen.count >= count { break }
            let lists = app.collectionViews
            guard lists.count > 0 else { break }
            let list = lists.element(boundBy: lists.count - 1)
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            sleep(1)
        }
        return seen.count
    }

    // MARK: Tests

    /// Signed out: sign in with Apple, subscribe, back up; sign out (the library stays); sign back
    /// in and the same account carries on with its backup.
    func testSignInBackUpSignOutAndSignBackIn() {
        let app = launch("signedOut")
        openCloud(app)
        expectSignedOut(app)

        signIn(app, ID.signInApple)
        XCTAssertTrue(waitFor(accountRow(app), "label CONTAINS 'Signed in with Apple'"), app.debugDescription)
        XCTAssertTrue(any(app, ID.accountSignIn).label.contains("reader@privaterelay.appleid.com"), "the email, on this device")
        scrollToTop(app)
        tap(ID.subscribe, in: app)
        backUpNow(app)
        XCTAssertTrue(any(app, ID.keyScreen).waitForExistence(timeout: 60), "the first backup made the key: \(app.debugDescription)")
        app.buttons[ID.keyClose].firstMatch.tap()
        XCTAssertTrue(any(app, ID.keyScreen).waitForNonExistence(timeout: 5))
        let device = any(app, ID.device0)
        scrollTo(device, in: app)
        XCTAssertTrue(device.waitForExistence(timeout: 10), "the devices are listed: \(app.debugDescription)")
        XCTAssertTrue(device.label.hasPrefix("This \(Fixtures.deviceName)"), "this device by its kind: \(device.label)")
        let other = any(app, "cloud.account.device.1")
        scrollTo(other, in: app)
        XCTAssertTrue(other.label.hasPrefix("Another device"), "a device whose label can't be opened: \(other.label)")

        tap(ID.signOut, in: app)
        confirm(app, "Sign Out", saying: ["stay on this \(Fixtures.deviceName)", "won’t be backed up"])
        expectSignedOut(app)
        closeSettings(app)
        editNote(app, "Signed out ")

        openCloud(app)
        signIn(app, ID.signInApple)
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), "the subscription carries on: \(app.debugDescription)")
        scrollTo(app.buttons[ID.backUpNow].firstMatch, in: app)
        XCTAssertTrue(waitFor(app.buttons[ID.backUpNow].firstMatch, "isEnabled == true", timeout: 15))
        XCTAssertGreaterThan(seeSnapshots(1, in: app), 0, "the backup made before signing out is there: \(app.debugDescription)")
        XCTAssertFalse(any(app, ID.signedOutNotice).exists)
    }

    /// Sign Out of All Devices: this device is signed out too, and keeps its library.
    func testSignOutOfAllDevicesKeepsTheLibrary() {
        let app = launch("active")
        openCloud(app)
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
        tap(ID.signOutAll, in: app)
        confirm(app, "Sign Out of All Devices", saying: ["Every device", "books on each device stay as they are"])
        expectSignedOut(app)
        closeSettings(app)
        editNote(app, "Everywhere ")
    }

    /// Change to Sign in with Google: the account stays, the page then offers to sign out every
    /// device; the library stays.
    func testChangingTheSignInKeepsTheAccountAndTheLibrary() {
        let app = launch("active")
        openCloud(app)
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(accountRow(app), "label CONTAINS 'Signed in with Apple'", timeout: 15), app.debugDescription)
        tap(ID.changeSignIn, in: app)
        confirm(app, "Continue", saying: ["First confirm with Apple, then sign in with Google", "books on this \(Fixtures.deviceName) aren’t touched"],
                thenAnotherAlert: true)
        let changed = app.alerts.firstMatch
        XCTAssertTrue(changed.buttons["Sign Out of All Devices…"].waitForExistence(timeout: 15),
                      "the change suggests signing out everywhere: \(app.debugDescription)")
        changed.buttons["Not Now"].tap()
        XCTAssertTrue(waitFor(accountRow(app), "label CONTAINS 'Signed in with Google'"), any(app, ID.accountSignIn).label)
        XCTAssertTrue(any(app, ID.accountSignIn).label.contains("reader@gmail.example"))
        XCTAssertTrue(app.buttons[ID.changeSignIn].label.contains("Apple"), "and it can change back")
        XCTAssertTrue(any(app, ID.status).exists, "still subscribed, still signed in")
        closeSettings(app)
        editNote(app, "Changed ")
    }

    /// An ended session (signed out on another device): the page says so and that the books are
    /// no longer backed up, the library stays, and signing in again carries on with the backups.
    func testAnEndedSessionSignsOutAndSigningInCarriesOn() {
        let app = launch("sessionExpired")
        openCloud(app)
        let notice = any(app, ID.signedOutNotice)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(notice.label.contains("aren’t being backed up"), notice.label)
        expectSignedOut(app)
        closeSettings(app)
        editNote(app, "Expired ")

        openCloud(app)
        signIn(app, ID.signInGoogle)
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
        scrollTo(app.buttons[ID.backUpNow].firstMatch, in: app)
        XCTAssertEqual(seeSnapshots(2, in: app), 2, "the account's backups are there: \(app.debugDescription)")
    }

    /// Delete Account: the confirmation says the books stay and the subscription isn't
    /// cancelled; afterwards the device is signed out with the library intact.
    func testDeletingTheAccountKeepsTheLibrary() {
        let app = launch("active")
        openCloud(app)
        XCTAssertTrue(any(app, ID.status).waitForExistence(timeout: 15), app.debugDescription)
        tap(ID.deleteAccount, in: app)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[ID.deleteAccount].exists, "nothing happens after Cancel")

        tap(ID.deleteAccount, in: app)
        confirm(app, "Delete Account", saying: ["stay exactly as they are", "subscription isn’t cancelled", "Manage Subscription"])
        let notice = any(app, ID.signedOutNotice)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(notice.label.contains("deleted") && notice.label.contains("Manage Subscription"), notice.label)
        expectSignedOut(app)
        closeSettings(app)
        editNote(app, "Deleted ")
    }

    /// A build with every setting empty shows no sign-in anywhere: no cloud row, no button.
    func testADefaultBuildShowsNoSignIn() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small))
        let gear = app.buttons[ID.settingsOpen].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        XCTAssertFalse(any(app, ID.signInApple).exists)
        gear.tap()
        let row = app.buttons[ID.settingsRow].firstMatch
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[ID.cloudRow].exists)
        XCTAssertFalse(any(app, ID.signInApple).exists)
        XCTAssertFalse(any(app, ID.signInGoogle).exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sign in with'")).count, 0)
    }
}
