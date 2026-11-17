import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import TactileTexts

/// The Backup screens' plain decisions (`BackupUILogic.swift`, `BackupJobText`).
struct BackupUILogicTests {
    // MARK: Fixtures

    private static let sha = String(repeating: "a", count: 64)
    private static let otherSHA = String(repeating: "b", count: 64)
    private let fixedDate: (Date) -> String = { _ in "DATE" }

    private func book(_ title: String, id: UUID = UUID(), fingerprint: String? = nil) -> Book {
        Book(id: id, title: title, fingerprint: fingerprint ?? "fp-\(title)", fileName: "\(title).pdf", pageCount: 10,
             fileSize: 1000)
    }

    private func entry(_ book: Book, embedded: Bool = false, sha256: String = sha,
                       counts: BackupManifest.RecordCounts = .init(notes: 2, highlights: 1, inkedPages: 3)) -> BackupManifest.BookEntry {
        BackupManifest.BookEntry(book: book, pdf: .init(sha256: sha256, size: 1000, embedded: embedded), counts: counts,
                                 lastModifiedAt: Date(timeIntervalSince1970: 100), files: [])
    }

    private func manifest(_ entries: [BackupManifest.BookEntry], includesPDFs: Bool = false) -> BackupManifest {
        BackupManifest(createdAt: Date(timeIntervalSince1970: 1000), appVersion: "1", appBuild: "1", deviceName: "Test iPad",
                       includesPDFs: includesPDFs, books: entries)
    }

    private func local(_ book: Book, hasPDF: Bool = true, sha256: String? = sha) -> LocalBookSummary {
        LocalBookSummary(book: book, hasPDF: hasPDF, sha256: sha256, counts: .init(notes: 5, bookmarks: 1),
                         lastModifiedAt: Date(timeIntervalSince1970: 200))
    }

    // MARK: Text

    @Test func estimateLineShowsBothSizes() {
        let line = BackupUIText.estimateLine(BackupSizeEstimate(notesAndInk: 14_000_000, withPDFs: 3_200_000_000))
        #expect(line.hasPrefix("Notes and ink only: "))
        #expect(line.contains(" · With PDFs: "))
        #expect(line.contains(BackupUIText.bytes(14_000_000)))
        #expect(line.contains(BackupUIText.bytes(3_200_000_000)))
    }

    @Test func skippedLineNamesTheBooks() {
        #expect(BackupUIText.skippedLine([]) == nil)
        #expect(BackupUIText.skippedLine(["A"])?.hasPrefix("“A” was left out") == true)
        let two = BackupUIText.skippedLine(["A", "B"]) ?? ""
        #expect(two.contains("“A”") && two.contains("“B”") && two.contains("were left out"))
    }

    @Test func destinationStatusLine() {
        #expect(BackupUIText.destinationStatus(availability: nil, lastSuccess: nil) == "Checking…")
        #expect(BackupUIText.destinationStatus(availability: .unavailable(reason: "Gone."), lastSuccess: Date()) == "Gone.")
        #expect(BackupUIText.destinationStatus(availability: .available, lastSuccess: nil) == "No backups yet")
        #expect(BackupUIText.destinationStatus(availability: .available, lastSuccess: Date(), dateText: fixedDate)
                == "Last backup: DATE")
    }

    @Test func destinationResultLine() {
        let snapshot = BackupSnapshotInfo(id: "x", name: "x", createdAt: Date(), deviceName: "iPad", byteSize: 10)
        var result = DestinationBackupResult(snapshot: snapshot, bookCount: 3, uploadedPDFs: 0, alreadyPresentPDFs: 2,
                                             deletedSnapshots: 0, skippedBookTitles: [])
        #expect(BackupUIText.destinationBackupDone(result, destinationName: "Folder") == "Backed up 3 books to Folder.")
        result.uploadedPDFs = 1
        #expect(BackupUIText.destinationBackupDone(result, destinationName: "Folder") == "Backed up 3 books to Folder. 1 PDF uploaded.")
        #expect(BackupUIText.snapshotDetail(snapshot).hasPrefix("iPad · "))
    }

    // MARK: Errors

    @Test func cancellationIsQuietAndOtherErrorsShowTheirOwnMessage() {
        #expect(BackupFailure.from(CancellationError(), title: "T") == nil)
        #expect(BackupFailure.from(ImportError.cancelled, title: "T") == nil)
        let busy = BackupFailure.from(BackupServiceError.busy, title: "T")
        #expect(busy?.message == BackupServiceError.busy.localizedDescription)
        let offline = BackupFailure.from(CloudBackupError.noNetwork(destination: "R2"), title: "T")
        #expect(offline?.title == "T")
        #expect(offline?.message == CloudBackupError.noNetwork(destination: "R2").localizedDescription)
        let mismatch = BackupFailure.from(ImportError.pdfMismatch(bookTitle: "B"), title: "T")
        #expect(mismatch?.message == ImportError.pdfMismatch(bookTitle: "B").localizedDescription)
    }

    // MARK: Destinations

    @Test func destinationKindsDecideTheirControls() {
        #expect(BackupDestinationKind(id: "folder") == .pickedFolder)
        #expect(BackupDestinationKind(id: "s3") == .s3)
        #expect(BackupDestinationKind(id: "folder:/tmp/x") == .other)
        // The IDs of the destinations the app once had of its own (an old setting may hold one).
        #expect(BackupDestinationKind(id: "icloud") == .other)
        #expect(BackupDestinationKind(id: "google-drive") == .other)
        #expect(BackupDestinationKind.pickedFolder.showsFolderControls)
        #expect(!BackupDestinationKind.other.showsFolderControls)
        #expect(!BackupDestinationKind.s3.showsFolderControls)
    }

    // MARK: Automatic backup

    @Test func automaticChoicesAreTheAvailableDestinations() {
        let entries = [AutomaticBackupLogic.Choice(id: "a", name: "A"), .init(id: "b", name: "B"), .init(id: "c", name: "C")]
        let choices = AutomaticBackupLogic.choices(entries, availability: ["a": .unavailable(reason: "no"), "b": .available, "c": .available])
        #expect(choices.map(\.id) == ["b", "c"])
        #expect(AutomaticBackupLogic.destination(current: "c", choices: choices) == "c")
        #expect(AutomaticBackupLogic.destination(current: "a", choices: choices) == "b")
        #expect(AutomaticBackupLogic.destination(current: nil, choices: []) == nil)
    }

    @Test func automaticStatusLine() {
        func line(enabled: Bool = true, name: String? = "Folder", availability: BackupDestinationAvailability? = .available,
                  success: Date? = nil, failure: String? = nil) -> String? {
            AutomaticBackupLogic.statusLine(isEnabled: enabled, destinationName: name, availability: availability,
                                            lastSuccess: success, lastFailureMessage: failure, dateText: fixedDate)
        }
        #expect(line(enabled: false) == nil, "the switch says it is off")
        #expect(line(name: nil) == "Choose where automatic backups go.")
        #expect(line(availability: .unavailable(reason: "Gone.")) == "Automatic backups to Folder are waiting: Gone.")
        #expect(line(success: Date(), failure: "Disk full.") == "The last automatic backup didn’t finish: Disk full.")
        #expect(line(success: Date()) == "Last successful backup: DATE.")
        #expect(line() == "No backup to Folder yet.")
    }

    // MARK: Restore preview

    @Test func everyBookIsTickedAndExistingOnesAreMerged() {
        let existing = book("Existing")
        let fresh = book("Fresh")
        let plan = RestorePlan(manifest: manifest([entry(existing), entry(fresh)]), localLibrary: [local(existing)],
                               destinationPDFHashes: [])
        let choices = RestoreChoices(plan: plan)
        #expect(choices.selection == [existing.id, fresh.id])
        #expect(choices.choice(for: plan.items[0]) == .merge)
        #expect(choices.choice(for: plan.items[1]) == nil, "a new book has no menu")
        #expect(choices.actions(in: plan) == [existing.id: .merge, fresh.id: .restore])
        #expect(RestorePreviewLogic.statusText(plan.items[0].status) == "Already in Library")
        #expect(RestorePreviewLogic.statusText(plan.items[1].status) == "New")
    }

    @Test func pdfSourceText() {
        let a = book("A"), b = book("B"), c = book("C"), d = book("D")
        let entries = [entry(a, embedded: true), entry(b, sha256: Self.otherSHA), entry(c), entry(d, sha256: String(repeating: "c", count: 64))]
        let localCopy = book("Local copy")
        let plan = RestorePlan(manifest: manifest(entries), localLibrary: [local(localCopy)],
                               destinationPDFHashes: [Self.otherSHA])
        let texts = plan.items.map { RestorePreviewLogic.pdfText($0, restorePDFs: true) }
        #expect(texts == ["PDF: included in the backup", "PDF: stored with the backups", "PDF: already on this iPad",
                          "PDF: not included. Link it later with Locate PDF…"])
        // Restore PDFs off: what the backup holds is not used.
        #expect(RestorePreviewLogic.pdfText(plan.items[0], restorePDFs: false).hasPrefix("PDF: not included"))
        #expect(RestorePreviewLogic.offersRestorePDFs(plan))
        let none = RestorePlan(manifest: manifest([entry(d)]), localLibrary: [], destinationPDFHashes: [])
        #expect(!RestorePreviewLogic.offersRestorePDFs(none))
    }

    @Test func countsAndSides() {
        let counts = BackupManifest.RecordCounts(notes: 1, highlights: 2, bookmarks: 0, userHeadings: 0, inkedPages: 1)
        #expect(RestorePreviewLogic.countsText(counts) == "1 note, 2 highlights, 0 bookmarks, 1 page of ink")
        let withHeadings = BackupManifest.RecordCounts(notes: 0, highlights: 0, bookmarks: 1, userHeadings: 2, inkedPages: 4)
        #expect(RestorePreviewLogic.countsText(withHeadings) == "0 notes, 0 highlights, 1 bookmark, 2 headings, 4 pages of ink")
        #expect(RestorePreviewLogic.sideText("On this iPad", counts: counts, modified: Date(), dateText: fixedDate)
                == "On this iPad: 1 note, 2 highlights, 0 bookmarks, 1 page of ink. Changed DATE.")
        #expect(RestorePreviewLogic.replaceWarning.contains("replaces"))
    }

    @Test func restoreButtonAndConfirmation() {
        #expect(RestorePreviewLogic.restoreButtonTitle(count: 0) == "Restore")
        #expect(RestorePreviewLogic.restoreButtonTitle(count: 1) == "Restore 1 Book")
        #expect(RestorePreviewLogic.restoreButtonTitle(count: 3) == "Restore 3 Books")

        let existing = book("Existing"), other = book("Other"), fresh = book("Fresh")
        let plan = RestorePlan(manifest: manifest([entry(existing), entry(other), entry(fresh)]),
                               localLibrary: [local(existing), local(other)], destinationPDFHashes: [])
        let items = plan.items
        // Merges and new books need no confirmation.
        #expect(RestorePreviewLogic.confirmation(selected: [(items[2], .restore)]) == nil)
        #expect(RestorePreviewLogic.confirmation(selected: [(items[0], .merge), (items[2], .restore)]) == nil)
        let one = RestorePreviewLogic.confirmation(selected: [(items[0], .replace), (items[1], .merge), (items[2], .restore)])
        #expect(one?.title == "Replace “Existing”?")
        #expect(one?.message == "Restoring replaces the notes, highlights, bookmarks and ink of “Existing” on this iPad with the backup’s. What is there now is lost, unless you undo this restore from the Backup screen.")
        #expect(one?.message.contains("Other") == false && one?.message.contains("Fresh") == false)
        #expect(one?.confirmTitle == "Restore 3 Books")
        let two = RestorePreviewLogic.confirmation(selected: [(items[0], .replace), (items[1], .replace)])
        #expect(two?.title == "Replace 2 Books?")
        #expect(two?.message.contains("“Existing”") == true && two?.message.contains("“Other”") == true)
        #expect(two?.confirmTitle == "Restore 2 Books")
    }

    @Test func summaryHeadline() {
        var summary = RestoreSummary()
        #expect(RestorePreviewLogic.summaryHeadline(summary) == "Nothing was restored")
        summary.failures = [.init(id: UUID(), title: "X", message: "m")]
        #expect(RestorePreviewLogic.summaryHeadline(summary) == "No books could be restored")
        summary.failures = []
        summary.restored = [.init(id: UUID(), title: "A", hasPDF: true), .init(id: UUID(), title: "B", hasPDF: false),
                            .init(id: UUID(), title: "C", hasPDF: true)]
        #expect(RestorePreviewLogic.summaryHeadline(summary) == "3 books restored, 1 needs its PDF")
        summary.restored[0].hasPDF = false
        summary.failures = [.init(id: UUID(), title: "X", message: "m")]
        #expect(RestorePreviewLogic.summaryHeadline(summary) == "3 books restored, 2 need their PDFs, 1 book not restored")
        // Merged books are counted on their own.
        summary.failures = []
        summary.restored = summary.restored.map { var book = $0; book.hasPDF = true; return book }
        summary.merged = [Self.merged(id: summary.restored[0].id, title: "A")]
        #expect(RestorePreviewLogic.summaryHeadline(summary) == "1 book merged, 2 books restored")
        summary.merged = summary.restored.map { Self.merged(id: $0.id, title: $0.title) }
        #expect(RestorePreviewLogic.summaryHeadline(summary) == "3 books merged")
        summary.merged = [Self.merged(id: summary.restored[1].id, title: "B")]
        #expect(RestorePreviewLogic.plainlyRestored(summary, linked: []).map(\.title) == ["A", "C"])
        #expect(RestorePreviewLogic.droppedNotesLine(0) == nil)
        #expect(RestorePreviewLogic.droppedNotesLine(2) == "2 notes were left out because they were empty.")
        #expect(RestorePreviewLogic.headerLine(createdAt: Date(), deviceName: "iPad", dateText: fixedDate) == "Made DATE on iPad")
    }

    @Test func missingPDFLabel() {
        #expect(MissingPDFText.cellAccessibilityLabel("small, 12 pages", isMissing: false) == "small, 12 pages")
        #expect(MissingPDFText.cellAccessibilityLabel("small, 12 pages", isMissing: true) == "small, 12 pages, PDF missing")
    }

    // MARK: Job text

    @MainActor @Test func cancelStopsBeingOfferedOnceBooksAreSwappedIn() {
        #expect(BackupJobText.canCancel(kind: .restore, phase: .extracting))
        #expect(BackupJobText.canCancel(kind: .restore, phase: .savingOpenBooks))
        #expect(!BackupJobText.canCancel(kind: .restore, phase: .committing))
        #expect(!BackupJobText.canCancel(kind: .restore, phase: .cleaningUp))
        #expect(BackupJobText.canCancel(kind: .backUpToFile, phase: .writingBackup))
        #expect(!BackupJobText.canCancel(kind: .backUpToDestination("F"), phase: .removingOldBackups))
        #expect(BackupJobText.status(kind: .restore, phase: .committing, fraction: 0.96).hasSuffix("can’t be cancelled now."))
        #expect(BackupJobText.status(kind: .backUpToFile, phase: .writingBackup, fraction: 0.425) == "Writing backup… 43%")
        #expect(BackupJobText.title(.backUpToDestination("My Backups")) == "Backing Up to My Backups")
    }

    @MainActor @Test func undoAndMergePhasesReadAsWhatTheyDo() {
        #expect(BackupJobText.title(.undoRestore) == "Undoing Restore")
        #expect(BackupJobText.status(kind: .restore, phase: .merging, fraction: 0.5) == "Merging books… 50%")
        #expect(BackupJobText.canCancel(kind: .restore, phase: .merging))
        #expect(BackupJobText.status(kind: .restore, phase: .savingSafetyCopy, fraction: 0.2) == "Saving a safety copy… 20%")
        #expect(BackupJobText.status(kind: .undoRestore, phase: .reading, fraction: 0) == "Reading the safety copy… 0%")
        #expect(BackupJobText.status(kind: .restore, phase: .reading, fraction: 0) == "Reading backup… 0%")
        #expect(BackupJobText.status(kind: .undoRestore, phase: .committing, fraction: 0.9)
                == "Putting books back… 90%. This can’t be cancelled now.")
    }

    static func merged(id: UUID, title: String) -> RestoreSummary.MergedBook {
        RestoreSummary.MergedBook(id: id, backupBookID: id, title: title, report: BookMergeReport(), ink: MergeInkCounts(),
                                  combinedInkAlreadyPresent: 0, unreadableInk: [], tookPDFFromBackup: false)
    }
}
