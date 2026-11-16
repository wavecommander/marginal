import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import TactileTexts

/// The restore preview's per-book choices, the merge sentences, the summary of a merge and Undo
/// Last Restore (`RestoreChoices`, `RestorePreviewLogic.row`, `MergeText`, `UndoRestoreLogic`).
struct BackupUIMergeLogicTests {
    // MARK: Fixtures

    private static let sha = String(repeating: "a", count: 64)
    private let fixedDate: (Date) -> String = { _ in "DATE" }

    private func book(_ title: String, id: UUID = UUID()) -> Book {
        Book(id: id, title: title, fingerprint: "fp-\(title)", fileName: "\(title).pdf", pageCount: 10, fileSize: 1000)
    }

    private func entry(_ book: Book, embedded: Bool = false) -> BackupManifest.BookEntry {
        BackupManifest.BookEntry(book: book, pdf: .init(sha256: Self.sha, size: 1000, embedded: embedded),
                                 counts: .init(notes: 2, highlights: 1, inkedPages: 3),
                                 lastModifiedAt: Date(timeIntervalSince1970: 100), files: [])
    }

    private func local(_ book: Book, hasPDF: Bool = true) -> LocalBookSummary {
        LocalBookSummary(book: book, hasPDF: hasPDF, sha256: Self.sha, counts: .init(notes: 5, bookmarks: 1),
                         lastModifiedAt: Date(timeIntervalSince1970: 200))
    }

    private func plan(_ entries: [BackupManifest.BookEntry], library: [LocalBookSummary]) -> RestorePlan {
        let manifest = BackupManifest(createdAt: Date(timeIntervalSince1970: 1000), appVersion: "1", appBuild: "1",
                                      deviceName: "iPad", includesPDFs: false, books: entries)
        return RestorePlan(manifest: manifest, localLibrary: library, destinationPDFHashes: [])
    }

    private func report(notesAdded: Int = 0, notesCombined: Int = 0, highlightsAdded: Int = 0, bookmarksAdded: Int = 0,
                        headingsAdded: Int = 0) -> BookMergeReport {
        var report = BookMergeReport()
        report.notesAdded = notesAdded
        report.notesCombined = notesCombined
        report.highlightsAdded = highlightsAdded
        report.bookmarksAdded = bookmarksAdded
        report.headingsAdded = headingsAdded
        return report
    }

    private func preview(_ report: BookMergeReport, ink: MergeInkCounts = MergeInkCounts()) -> BookMergePreview {
        BookMergePreview(id: UUID(), localBookID: UUID(), report: report, ink: ink)
    }

    private func merged(_ report: BookMergeReport, ink: MergeInkCounts = MergeInkCounts(), alreadyPresent: Int = 0,
                        unreadable: [UnreadableInk] = [], tookPDF: Bool = false) -> RestoreSummary.MergedBook {
        RestoreSummary.MergedBook(id: UUID(), backupBookID: UUID(), title: "small", report: report, ink: ink,
                                  combinedInkAlreadyPresent: alreadyPresent, unreadableInk: unreadable,
                                  tookPDFFromBackup: tookPDF)
    }

    // MARK: Choices

    @Test func tickAndMenuStayConsistent() {
        let existing = book("Existing"), fresh = book("Fresh")
        let plan = plan([entry(existing), entry(fresh)], library: [local(existing)])
        let item = plan.items[0]
        var choices = RestoreChoices(plan: plan)
        #expect(choices.choice(for: item) == .merge)

        // Replace, then untick: the menu says Leave as Is; ticking again brings Replace back.
        choices.choose(.replace, for: item.id)
        #expect(choices.choice(for: item) == .replace)
        #expect(choices.action(for: item) == .replace)
        choices.toggle(item.id)
        #expect(choices.choice(for: item) == .leave)
        #expect(!choices.isSelected(item.id))
        #expect(choices.action(for: item) == nil)
        #expect(choices.actions(in: plan) == [fresh.id: .restore], "a book left as it is is not passed")
        choices.toggle(item.id)
        #expect(choices.choice(for: item) == .replace)

        // Leave as Is unticks; Merge ticks.
        choices.choose(.leave, for: item.id)
        #expect(!choices.isSelected(item.id))
        choices.choose(.merge, for: item.id)
        #expect(choices.isSelected(item.id) && choices.choice(for: item) == .merge)
        #expect(choices.anyMerge(in: plan))
        choices.choose(.leave, for: item.id)
        #expect(!choices.anyMerge(in: plan))

        // A new book has no menu; choosing for it does nothing.
        choices.choose(.leave, for: fresh.id)
        #expect(choices.isSelected(fresh.id))
        choices.toggle(fresh.id)
        #expect(choices.actions(in: plan).isEmpty)
        #expect(choices.selectedItems(in: plan).isEmpty)
    }

    @Test func choicesFollowTheLibraryWhenThePlanIsRebuilt() {
        let a = book("A"), b = book("B")
        let before = plan([entry(a), entry(b)], library: [local(a)])
        var choices = RestoreChoices(plan: before)
        choices.choose(.replace, for: a.id)
        // B is imported in another window and A is deleted.
        let after = plan([entry(a), entry(b)], library: [local(b)])
        choices.reconcile(with: after)
        #expect(choices.choice(for: after.items[0]) == nil, "A is new now")
        #expect(choices.action(for: after.items[0]) == .restore)
        #expect(choices.choice(for: after.items[1]) == .merge, "B starts at Merge")
        // A comes back: its Replace was forgotten, so it is merged.
        choices.reconcile(with: before)
        #expect(choices.choice(for: before.items[0]) == .merge)
    }

    // MARK: Rows

    @Test func rowsShowTheMenuOnlyForBooksInTheLibrary() {
        let existing = book("Existing"), fresh = book("Fresh")
        let plan = plan([entry(existing, embedded: true), entry(fresh)], library: [local(existing)])
        var choices = RestoreChoices(plan: plan)

        let newRow = RestorePreviewLogic.row(plan.items[1], choices: choices, restorePDFs: true, preview: nil,
                                             previewsLoaded: false, dateText: fixedDate)
        #expect(!newRow.showsMenu)
        #expect(newRow.sideLines.isEmpty)
        #expect(newRow.note == .counts("2 notes, 1 highlight, 0 bookmarks, 3 pages of ink"))

        // Merge: loading, then the sentence; this iPad's PDF is kept even though the backup has one.
        var row = RestorePreviewLogic.row(plan.items[0], choices: choices, restorePDFs: true, preview: nil,
                                          previewsLoaded: false, dateText: fixedDate)
        #expect(row.menuChoice == .merge)
        #expect(row.note == .merge("Working out what a merge adds…", isLoading: true))
        #expect(row.pdfLine == "PDF: already on this iPad")
        #expect(row.sideLines == ["In this backup: 2 notes, 1 highlight, 0 bookmarks, 3 pages of ink. Changed DATE.",
                                  "On this iPad: 5 notes, 0 highlights, 1 bookmark, 0 pages of ink. Changed DATE."])
        row = RestorePreviewLogic.row(plan.items[0], choices: choices, restorePDFs: true,
                                      preview: preview(report(notesAdded: 1)), previewsLoaded: true, dateText: fixedDate)
        #expect(row.note == .merge("Adds 1 note. Nothing on this iPad is removed.", isLoading: false))
        row = RestorePreviewLogic.row(plan.items[0], choices: choices, restorePDFs: true, preview: nil,
                                      previewsLoaded: true, dateText: fixedDate)
        #expect(row.note == .merge(RestorePreviewLogic.mergeFallbackText, isLoading: false))

        // Replace: the warning, and the backup's PDF.
        choices.choose(.replace, for: existing.id)
        row = RestorePreviewLogic.row(plan.items[0], choices: choices, restorePDFs: true, preview: nil,
                                      previewsLoaded: true, dateText: fixedDate)
        #expect(row.menuChoice == .replace)
        #expect(row.note == .replaceWarning(RestorePreviewLogic.replaceWarning))
        #expect(row.pdfLine == "PDF: included in the backup")

        // Leave as Is: no PDF line.
        choices.choose(.leave, for: existing.id)
        row = RestorePreviewLogic.row(plan.items[0], choices: choices, restorePDFs: true, preview: nil,
                                      previewsLoaded: true, dateText: fixedDate)
        #expect(row.menuChoice == .leave)
        #expect(row.note == .leave("Left as it is: nothing from this backup is added to this book."))
        #expect(row.pdfLine == nil)
    }

    @Test func aMergeTakesTheBackupsPDFOnlyWhenThisIPadHasNone() {
        let existing = book("Existing")
        let plan = plan([entry(existing, embedded: true)], library: [local(existing, hasPDF: false)])
        let item = plan.items[0]
        #expect(RestorePreviewLogic.pdfText(item, action: .merge, restorePDFs: true) == "PDF: included in the backup")
        #expect(RestorePreviewLogic.pdfText(item, action: .merge, restorePDFs: false) == "PDF: not included. Link it later with Locate PDF…")
        #expect(RestorePreviewLogic.pdfText(item, action: nil, restorePDFs: true) == nil)
    }

    @Test func menuChoicesAndAccessibility() {
        #expect(RestoreRowChoice.allCases.map(\.title) == ["Merge", "Replace with Backup", "Leave as Is"])
        #expect(RestoreRowChoice.allCases.map(\.action) == [.merge, .replace, nil])
        #expect(RestorePreviewLogic.menuAccessibilityLabel(title: "small") == "What to do with “small”")
        #expect(RestorePreviewLogic.tickValue(isSelected: true) == "Selected")
        #expect(RestorePreviewLogic.tickValue(isSelected: false) == "Not selected")
        #expect(RestorePreviewLogic.tickHint(isSelected: false, isExisting: true) == "Double-tap to merge this book.")
        #expect(RestorePreviewLogic.tickHint(isSelected: false, isExisting: false) == "Double-tap to restore this book.")
        #expect(RestorePreviewLogic.tickHint(isSelected: true, isExisting: true) == "Double-tap to leave this book out.")
    }

    @Test func buttonTitleFollowsTheChoices() {
        #expect(RestorePreviewLogic.restoreButtonTitle(actions: []) == "Restore")
        #expect(RestorePreviewLogic.restoreButtonTitle(actions: [.merge]) == "Merge 1 Book")
        #expect(RestorePreviewLogic.restoreButtonTitle(actions: [.merge, .merge]) == "Merge 2 Books")
        #expect(RestorePreviewLogic.restoreButtonTitle(actions: [.replace]) == "Restore 1 Book")
        #expect(RestorePreviewLogic.restoreButtonTitle(actions: [.merge, .restore, .replace]) == "Restore 3 Books")
    }

    @Test func footerAndFootnote() {
        #expect(RestorePreviewLogic.booksFooter(hasExistingBooks: false) == "Every book is ticked. Untick a book to leave it out.")
        #expect(RestorePreviewLogic.booksFooter(hasExistingBooks: true).contains("is merged"))
        #expect(RestorePreviewLogic.mergeFootnote.hasPrefix("In a merge, anything deleted on this iPad after this backup was made comes back"))
        let existing = book("Existing")
        let item = plan([entry(existing)], library: [local(existing)]).items[0]
        #expect(RestorePreviewLogic.restoringActionText(item, action: .merge) == "Merge")
        #expect(RestorePreviewLogic.restoringActionText(item, action: .replace) == "Replace with Backup")
    }

    // MARK: Merge sentences

    @Test func previewSentenceWithSeveralOfEach() {
        let text = MergeText.previewText(preview(report(notesAdded: 3, notesCombined: 2, highlightsAdded: 12, bookmarksAdded: 2),
                                                 ink: MergeInkCounts(pagesCombined: 4)))
        #expect(text == "Adds 3 notes, 12 highlights and 2 bookmarks. Combines 2 notes and the ink on 4 pages. Nothing on this iPad is removed.")
        let all = MergeText.previewText(preview(report(notesAdded: 2, notesCombined: 3, highlightsAdded: 4, bookmarksAdded: 5,
                                                       headingsAdded: 6),
                                                ink: MergeInkCounts(pagesAdded: 7, pagesCombined: 8, notesAdded: 9, notesCombined: 10)))
        #expect(all == "Adds 2 notes, 4 highlights, 5 bookmarks, 6 headings, ink on 7 pages and handwriting in 9 notes. Combines 3 notes, the ink on 8 pages and the handwriting in 10 notes. Nothing on this iPad is removed.")
    }

    @Test func previewSentenceWithOneOfEach() {
        let text = MergeText.previewText(preview(report(notesAdded: 1, notesCombined: 1, highlightsAdded: 1, bookmarksAdded: 1,
                                                        headingsAdded: 1),
                                                 ink: MergeInkCounts(pagesAdded: 1, pagesCombined: 1, notesAdded: 1, notesCombined: 1)))
        #expect(text == "Adds 1 note, 1 highlight, 1 bookmark, 1 heading, ink on 1 page and handwriting in 1 note. Combines 1 note, the ink on 1 page and the handwriting in 1 note. Nothing on this iPad is removed.")
    }

    @Test func previewSentenceWithOnlyAddsOrOnlyCombines() {
        #expect(MergeText.previewText(preview(report(highlightsAdded: 2)))
                == "Adds 2 highlights. Nothing on this iPad is removed.")
        #expect(MergeText.previewText(preview(report(), ink: MergeInkCounts(pagesCombined: 1)))
                == "Combines the ink on 1 page. Nothing on this iPad is removed.")
        #expect(MergeText.previewText(preview(report(bookmarksAdded: 1), ink: MergeInkCounts(pagesAdded: 2)))
                == "Adds 1 bookmark and ink on 2 pages. Nothing on this iPad is removed.")
    }

    @Test func previewSentenceWhenNothingIsAdded() {
        #expect(MergeText.previewText(preview(report())) == "This iPad already has everything in this backup.")
        // Counts the sentence does not mention (identical notes, matched headings) add nothing.
        var identical = report()
        identical.notesIdentical = 4
        identical.headingsMatched = 2
        identical.duplicatesSkipped = 1
        #expect(MergeText.previewText(preview(identical)) == MergeText.nothingToAdd)
    }

    @Test func listJoinsWithoutASerialComma() {
        #expect(MergeText.list([]) == "")
        #expect(MergeText.list(["a"]) == "a")
        #expect(MergeText.list(["a", "b"]) == "a and b")
        #expect(MergeText.list(["a", "b", "c"]) == "a, b and c")
    }

    // MARK: Summary

    @Test func summaryOfAMerge() {
        let book = merged(report(notesAdded: 3, notesCombined: 2, highlightsAdded: 12, bookmarksAdded: 2),
                          ink: MergeInkCounts(pagesCombined: 4))
        #expect(MergeText.summaryLines(book) == ["Added 3 notes, 12 highlights and 2 bookmarks. Combined 2 notes and the ink on 4 pages."])
        let one = merged(report(notesAdded: 1), ink: MergeInkCounts(notesCombined: 1))
        #expect(MergeText.summaryLines(one) == ["Added 1 note. Combined the handwriting in 1 note."])
    }

    @Test func summarySaysNothingNew() {
        #expect(MergeText.summaryLines(merged(report())) == ["Nothing new: this iPad already had everything in the backup."])
        // Ink that differed in bytes but already held every stroke is not counted.
        let again = merged(report(), ink: MergeInkCounts(pagesCombined: 3), alreadyPresent: 3)
        #expect(MergeText.summaryLines(again) == [MergeText.nothingNew])
    }

    @Test func combinedInkAlreadyPresentIsLeftOut() {
        let pages = MergeText.summaryCounts(merged(report(), ink: MergeInkCounts(pagesCombined: 3), alreadyPresent: 1))
        #expect(pages.inkPagesCombined == 2 && pages.inkPagesAndNotesCombined == 0)
        let notes = MergeText.summaryCounts(merged(report(), ink: MergeInkCounts(notesCombined: 2), alreadyPresent: 1))
        #expect(notes.inkNotesCombined == 1)
        // Both had combined ink: the rest can't be placed, so it is counted together.
        let both = merged(report(), ink: MergeInkCounts(pagesCombined: 3, notesCombined: 2), alreadyPresent: 1)
        #expect(MergeText.summaryLines(both) == ["Combined the ink on 4 pages and notes."])
    }

    @Test func summaryOfUnreadableInkAndTheBackupsPDF() {
        let noteID = UUID()
        let book = merged(report(highlightsAdded: 1),
                          unreadable: [.init(location: .page(2), side: .local), .init(location: .page(6), side: .backup),
                                       .init(location: .page(2), side: .backup), .init(location: .note(noteID), side: .local)],
                          tookPDF: true)
        #expect(MergeText.summaryLines(book) == [
            "Added 1 highlight.",
            "The ink on pages 3 and 7 and in 1 note couldn’t be read, so it was kept as it was and not combined.",
            "Its PDF came from the backup.",
        ])
        #expect(MergeText.unreadableLine([]) == nil)
        #expect(MergeText.unreadableLine([.init(location: .page(0), side: .local)])
                == "The ink on page 1 couldn’t be read, so it was kept as it was and not combined.")
        #expect(MergeText.unreadableLine([.init(location: .note(UUID()), side: .local), .init(location: .note(UUID()), side: .backup)])
                == "The ink in 2 notes couldn’t be read, so it was kept as it was and not combined.")
    }

    @Test func undoHintNamesTheBackupScreen() {
        #expect(RestorePreviewLogic.undoHint == "To put things back as they were, use Undo Last Restore on the Backup screen.")
    }

    // MARK: Undo Last Restore

    private func record(changed: [String], added: [String], notChanged: [String] = []) -> RestoreSafetyRecord {
        let changedBooks = changed.map { RestoreSafetyRecord.ChangedBook(previousID: UUID(), title: $0, currentID: UUID(), hasKnownPDFHash: true) }
            + notChanged.map { RestoreSafetyRecord.ChangedBook(previousID: UUID(), title: $0, currentID: nil, hasKnownPDFHash: true) }
        return RestoreSafetyRecord(id: UUID(), createdAt: Date(), sourceName: "backup", changed: changedBooks,
                                   added: added.map { .init(id: UUID(), title: $0) })
    }

    @Test func undoRowSaysWhenAndHowMany() {
        #expect(UndoRestoreLogic.rowTitle == "Undo Last Restore")
        #expect(UndoRestoreLogic.rowDetail(record(changed: ["A"], added: []), dateText: fixedDate)
                == "The restore on DATE changed 1 book.")
        #expect(UndoRestoreLogic.rowDetail(record(changed: [], added: ["B", "C"]), dateText: fixedDate)
                == "The restore on DATE added 2 books.")
        // Books saved as a precaution but not changed are not counted.
        #expect(UndoRestoreLogic.rowDetail(record(changed: ["A", "B"], added: ["C"], notChanged: ["D"]), dateText: fixedDate)
                == "The restore on DATE changed 2 books and added 1 book.")
        #expect(UndoRestoreLogic.rowAccessibilityLabel(record(changed: ["A"], added: []), dateText: fixedDate)
                == "Undo Last Restore. The restore on DATE changed 1 book.")
    }

    @Test func undoConfirmationNamesTheBooksAndWhatIsLost() {
        let one = UndoRestoreLogic.confirmation(record(changed: ["A"], added: ["B"], notChanged: ["D"]), dateText: fixedDate)
        #expect(one.title == "Undo the Last Restore?")
        #expect(one.confirmTitle == "Undo Restore")
        #expect(one.message == "“A” will go back to how it was before the restore on DATE. Anything done in it since then will be lost. “B”, which the restore added, will be removed from the Library with its notes, highlights and ink.")
        let many = UndoRestoreLogic.confirmation(record(changed: ["A", "C"], added: []), dateText: fixedDate)
        #expect(many.message.hasPrefix("“A” and “C” will go back to how they were before the restore on DATE. Anything done in them since then will be lost."))
        #expect(!many.message.contains("removed"))
        let added = UndoRestoreLogic.confirmation(record(changed: [], added: ["B", "E"]), dateText: fixedDate)
        #expect(added.message.hasSuffix("which the restore added, will be removed from the Library with their notes, highlights and ink."))
        #expect(!added.message.contains("go back"))
    }

    @Test func undoResult() {
        var summary = RestoreSummary()
        #expect(UndoRestoreLogic.resultLine(summary) == "Nothing was undone.")
        summary.restored = [.init(id: UUID(), title: "A", hasPDF: true)]
        #expect(UndoRestoreLogic.resultLine(summary) == "Restore undone: 1 book put back as it was.")
        summary.restored.append(.init(id: UUID(), title: "C", hasPDF: true))
        summary.removed = [.init(id: UUID(), title: "B", hasPDF: false)]
        #expect(UndoRestoreLogic.resultLine(summary) == "Restore undone: 2 books put back as they were, 1 book removed.")
        summary.failures = [.init(id: UUID(), title: "D", message: "“D” couldn’t be removed (disk).")]
        #expect(UndoRestoreLogic.resultLine(summary)
                == "Restore undone: 2 books put back as they were, 1 book removed. “D” couldn’t be removed (disk). Undo Last Restore again to finish.")
    }
}
