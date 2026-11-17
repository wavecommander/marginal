import UIKit
import XCTest

/// Backup & Restore (B4) through a real folder destination injected with `-backupFolder <path>`
/// (a folder under `build/backup-ui-tests/` that each test creates; the system document picker
/// cannot be driven, so the backup-file and Choose Folder… flows are not covered here).
///
/// `small.pdf`: 12 pages; its title in the Library is "small".
@MainActor
final class BackupUITests: XCTestCase {
    /// Mirrors `AccessibilityID.Backup`, `.Restore` and the Library's additions.
    private enum ID {
        static let settingsOpen = "settings.open"
        static let settingsRow = "settings.backup"
        static let done = "backup.done"
        static let saveFile = "backup.file.save"
        static let fileEstimate = "backup.file.estimate"
        static let backUpNow = "backup.destinationScreen.backUpNow"
        static let destinationIncludePDFs = "backup.destinationScreen.includePDFs"
        static let fileIncludePDFs = "backup.file.includePDFs"
        static let destinationResult = "backup.destinationScreen.result"
        static let snapshotsEmpty = "backup.snapshots.empty"
        static let progress = "backup.progress"
        static let progressCancel = "backup.progress.cancel"
        static let libraryProgress = "library.backupProgress"
        static let emptyRestore = "library.emptyRestoreButton"
        static let confirm = "restore.confirm"
        static let summary = "restore.summary"
        static let restoreDone = "restore.done"
        static let restoreCancel = "restore.cancel"
        static let noteText = "notePage.text"
        static let noteStatus = "notePage.status"
        static let pagePill = "reader.pagePill"
        static func destination(_ id: String) -> String { "backup.destination.\(id)" }
        static func restoreBook(_ title: String) -> String { "restore.book.\(title)" }
        static func replaceWarning(_ title: String) -> String { "restore.book.\(title).replaceWarning" }
        static func action(_ title: String) -> String { "restore.book.\(title).action" }
        static func mergeText(_ title: String) -> String { "restore.book.\(title).mergeText" }
        static func leaveText(_ title: String) -> String { "restore.book.\(title).leaveText" }
        static let mergeFootnote = "restore.mergeFootnote"
        static func merged(_ title: String) -> String { "restore.summary.merged.\(title)" }
        static let undoHint = "restore.summary.undoHint"
        static let undoRestore = "backup.undoRestore"
        static let undoResult = "backup.undoRestore.result"
        static func locate(_ title: String) -> String { "restore.summary.locate.\(title)" }
    }

    // Set up per test in the nonisolated `setUp`.
    nonisolated(unsafe) private var folder: URL!
    nonisolated(unsafe) private var scratch: URL!
    private var folderID: String { "folder:\(folder.path)" }

    override func setUp() {
        continueAfterFailure = false
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
        scratch = Fixtures.repoRoot.appendingPathComponent("build/backup-ui-tests/\(UUID().uuidString)", isDirectory: true)
        folder = scratch.appendingPathComponent("Backups Folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Helpers

    private func launch(_ fixtures: [String], extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchFresh(fixtures.flatMap { XCUIApplication.importing($0) } + ["-backupFolder", folder.path] + extra
                                    + shotArguments)
    }

    /// Extra launch arguments for the screenshot runs (`TEST_RUNNER_BACKUP_SHOT_ARGS`), e.g. the
    /// largest text size: `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL`.
    private var shotArguments: [String] {
        (ProcessInfo.processInfo.environment["BACKUP_SHOT_ARGS"] ?? "").split(separator: " ").map(String.init)
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func book(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["library.book.\(title)"].firstMatch
    }

    private func snapshotRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'backup.snapshot.'"))
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Types a page note on page 1 of "small" (the reader opened by `-openBook`) and waits for it to save.
    private func addNote(_ app: XCUIApplication, _ text: String) {
        XCTAssertTrue(app.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "reader open")
        let field = app.textViews[ID.noteText].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "note text view")
        field.tap()
        field.typeText(text)
        XCTAssertTrue(waitFor(app.staticTexts[ID.noteStatus].firstMatch, "label == 'Saved'"), "note saved")
        app.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 10))
    }

    /// Launches the app again on the same data (not fresh), with "small" open on page 1 and its
    /// page note showing.
    private func relaunchIntoReader(_ app: XCUIApplication) -> XCUIApplication {
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-openBook", "small", "-openPage", "1", "-notesPanel", "page", "-backupFolder", folder.path]
            + shotArguments
        again.launch()
        XCTAssertTrue(again.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "the book opens")
        XCTAssertTrue(again.textViews[ID.noteText].firstMatch.waitForExistence(timeout: 10), "note text view")
        return again
    }

    /// The text of the page-1 note in the open reader.
    private func noteValue(_ app: XCUIApplication) -> String {
        app.textViews[ID.noteText].firstMatch.value as? String ?? ""
    }

    /// Picks `choice` from the Merge / Replace with Backup / Leave as Is menu of `title`'s row.
    private func choose(_ choice: String, for title: String, in app: XCUIApplication) {
        let menu = any(app, ID.action(title))
        // A menu button can be reported as not hittable while it is on screen, so scroll only
        // when it isn't there at all.
        if !menu.waitForExistence(timeout: 2) { scrollTo(menu, in: app) }
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        let item = app.buttons[choice].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.tap()
        XCTAssertTrue(waitFor(menu, "value == '\(choice)'"), "\(String(describing: menu.value))")
    }

    /// Back up "small" (no notes) to the folder, then relaunch into the reader and write a page
    /// note that only this iPad has. Returns the relaunched app, back in the Library.
    private func backUpThenAddALaterNote(_ text: String) -> XCUIApplication {
        let app = launch([Fixtures.small])
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 20))
        openBackupScreen(app)
        openDestination(app)
        backUpNow(app)
        closeSettings(app)
        let again = relaunchIntoReader(app)
        addNote(again, text)
        return again
    }

    private func openBackupScreen(_ app: XCUIApplication) {
        let gear = app.buttons[ID.settingsOpen].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        let row = app.buttons[ID.settingsRow].firstMatch
        XCTAssertTrue(app.buttons["settings.done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func openDestination(_ app: XCUIApplication) {
        // The ID holds the folder's path, longer than a plain identifier query allows.
        let row = app.buttons.matching(NSPredicate(format: "identifier == %@", ID.destination(folderID))).firstMatch
        scrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons[ID.backUpNow].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Back Up Now on the open destination screen; waits for the backup to be listed.
    private func backUpNow(_ app: XCUIApplication) {
        let button = app.buttons[ID.backUpNow].firstMatch
        XCTAssertTrue(waitFor(button, "isEnabled == true"), "destination available")
        button.tap()
        XCTAssertTrue(any(app, ID.destinationResult).waitForExistence(timeout: 30), app.debugDescription)
        scrollTo(snapshotRows(app).firstMatch, in: app)
        XCTAssertTrue(snapshotRows(app).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// With large text a list can be taller than the sheet, and rows off screen are not in the
    /// tree yet: swipe up until `element` is there and hittable (a few times at most).
    ///
    /// The drag is made inside the front list itself. A swipe on the app as a whole is not
    /// enough: when the app's window is smaller than the screen (windows keep their size between
    /// launches on the simulator) the sheet is short, the row starts off screen, and a swipe
    /// aimed at the screen's middle did not scroll the sheet.
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

    private func closeSettings(_ app: XCUIApplication) {
        app.buttons[ID.done].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.waitForNonExistence(timeout: 5))
    }

    private func deleteBook(_ app: XCUIApplication, _ title: String) {
        let cell = book(app, title)
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        // On the title under the cover (see LibraryUITests.openContextMenu).
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).press(forDuration: 1.0)
        let delete = app.buttons["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(cell.waitForNonExistence(timeout: 10))
    }

    /// Opens the newest backup at the destination for restore.
    private func openNewestBackup(_ app: XCUIApplication) {
        let row = snapshotRows(app).firstMatch
        scrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons[ID.confirm].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
    }

    private func restoreAndFinish(_ app: XCUIApplication) {
        let confirm = app.buttons[ID.confirm].firstMatch
        XCTAssertTrue(waitFor(confirm, "isEnabled == true"))
        confirm.tap()
        XCTAssertTrue(any(app, ID.summary).waitForExistence(timeout: 30), app.debugDescription)
    }

    // MARK: Tests

    /// The app has no iCloud or Google Drive destination of its own: the folder picked in Files
    /// is how they are reached, and its screen says so.
    func testTheFolderPickedInFilesIsTheOnlyDestinationOfTheAppsOwn() {
        let app = launch([])
        openBackupScreen(app)
        let folderRow = app.buttons["backup.destination.folder"].firstMatch
        scrollTo(folderRow, in: app)
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5), app.debugDescription)
        // The picked folder, and the folder this test passes with `-backupFolder`.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'backup.destination.'"))
        XCTAssertEqual(rows.count, 2, app.debugDescription)
        XCTAssertFalse(app.buttons["backup.destination.icloud"].exists)
        XCTAssertFalse(app.buttons["backup.destination.google-drive"].exists)

        folderRow.tap()
        XCTAssertTrue(app.buttons["backup.destinationScreen.chooseFolder"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitFor(any(app, "backup.destinationScreen.folder.footer"), "label CONTAINS 'iCloud Drive'"), app.debugDescription)
        XCTAssertFalse(app.buttons["Sign In…"].exists)
    }

    /// (a) Back up with PDFs, delete the book, restore it: the book and its note are back.
    func testBackUpDeleteAndRestoreWithPDFs() {
        let app = launch([Fixtures.small], extra: ["-openBook", "small", "-openPage", "1", "-notesPanel", "page"])
        addNote(app, "Kept by the backup")

        openBackupScreen(app)
        XCTAssertTrue(waitFor(any(app, ID.fileEstimate), "label BEGINSWITH 'Notes and ink only: '"), app.debugDescription)
        openDestination(app)
        backUpNow(app)
        closeSettings(app)

        deleteBook(app, "small")
        XCTAssertTrue(app.buttons[ID.emptyRestore].waitForExistence(timeout: 10), "empty Library offers Restore from Backup…")

        openBackupScreen(app)
        openDestination(app)
        openNewestBackup(app)
        let checkbox = any(app, ID.restoreBook("small"))
        XCTAssertEqual(checkbox.value as? String, "Selected", "a new book is ticked")
        XCTAssertTrue(checkbox.label.hasSuffix("New"), checkbox.label)
        restoreAndFinish(app)
        XCTAssertTrue(app.staticTexts["1 book restored"].exists, app.debugDescription)
        app.buttons[ID.restoreDone].firstMatch.tap()
        closeSettings(app)

        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 10), "restored into the Library")
        XCTAssertFalse(book(app, "small").label.contains("PDF missing"), "restored with its PDF")

        // The note is there, in a reader opened fresh.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-openBook", "small", "-openPage", "1", "-notesPanel", "page"]
        again.launch()
        XCTAssertTrue(again.buttons[ID.pagePill].firstMatch.waitForExistence(timeout: 30), "the book opens")
        let field = again.textViews[ID.noteText].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(field, "value CONTAINS 'Kept by the backup'"), "\(String(describing: field.value))")
    }

    /// (b) A backup without PDFs: the restored book shows "PDF missing" and offers Locate PDF….
    func testRestoreWithoutPDFsShowsTheMissingBadge() {
        let app = launch([Fixtures.small])
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 20))
        openBackupScreen(app)
        openDestination(app)
        let includePDFs = app.switches[ID.destinationIncludePDFs].firstMatch
        XCTAssertTrue(includePDFs.waitForExistence(timeout: 5))
        XCTAssertEqual(includePDFs.value as? String, "1", "Include PDFs is on by default")
        includePDFs.tap()
        if !waitFor(includePDFs, "value == '0'", timeout: 3) {
            // The row's label took the tap: tap the switch itself, at the trailing edge.
            includePDFs.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertTrue(waitFor(includePDFs, "value == '0'"), "Include PDFs off")
        backUpNow(app)
        closeSettings(app)
        deleteBook(app, "small")

        openBackupScreen(app)
        // The choice made on the destination's switch is the backup-file switch's too: there is
        // one Include PDFs choice for every backup.
        let fileIncludePDFs = app.switches[ID.fileIncludePDFs].firstMatch
        XCTAssertTrue(fileIncludePDFs.waitForExistence(timeout: 5))
        XCTAssertEqual(fileIncludePDFs.value as? String, "0", "the backup-file switch follows the destination's")
        openDestination(app)
        XCTAssertEqual(app.switches[ID.destinationIncludePDFs].firstMatch.value as? String, "0", "and it is remembered")
        openNewestBackup(app)
        XCTAssertFalse(app.switches["restore.restorePDFs"].exists, "nothing to restore PDFs from")
        XCTAssertTrue(any(app, "restore.book.small.pdf").label.contains("Locate PDF"), app.debugDescription)
        restoreAndFinish(app)
        XCTAssertTrue(app.staticTexts["1 book restored, 1 needs its PDF"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons[ID.locate("small")].exists, "the summary offers Locate PDF…")
        app.buttons[ID.restoreDone].firstMatch.tap()
        closeSettings(app)

        let cell = book(app, "small")
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(cell, "label CONTAINS 'PDF missing'"), cell.label)
        cell.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "opening a book without its PDF asks for it")
        XCTAssertTrue(alert.buttons["Locate PDF…"].exists)
        XCTAssertTrue(alert.buttons["Open Notebook"].exists)
        alert.buttons["Cancel"].tap()

        // The context menu offers it too.
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Locate PDF…"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Open Notebook"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Library"].firstMatch.waitForExistence(timeout: 10),
                      "the Notebook of a book without its PDF opens")
    }

    /// (c) Restoring over a book still in the Library: ticked and set to Merge by default, with
    /// what a merge adds; Replace with Backup shows the warning and Restore asks first, naming the
    /// book; Leave as Is unticks it.
    func testRestoringOverAnExistingBookDefaultsToMergeAndReplaceWarns() {
        let app = launch([Fixtures.small])
        XCTAssertTrue(book(app, "small").waitForExistence(timeout: 20))
        openBackupScreen(app)
        openDestination(app)
        backUpNow(app)
        openNewestBackup(app)

        let checkbox = any(app, ID.restoreBook("small"))
        XCTAssertEqual(checkbox.value as? String, "Selected", "an existing book is ticked")
        XCTAssertTrue(checkbox.label.contains("Already in Library"), checkbox.label)
        let menu = any(app, ID.action("small"))
        XCTAssertEqual(menu.value as? String, "Merge", "and set to Merge")
        XCTAssertTrue(waitFor(any(app, ID.mergeText("small")), "label CONTAINS 'already has everything'"), app.debugDescription)
        XCTAssertFalse(any(app, ID.replaceWarning("small")).exists, "no replace warning for a merge")
        XCTAssertTrue(any(app, ID.mergeFootnote).exists, "the footnote about deletions coming back")
        XCTAssertEqual(app.buttons[ID.confirm].label, "Merge 1 Book")

        // Replace with Backup: the warning, and a confirmation naming the book.
        choose("Replace with Backup", for: "small", in: app)
        XCTAssertTrue(any(app, ID.replaceWarning("small")).label.contains("replaces"), app.debugDescription)
        XCTAssertFalse(any(app, ID.mergeFootnote).exists, "no merge, no footnote")
        XCTAssertEqual(app.buttons[ID.confirm].label, "Restore 1 Book")
        app.buttons[ID.confirm].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.label.contains("small") || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'small'")).count > 0,
                      app.debugDescription)
        alert.buttons["Cancel"].tap()

        // Leave as Is is unticking; ticking again brings Replace back.
        choose("Leave as Is", for: "small", in: app)
        XCTAssertTrue(waitFor(checkbox, "value == 'Not selected'"))
        XCTAssertTrue(any(app, ID.leaveText("small")).exists, app.debugDescription)
        XCTAssertFalse(app.buttons[ID.confirm].isEnabled, "nothing to restore")
        checkbox.tap()
        XCTAssertTrue(waitFor(checkbox, "value == 'Selected'"))
        XCTAssertEqual(any(app, ID.action("small")).value as? String, "Replace with Backup")

        app.buttons[ID.restoreCancel].firstMatch.tap()
        XCTAssertTrue(app.buttons[ID.backUpNow].firstMatch.waitForExistence(timeout: 5))
    }

    /// (e) A merge keeps a note made on this iPad after the backup, and the summary says what it
    /// did (the backup holds nothing this iPad lacks, so: nothing new). It can be undone.
    func testMergeKeepsANoteMadeAfterTheBackup() {
        let app = backUpThenAddALaterNote("Written after the backup")

        openBackupScreen(app)
        openDestination(app)
        openNewestBackup(app)
        XCTAssertEqual(any(app, ID.action("small")).value as? String, "Merge")
        restoreAndFinish(app)
        XCTAssertTrue(app.staticTexts["1 book merged"].exists, app.debugDescription)
        let merged = any(app, ID.merged("small"))
        XCTAssertTrue(merged.exists, app.debugDescription)
        XCTAssertTrue(merged.label.contains("Nothing new") || merged.label.contains("Added"), merged.label)
        XCTAssertTrue(any(app, ID.undoHint).exists, "the summary says the restore can be undone")
        app.buttons[ID.restoreDone].firstMatch.tap()
        closeSettings(app)

        let again = relaunchIntoReader(app)
        XCTAssertTrue(waitFor(again.textViews[ID.noteText].firstMatch, "value CONTAINS 'Written after the backup'"),
                      noteValue(again))
    }

    /// (f) Replace with Backup removes a note made after the backup; Undo Last Restore brings it
    /// back, and its row goes away.
    func testReplaceRemovesALaterNoteAndUndoBringsItBack() {
        let app = backUpThenAddALaterNote("Lost by the replace")

        openBackupScreen(app)
        XCTAssertFalse(any(app, ID.undoRestore).exists, "nothing to undo yet")
        openDestination(app)
        openNewestBackup(app)
        choose("Replace with Backup", for: "small", in: app)
        app.buttons[ID.confirm].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Restore 1 Book"].tap()
        XCTAssertTrue(any(app, ID.summary).waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1 book restored"].exists, app.debugDescription)
        app.buttons[ID.restoreDone].firstMatch.tap()
        closeSettings(app)

        var reader = relaunchIntoReader(app)
        XCTAssertFalse(noteValue(reader).contains("Lost by the replace"), noteValue(reader))
        reader.navigationBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(book(reader, "small").waitForExistence(timeout: 10))

        // Undo Last Restore: the row says when and how many, asks first, then goes away.
        openBackupScreen(reader)
        let undo = any(reader, ID.undoRestore)
        scrollTo(undo, in: reader)
        XCTAssertTrue(undo.waitForExistence(timeout: 5), reader.debugDescription)
        XCTAssertTrue((undo.value as? String ?? "").contains("changed 1 book"), "\(String(describing: undo.value))")
        undo.tap()
        let confirm = reader.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS '“small”' AND label CONTAINS 'will be lost'")).count > 0,
                      reader.debugDescription)
        confirm.buttons["Undo Restore"].tap()
        let result = any(reader, ID.undoResult)
        XCTAssertTrue(result.waitForExistence(timeout: 30), reader.debugDescription)
        XCTAssertEqual(result.label, "Restore undone: 1 book put back as it was.")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5), "nothing left to undo")
        closeSettings(reader)

        reader = relaunchIntoReader(reader)
        XCTAssertTrue(waitFor(reader.textViews[ID.noteText].firstMatch, "value CONTAINS 'Lost by the replace'"), noteValue(reader))
    }

    /// (d) One job at a time, with progress in place and in the Library, and Cancel. Uses a
    /// generated 3 GB PDF so the backup lasts long enough to be seen; if it still finishes
    /// before it can be observed, the test is skipped rather than failed.
    func testProgressRowAndOneJobAtATime() throws {
        let huge = scratch.appendingPathComponent("huge.pdf")
        try Self.writePaddedPDF(to: huge, paddingBytes: 3 * 1024 * 1024 * 1024)
        let app = launch([huge.path])
        XCTAssertTrue(book(app, "huge").waitForExistence(timeout: 90), app.debugDescription)
        openBackupScreen(app)
        openDestination(app)
        let backUp = app.buttons[ID.backUpNow].firstMatch
        XCTAssertTrue(waitFor(backUp, "isEnabled == true"))
        backUp.tap()

        // While it runs it shows in place, and nothing else can start.
        guard any(app, ID.progress).exists || any(app, ID.progress).waitForExistence(timeout: 2) else {
            throw XCTSkip("the backup finished before its progress could be observed")
        }
        XCTAssertFalse(backUp.isEnabled, "Back Up Now waits for the running job")
        app.buttons[ID.done].firstMatch.tap()

        // Every Library window shows the job with Cancel.
        let row = any(app, ID.libraryProgress)
        guard row.waitForExistence(timeout: 3) else {
            throw XCTSkip("the backup finished before the Library could show it")
        }
        let cancel = row.buttons[ID.progressCancel].firstMatch
        XCTAssertTrue(cancel.exists, app.debugDescription)
        if cancel.isEnabled { cancel.tap() }
        XCTAssertTrue(row.waitForNonExistence(timeout: 60), "the row goes when the job ends")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "a cancellation is quiet")
        // Another job can start again.
        openBackupScreen(app)
        XCTAssertTrue(app.buttons[ID.saveFile].firstMatch.isEnabled)
    }

    /// Screenshots of the Backup screen, a destination, the restore preview (with the Merge /
    /// Replace with Backup / Leave as Is menu open, and set to Replace), the summary of a merge and
    /// the Backup screen with Undo Last Restore, landscape and portrait, to
    /// `build/shots/backup-<name><suffix>.png` (`TEST_RUNNER_BACKUP_SHOT_SUFFIX`, e.g. `-dark` after
    /// `xcrun simctl ui <device> appearance dark`).
    func testScreenshots() throws {
        let app = launch([Fixtures.small, Fixtures.noOutline], extra: ["-openBook", "small", "-openPage", "1", "-notesPanel", "page"])
        addNote(app, "A note to restore")
        openBackupScreen(app)
        sleep(1)
        try save("screen", app)
        openDestination(app)
        backUpNow(app)
        try save("destination", app)
        closeSettings(app)
        deleteBook(app, "no-outline")

        openBackupScreen(app)
        openDestination(app)
        openNewestBackup(app)
        XCTAssertTrue(waitFor(any(app, ID.mergeText("small")), "label CONTAINS 'already has everything'"), app.debugDescription)
        sleep(1)
        try save("restore-preview", app)
        let menu = any(app, ID.action("small"))
        menu.tap()
        XCTAssertTrue(app.buttons["Leave as Is"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)
        try save("restore-preview-menu", app)
        app.buttons["Replace with Backup"].firstMatch.tap()
        XCTAssertTrue(any(app, ID.replaceWarning("small")).waitForExistence(timeout: 5))
        sleep(1)
        try save("restore-preview-replace", app)
        choose("Merge", for: "small", in: app)

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        try save("restore-preview-portrait", app)
        restoreAndFinish(app)
        sleep(1)
        try save("restore-summary-portrait", app)
        app.buttons[ID.restoreDone].firstMatch.tap()
        closeSettings(app)
        openBackupScreen(app)
        let undo = any(app, ID.undoRestore)
        // The footnote under the Restore section, so the whole Undo row is on screen.
        let footnote = any(app, "backup.footnote")
        scrollTo(undo, in: app)
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(footnote, in: app)
        sleep(1)
        try save("screen-undo-portrait", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        scrollTo(footnote, in: app)
        try save("screen-undo", app)
    }

    // MARK: Support

    private var suffix: String { ProcessInfo.processInfo.environment["BACKUP_SHOT_SUFFIX"] ?? "" }

    private func save(_ name: String, _ app: XCUIApplication) throws {
        let directory = Fixtures.repoRoot.appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = XCUIScreen.main.screenshot().image
        let upright = UIGraphicsImageRenderer(size: image.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            return format
        }()).image { _ in image.draw(at: .zero) }
        try upright.pngData()?.write(to: directory.appendingPathComponent("backup-\(name)\(suffix).png"))
    }

    /// A one-page PDF carrying `paddingBytes` of zeros in an unreferenced stream, with a correct
    /// cross-reference table, so it opens normally but is as large as wanted.
    static func writePaddedPDF(to url: URL, paddingBytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset = 0
        var offsets: [Int] = []
        func write(_ string: String) throws {
            let data = Data(string.utf8)
            try handle.write(contentsOf: data)
            offset += data.count
        }
        try write("%PDF-1.4\n")
        let content = "0.5 w 72 72 m 540 720 l S\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        ]
        for (index, body) in objects.enumerated() {
            offsets.append(offset)
            try write("\(index + 1) 0 obj\n\(body)\nendobj\n")
        }
        offsets.append(offset)
        try write("5 0 obj\n<< /Length \(paddingBytes) >>\nstream\n")
        let chunk = Data(count: 8 * 1024 * 1024)
        var remaining = paddingBytes
        while remaining > 0 {
            let part = min(remaining, chunk.count)
            try handle.write(contentsOf: part == chunk.count ? chunk : chunk.prefix(part))
            offset += part
            remaining -= part
        }
        try write("\nendstream\nendobj\n")
        let xref = offset
        var table = "xref\n0 6\n0000000000 65535 f \n"
        for value in offsets { table += String(format: "%010d 00000 n \n", value) }
        try write(table)
        try write("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
    }
}
