import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// The merge engine (M3): restoring a book already in the Library by merging the backup's copy
/// into it, with real PencilKit page ink and note ink, through the journalled commit.
@MainActor
struct BackupMergeTests {
    typealias Support = BackupTestSupport
    typealias M = BackupMergeTestSupport

    // MARK: Union

    @Test func twoDivergedCopiesMergeIntoTheUnionOfRecordsAndStrokes() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        let service = Support.makeService(d.local, scratch: d.scratch)
        let session = try await service.openBackup(at: d.backup)
        defer { session.close() }
        #expect(session.plan.items.map(\.defaultAction) == [.merge])
        let preview = try #require(await service.mergePreview(for: session)[d.book.id])
        let summary = try await service.restore([d.book.id: .merge], from: session, restorePDFs: true)

        #expect(summary.failures.isEmpty)
        #expect(summary.restored.map(\.id) == [d.book.id])
        let mergedBook = try #require(summary.merged.first)
        #expect(summary.merged.count == 1 && mergedBook.id == d.book.id && mergedBook.backupBookID == d.book.id)
        #expect(mergedBook.unreadableInk.isEmpty && !mergedBook.tookPDFFromBackup)

        // Records: every local one with its ID, plus the backup's.
        let merged = try #require(try Support.archive(d.local, d.book.id))
        #expect(merged.book == d.localBefore.book, "the local book record, reading position included")
        for note in d.localBefore.notes { #expect(merged.notes.contains { $0.id == note.id && $0.target == note.target }) }
        for highlight in d.localBefore.highlights { #expect(merged.highlights.contains(highlight)) }
        for bookmark in d.localBefore.bookmarks { #expect(merged.bookmarks.contains(bookmark)) }
        for heading in d.localBefore.userHeadings { #expect(merged.userHeadings.contains(heading)) }
        #expect(Set(merged.highlights.map(\.text)) == ["base highlight", "backup highlight", "local highlight"])
        #expect(merged.bookmarks.map(\.pageIndex).sorted() == [0, 4, 8])
        #expect(Set(merged.userHeadings.map(\.title)) == ["Base heading", "Backup heading", "Local heading"])
        #expect(merged.notes.map(\.target).sorted { "\($0)" < "\($1)" }
            == [NoteTarget.page(1), .page(3), .page(7)].sorted { "\($0)" < "\($1)" })
        let expected = BookMerge.merge(local: d.localBefore, incoming: d.originArchive)
        #expect(mergedBook.report == expected.report)
        #expect(expected.report.notesAdded == 1 && expected.report.notesCombined == 1 && expected.report.highlightsAdded == 1
            && expected.report.bookmarksAdded == 1 && expected.report.headingsAdded == 1)

        // Page ink: both sides' strokes, each exactly once.
        let page2 = try #require(try await M.pageDrawing(d.local, d.book.id, page: 2))
        #expect(page2.strokes.count == 3)
        for role in ["page2-base", "page2-origin", "page2-local"] {
            #expect(M.count(of: d.strokes[role]!, in: page2.strokes) == 1, "\(role)")
        }
        #expect(try await M.pageDrawing(d.local, d.book.id, page: 5).map { M.identities($0.strokes) }
            == [StrokeIdentity(d.strokes["page5-origin"]!)])
        #expect(try await M.pageDrawing(d.local, d.book.id, page: 6).map { M.identities($0.strokes) }
            == [StrokeIdentity(d.strokes["page6-local"]!)])

        // The combined note: both sides' paragraphs, local first; each stroke on its paragraph.
        let note = try #require(merged.notes.first { $0.target == .page(1) })
        #expect(note.id == d.localBefore.notes.first { $0.target == .page(1) }?.id)
        #expect(note.text == "Alpha\nBeta\nGamma")
        let ink = try #require(try await M.storedNoteInk(d.local, note))
        let mergedLayout = M.layout(note.text)
        #expect(ink.layout == mergedLayout && note.bandLayout == mergedLayout && note.hasInk)
        #expect(ink.strokes.count == 3)
        for (role, paragraph) in [("alpha", 0), ("beta", 1), ("gamma", 2)] {
            let placed = try #require(M.placed(d.strokes[role]!, in: ink), "\(role)")
            #expect(placed.band == .paragraph(paragraph), "\(role)")
            let band = mergedLayout.paragraphs[paragraph]
            let middle = placed.page.renderBounds.midY
            #expect(middle >= band.top && middle < band.bottom, "\(role) at \(middle), band \(band.top)..<\(band.bottom)")
        }
        let added = try #require(merged.notes.first { $0.target == .page(3) })
        #expect(added.text == "From the backup" && added.hasInk)
        let addedInk = try #require(try await M.storedNoteInk(d.local, added))
        #expect(M.identities(addedInk.strokes.map(\.local)) == [StrokeIdentity(d.strokes["page3-note"]!)])

        // The preview said exactly this.
        #expect(preview.localBookID == d.book.id)
        #expect(preview.report == mergedBook.report)
        #expect(preview.ink == mergedBook.ink)
        #expect(mergedBook.ink == MergeInkCounts(pagesAdded: 1, pagesCombined: 1, notesAdded: 1, notesCombined: 1))
        #expect(mergedBook.combinedInkAlreadyPresent == 0)
        #expect(Support.restoresDirectoryIsGone(d.local))
        #expect(try await d.local.sweepOrphanedBookDirectories().isEmpty)
    }

    @Test func mergingTheSameBackupAgainChangesNothing() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        _ = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch)
        let once = try M.inkState(d.local)
        let filesOnce = try Support.libraryState(d.local).files

        let service = Support.makeService(d.local, scratch: d.scratch)
        let session = try await service.openBackup(at: d.backup)
        defer { session.close() }
        let preview = try #require(await service.mergePreview(for: session)[d.book.id])
        #expect(preview.report.addsNothing)
        let summary = try await service.restore([d.book.id: .merge], from: session, restorePDFs: true)
        #expect(summary.failures.isEmpty)
        let again = try #require(summary.merged.first)
        #expect(again.report.addsNothing)
        #expect(again.ink.pagesAdded == 0 && again.ink.notesAdded == 0)
        #expect(again.combinedInkAlreadyPresent == again.ink.pagesCombined + again.ink.notesCombined,
                "ink that differs in bytes already holds every stroke of the backup's")
        // Records equal, every drawing the same strokes in the same places; in fact the same bytes.
        #expect(try M.inkState(d.local) == once)
        #expect(try Support.libraryState(d.local).files == filesOnce)
    }

    @Test func trailingInkFromBothSidesDoesNotOverlap() async throws {
        let scratch = try Support.scratch("BackupMergeTrailing")
        let local = try LibraryStore.ephemeral()
        let origin = try LibraryStore.ephemeral()
        defer { for url in [scratch, local.rootDirectory, origin.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let book = try #require(try await ImportService(store: local).importPDF(at: Support.small).book)
        try await M.writeNote(local, book.id, target: .page(0), text: "Alpha\nBeta", strokesOver: [0])
        let base = try await Support.makeService(local, scratch: scratch).backUpToFile(includePDFs: true).url
        let originService = Support.makeService(origin, scratch: scratch)
        let session = try await originService.openBackup(at: base)
        _ = try await originService.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()

        // Both sides write in the blank space after the text, at the same place.
        let fromBackup = try await M.writeNote(origin, book.id, target: .page(0), text: "Alpha\nBeta",
                                               strokesOver: [nil, nil], trailingOffset: 30)
        let backup = try await Support.makeService(origin, scratch: scratch).backUpToFile(includePDFs: false).url
        let fromHere = try await M.writeNote(local, book.id, target: .page(0), text: "Alpha\nBeta",
                                             strokesOver: [nil], trailingOffset: 30)
        #expect(fromHere[0].renderBounds.intersects(fromBackup[0].renderBounds), "they would overlap")

        let summary = try await M.merge(backup, bookID: book.id, into: local, scratch: scratch)
        #expect(summary.failures.isEmpty)
        let note = try #require(try local.notes.note(bookID: book.id, target: .page(0)))
        let ink = try #require(try await M.storedNoteInk(local, note))
        #expect(ink.strokes.count == 4)
        let mine = try #require(M.placed(fromHere[0], in: ink))
        #expect(mine.band == .trailing)
        #expect(abs(mine.page.renderBounds.minY - fromHere[0].renderBounds.minY) < 0.01, "the local ink does not move")
        let theirs = try fromBackup.map { try #require(M.placed($0, in: ink)) }
        for stroke in theirs {
            #expect(stroke.band == .trailing)
            #expect(stroke.page.renderBounds.minY >= mine.page.renderBounds.maxY + NoteInkMerging.trailingGap - 0.01)
        }
        // The backup's strokes keep their arrangement.
        let gap = theirs[1].page.renderBounds.minY - theirs[0].page.renderBounds.minY
        #expect(abs(gap - (fromBackup[1].renderBounds.minY - fromBackup[0].renderBounds.minY)) < 0.01)

        // Again: found by identity, neither moved nor duplicated.
        let before = try M.inkState(local)
        _ = try await M.merge(backup, bookID: book.id, into: local, scratch: scratch)
        #expect(try M.inkState(local) == before)
    }

    // MARK: Identity

    @Test func aBackupOfTheSamePDFUnderAnotherIDMergesIntoTheLocalBook() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        let other = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: other.rootDirectory) }
        let own = try #require(try await ImportService(store: other).importPDF(at: Support.small).book)
        #expect(own.id != d.book.id && own.fingerprint == d.book.fingerprint)
        let delta = try #require(try await M.writeNote(other, own.id, target: .page(1), text: "Alpha\nDelta", strokesOver: [1]).first)
        let ownPage = M.stroke(y: 600)
        try await M.savePageInk(other, own.id, page: 2, [ownPage])
        let localBefore = try #require(try Support.archive(other, own.id))

        let service = Support.makeService(other, scratch: d.scratch)
        let session = try await service.openBackup(at: d.backup)
        defer { session.close() }
        let preview = try #require(await service.mergePreview(for: session)[d.book.id])
        #expect(preview.localBookID == own.id)
        let summary = try await service.restore([d.book.id: .merge], from: session, restorePDFs: false)
        #expect(summary.failures.isEmpty)
        let mergedBook = try #require(summary.merged.first)
        #expect(mergedBook.id == own.id && mergedBook.backupBookID == d.book.id)
        #expect(preview.ink == mergedBook.ink && preview.report == mergedBook.report)

        #expect(try other.books.allBooks().map(\.id) == [own.id], "the local book keeps its ID; no second book")
        let merged = try #require(try Support.archive(other, own.id))
        #expect(merged.book == localBefore.book)
        #expect(merged.notes.allSatisfy { $0.bookID == own.id })

        // The backup's note ink, keyed there by the backup's note IDs, is found and kept.
        let originNote = try #require(d.originArchive.notes.first { $0.target == .page(3) })
        let added = try #require(merged.notes.first { $0.target == .page(3) })
        #expect(added.id == originNote.id)
        let addedInk = try #require(try await M.storedNoteInk(other, added))
        #expect(M.identities(addedInk.strokes.map(\.local)) == [StrokeIdentity(d.strokes["page3-note"]!)])

        let combined = try #require(merged.notes.first { $0.target == .page(1) })
        #expect(combined.id == localBefore.notes.first { $0.target == .page(1) }?.id)
        #expect(combined.text == "Alpha\nDelta\nGamma")
        let ink = try #require(try await M.storedNoteInk(other, combined))
        for (stroke, paragraph) in [(delta, 1), (d.strokes["gamma"]!, 2), (d.strokes["alpha"]!, 0)] {
            let placed = try #require(M.placed(stroke, in: ink))
            #expect(placed.band == .paragraph(paragraph))
            let band = ink.layout.paragraphs[paragraph]
            #expect(placed.page.renderBounds.midY >= band.top && placed.page.renderBounds.midY < band.bottom)
        }
        let page2 = try #require(try await M.pageDrawing(other, own.id, page: 2))
        #expect(Set(M.identities(page2.strokes)) == Set(M.identities([ownPage, d.strokes["page2-base"]!, d.strokes["page2-origin"]!])))
        #expect(page2.strokes.count == 3)
        #expect(Support.restoresDirectoryIsGone(other))
        #expect(try await other.sweepOrphanedBookDirectories().isEmpty)
    }

    // MARK: Unreadable ink

    @Test func unreadableInkOnEitherSideIsKeptAndReported() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        // The backup's page 1 note ink is damaged; this iPad's page 2 ink is damaged. (Bytes that
        // neither PencilKit nor the note-ink archive can read: some random bytes do decode, as an
        // empty drawing.)
        let damaged = Data("not a drawing".utf8)
        #expect((try? PKDrawing(data: damaged)) == nil)
        #expect((try? NoteInkArchive.decode(damaged, fallbackLayout: M.layout(""))) == nil)
        let originNote = try #require(try d.origin.notes.note(bookID: d.book.id, target: .page(1)))
        try await d.origin.saveNoteInk(damaged, bookID: d.book.id, noteID: originNote.id, origin: nil)
        let backup = try await Support.makeService(d.origin, scratch: d.scratch).backUpToFile(includePDFs: false).url
        try await d.local.savePageInk(damaged, bookID: d.book.id, pageIndex: 2, origin: nil)
        // Data PencilKit reads as an empty drawing counts as unreadable too (the app never
        // stores an empty drawing): page 5, where the backup has ink.
        try await d.local.savePageInk(PKDrawing().dataRepresentation(), bookID: d.book.id, pageIndex: 5, origin: nil)
        let directory = d.local.bookDirectoryURL(bookID: d.book.id)
        let filesBefore = Support.files(in: directory)
        let localNote = try #require(try d.local.notes.note(bookID: d.book.id, target: .page(1)))

        let summary = try await M.merge(backup, bookID: d.book.id, into: d.local, scratch: d.scratch)
        #expect(summary.failures.isEmpty)
        let mergedBook = try #require(summary.merged.first)
        #expect(Set(mergedBook.unreadableInk) == [UnreadableInk(location: .page(2), side: .local),
                                                    UnreadableInk(location: .page(5), side: .local),
                                                    UnreadableInk(location: .note(localNote.id), side: .backup)])
        // Kept exactly as they were.
        let files = Support.files(in: directory)
        #expect(files["ink/2.drawing"] == filesBefore["ink/2.drawing"])
        #expect(files["ink/5.drawing"] == filesBefore["ink/5.drawing"])
        #expect(files["notes/\(localNote.id.uuidString).drawing"] == filesBefore["notes/\(localNote.id.uuidString).drawing"])
        let merged = try #require(try Support.archive(d.local, d.book.id))
        let note = try #require(merged.notes.first { $0.id == localNote.id })
        #expect(note.text == "Alpha\nBeta\nGamma", "the text is still combined")
        #expect(note.hasInk && note.bandLayout == localNote.bandLayout, "the record describes the file kept")
        // Nothing else is affected.
        #expect(mergedBook.ink.pagesAdded == 0 && mergedBook.ink.notesAdded == 1)
        #expect(try await M.pageDrawing(d.local, d.book.id, page: 6).map { M.identities($0.strokes) }
            == [StrokeIdentity(d.strokes["page6-local"]!)])
        #expect(merged.highlights.count == 3 && merged.bookmarks.count == 3 && merged.userHeadings.count == 3)
        #expect(merged.notes.contains { $0.target == .page(3) && $0.hasInk })
    }

    // MARK: Changes while the merge runs

    @Test func aHighlightAddedWhileTheMergeRunsIsKeptAndSurvivesAnUndo() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        let filesBefore = Support.files(in: d.local.bookDirectoryURL(bookID: d.book.id))
        let late = Highlight(bookID: d.book.id, pageIndex: 9, rects: [CGRect(x: 5, y: 6, width: 50, height: 12)],
                             color: .blue, text: "made during the merge")
        let service = Support.makeService(d.local, scratch: d.scratch)
        service.beforeMergeCommit = { [store = d.local] in
            try? store.highlights.save(late)
            try? store.bookmarks.setBookmarked(true, bookID: late.bookID, pageIndex: 10)
        }
        let summary = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, service: service)
        #expect(summary.failures.isEmpty && summary.merged.count == 1)
        let merged = try #require(try Support.archive(d.local, d.book.id))
        #expect(merged.highlights.contains(late))
        #expect(merged.bookmarks.contains { $0.pageIndex == 10 })
        #expect(merged.highlights.contains { $0.text == "backup highlight" })

        // Undo puts back the book as it was at the merge, the late highlight included.
        let undo = try await service.undoLastRestore()
        #expect(undo.failures.isEmpty && undo.restored.map(\.id) == [d.book.id])
        let after = try #require(try Support.archive(d.local, d.book.id))
        var expected = d.localBefore
        expected.highlights.append(late)
        expected.bookmarks += after.bookmarks.filter { $0.pageIndex == 10 }
        #expect(after == Support.normalized(expected))
        #expect(Support.files(in: d.local.bookDirectoryURL(bookID: d.book.id)) == filesBefore)
    }

    @Test func aNoteChangedWhileTheMergeRunsFailsTheBookAndChangesNothing() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        let service = Support.makeService(d.local, scratch: d.scratch)
        let atCommit = StateBox()
        service.beforeMergeCommit = { [store = d.local, book = d.book] in
            guard var note = try? store.notes.note(bookID: book.id, target: .page(7)) else { return }
            note.text += "\nedited during the merge"
            note.modifiedAt = note.modifiedAt.addingTimeInterval(1)
            _ = try? store.notes.save(note)
            atCommit.state = try? Support.libraryState(store)
        }
        let summary = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, service: service)
        #expect(summary.restored.isEmpty && summary.merged.isEmpty)
        #expect(summary.failures.map(\.id) == [d.book.id])
        #expect(summary.failures.first?.message
            == BackupServiceError.libraryChanged(bookTitle: d.book.title).localizedDescription)
        let stateAtCommit = try #require(atCommit.state)
        #expect(try Support.libraryState(d.local) == stateAtCommit)
        #expect(service.latestRestoreSafetyRecord() == nil, "nothing changed: no undo")
        #expect(Support.restoresDirectoryIsGone(d.local))
    }

    // MARK: Files

    @Test func theMergedBookKeepsTheLocalPDFCoverSidecarAndPosition() async throws {
        let d = try await M.makeDiverged(includePDFs: true)
        defer { d.cleanUp() }
        let directory = d.local.bookDirectoryURL(bookID: d.book.id)
        let before = Support.files(in: directory)
        let pdf = try #require(before[d.book.fileName])
        #expect(before[ImportPipeline.coverFileName] != nil && before[BookStorageLayout.contentHashFileName] != nil)

        let summary = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch)
        let mergedBook = try #require(summary.merged.first)
        #expect(!mergedBook.tookPDFFromBackup && summary.needingPDF.isEmpty)
        let after = Support.files(in: directory)
        #expect(after[d.book.fileName] == pdf)
        #expect(after[ImportPipeline.coverFileName] == before[ImportPipeline.coverFileName])
        #expect(after[BookStorageLayout.contentHashFileName] == before[BookStorageLayout.contentHashFileName])
        #expect(try d.local.books.book(id: d.book.id)?.lastReadPageIndex == 9)
    }

    @Test func aLocalBookWithoutItsPDFGetsTheBackupsWhenAvailable() async throws {
        let d = try await M.makeDiverged(includePDFs: true)
        defer { d.cleanUp() }
        let directory = d.local.bookDirectoryURL(bookID: d.book.id)
        let pdf = try Data(contentsOf: d.local.documentURL(for: d.book))
        try FileManager.default.removeItem(at: d.local.documentURL(for: d.book))
        let sidecar = Support.files(in: directory)[BookStorageLayout.contentHashFileName]

        // Without "restore PDFs" the book is merged and still has none.
        let without = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, restorePDFs: false)
        #expect(without.merged.first?.tookPDFFromBackup == false && without.needingPDF.map(\.id) == [d.book.id])
        #expect(!d.local.hasDocument(d.book))

        let with = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, restorePDFs: true)
        #expect(with.merged.first?.tookPDFFromBackup == true && with.needingPDF.isEmpty)
        #expect(try Data(contentsOf: d.local.documentURL(for: d.book)) == pdf)
        #expect(Support.files(in: directory)[BookStorageLayout.contentHashFileName] == sidecar)
        #expect(try d.local.books.book(id: d.book.id) == d.localBefore.book)
    }

    // MARK: Crash safety and undo

    @Test(arguments: RestoreCommit.Step.allCases)
    func aMergeInterruptedAfterEachCommitStepRecoversToTheMergedBook(_ step: RestoreCommit.Step) async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        let before = try M.inkState(d.local)
        let service = Support.makeService(d.local, scratch: d.scratch)
        _ = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, service: service)
        let merged = try M.inkState(d.local)
        _ = try await service.undoLastRestore()
        #expect(try M.inkState(d.local) == before)

        let crashing = Support.makeService(d.local, scratch: d.scratch)
        crashing.stopCommitAfter = step
        let summary = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, service: crashing)
        #expect(summary.merged.isEmpty, "a stopped commit is not reported as done")
        #expect(!Support.restoresDirectoryIsGone(d.local))

        let report = await RestoreRecovery.recover(store: d.local)
        #expect(report.rolledForward == (step <= .recordsReplaced ? [d.book.id] : []))
        #expect(report.rolledBack.isEmpty && report.keptSessions.isEmpty)
        #expect(try M.inkState(d.local) == merged)
        #expect(Support.restoresDirectoryIsGone(d.local))
        #expect(try await d.local.sweepOrphanedBookDirectories().isEmpty)
        // The interrupted merge can still be undone.
        _ = try await Support.makeService(d.local, scratch: d.scratch).undoLastRestore()
        #expect(try M.inkState(d.local) == before)
    }

    @Test func undoAfterAMergePutsTheBookBackExactly() async throws {
        let d = try await M.makeDiverged(includePDFs: true)
        defer { d.cleanUp() }
        let before = try Support.libraryState(d.local)
        let service = Support.makeService(d.local, scratch: d.scratch)
        _ = try await M.merge(d.backup, bookID: d.book.id, into: d.local, scratch: d.scratch, service: service)
        #expect(try Support.libraryState(d.local) != before)
        let record = try #require(service.latestRestoreSafetyRecord())
        #expect(record.changed == [.init(previousID: d.book.id, title: d.book.title, currentID: d.book.id, hasKnownPDFHash: true)])
        #expect(record.added.isEmpty)

        let undo = try await service.undoLastRestore()
        #expect(undo.failures.isEmpty && undo.restored.map(\.id) == [d.book.id] && undo.needingPDF.isEmpty)
        // Records deep-equal; every file byte-equal (PDF, cover, sidecar, page ink, note ink).
        #expect(try Support.libraryState(d.local) == before)
        #expect(service.latestRestoreSafetyRecord() == nil)
    }

    // MARK: Actions

    @Test func theSetAPIStillReplacesAndMergeOnANewBookRestoresIt() async throws {
        let d = try await M.makeDiverged()
        defer { d.cleanUp() }
        let service = Support.makeService(d.local, scratch: d.scratch)
        let session = try await service.openBackup(at: d.backup)
        let summary = try await service.restore([d.book.id], from: session, restorePDFs: true)
        session.close()
        #expect(summary.restored.map(\.id) == [d.book.id] && summary.merged.isEmpty)
        #expect(try Support.archive(d.local, d.book.id) == d.originArchive, "replaced by the backup's records")
        #expect(try d.local.notes.note(bookID: d.book.id, target: .page(7)) == nil)

        let empty = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: empty.rootDirectory) }
        let fresh = Support.makeService(empty, scratch: d.scratch)
        let newSession = try await fresh.openBackup(at: d.backup)
        defer { newSession.close() }
        #expect(await fresh.mergePreview(for: newSession).isEmpty, "nothing in the Library to merge into")
        let restored = try await fresh.restore([d.book.id: .merge], from: newSession, restorePDFs: true)
        #expect(restored.restored.map(\.id) == [d.book.id] && restored.merged.isEmpty)
        #expect(try Support.archive(empty, d.book.id) == d.originArchive)
    }
}

@MainActor
private final class StateBox {
    var state: BackupTestSupport.LibraryState?
}
