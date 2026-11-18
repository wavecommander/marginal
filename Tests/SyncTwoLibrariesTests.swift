import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync
import Testing
import UIKit
@testable import TactileTexts

/// Two real libraries in one process syncing through the real `SyncEngine`, the app's
/// `SyncLibrary` (`LibrarySyncCore`) and ink merge (`AppSyncInkMerger`, real PencilKit strokes),
/// and one in-memory account (C4: "an app test runs two libraries in one process against one
/// store").
@MainActor
@Suite(.serialized)
struct SyncTwoLibrariesTests {
    typealias S = SyncTestSupport
    typealias Merge = BackupMergeTestSupport

    @MainActor
    struct World {
        let objects = InMemorySyncObjectStore()
        let a: SyncTestDevice
        let b: SyncTestDevice

        init() throws {
            a = try SyncTestDevice("A", objects: objects)
            b = try SyncTestDevice("B", objects: objects)
        }

        func cleanUp() { a.cleanUp(); b.cleanUp() }

        func settle(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await S.settle([a, b], objects: objects, comment, sourceLocation: sourceLocation)
            try await S.expectEqual(a, b, comment, sourceLocation: sourceLocation)
        }
    }

    /// Both devices hold `small.pdf`, imported separately, agreed.
    private func sharedWorld() async throws -> (World, Book, Book) {
        let world = try World()
        let bookA = try await world.a.importBook()
        let bookB = try await world.b.importBook()
        try await world.settle("shared start")
        return (world, try #require(try world.a.store.books.book(id: bookA.id)), try #require(try world.b.store.books.book(id: bookB.id)))
    }

    // MARK: Crossing over

    @Test func everyKindOfRecordInkAndADeletionCrossesBothWays() async throws {
        let world = try World()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        let smallA = try await a.importBook()
        let smallB = try await b.importBook()
        let otherA = try await a.importBook(BackupTestSupport.noOutline)
        let otherB = try await b.importBook(BackupTestSupport.noOutline)
        try await world.settle("start")

        // A → B: a note, a highlight, a bookmark, a heading, page ink, note ink.
        let date = Date(timeIntervalSinceReferenceDate: 790_000_000)
        try a.store.notes.save(Note(bookID: smallA.id, target: .page(2), text: "A’s note", createdAt: date))
        let highlightA = Highlight(bookID: smallA.id, pageIndex: 1, rects: [CGRect(x: 10, y: 20, width: 90, height: 12)],
                                   color: .green, text: "marked on A", createdAt: date)
        try a.store.highlights.save(highlightA)
        try a.store.bookmarks.setBookmarked(true, bookID: smallA.id, pageIndex: 4)
        let headingA = UserHeading(bookID: smallA.id, title: "A’s heading", pageIndex: 3, parent: nil, createdAt: date)
        try a.store.headings.save(headingA)
        let pageStroke = S.stroke(80)
        try await S.addPageInk(a, smallA.id, page: 5, [pageStroke])
        let noteStrokes = try await Merge.writeNote(a.store, smallA.id, target: .page(6), text: "Inked\nnote", strokesOver: [1])
        try await world.settle("A’s edits")

        let notesB = try b.archive(smallB).notes
        #expect(notesB.contains { $0.target == .page(2) && $0.text == "A’s note" })
        #expect(try b.archive(smallB).highlights.map(\.id) == [highlightA.id])
        #expect(try b.archive(smallB).bookmarks.map(\.pageIndex) == [4])
        #expect(try b.archive(smallB).userHeadings.map(\.title) == ["A’s heading"])
        #expect(try await b.pageStrokes(smallB.id, page: 5) == [StrokeIdentity(pageStroke)])
        let inkedB = try #require(notesB.first { $0.target == .page(6) })
        #expect(inkedB.hasInk)
        let inkB = try #require(try await S.noteInk(b, inkedB))
        #expect(S.paragraph(of: noteStrokes[0], in: inkB, text: inkedB.text) == "note")

        // B → A: the same kinds, other content.
        try b.store.notes.save(Note(bookID: smallB.id, target: .page(8), text: "B’s note", createdAt: date))
        let highlightB = Highlight(bookID: smallB.id, pageIndex: 2, rects: [CGRect(x: 30, y: 40, width: 50, height: 12)],
                                   color: .pink, text: "marked on B", createdAt: date)
        try b.store.highlights.save(highlightB)
        try b.store.bookmarks.setBookmarked(true, bookID: smallB.id, pageIndex: 9)
        try b.store.headings.save(UserHeading(bookID: smallB.id, title: "B’s heading", pageIndex: 7, parent: headingA.anchor,
                                              createdAt: date))
        let pageStrokeB = S.stroke(160)
        try await S.addPageInk(b, smallB.id, page: 5, [pageStrokeB])
        let noteStrokesB = try await Merge.writeNote(b.store, smallB.id, target: .page(6), text: "Inked\nnote", strokesOver: [0])
        try await world.settle("B’s edits")

        let archiveA = try a.archive(smallA)
        #expect(archiveA.notes.contains { $0.target == .page(8) && $0.text == "B’s note" })
        #expect(Set(archiveA.highlights.map(\.id)) == [highlightA.id, highlightB.id])
        #expect(archiveA.bookmarks.map(\.pageIndex).sorted() == [4, 9])
        #expect(Set(archiveA.userHeadings.map(\.title)) == ["A’s heading", "B’s heading"])
        #expect(Set(try await a.pageStrokes(smallA.id, page: 5)) == [StrokeIdentity(pageStroke), StrokeIdentity(pageStrokeB)])
        let inkedA = try #require(archiveA.notes.first { $0.target == .page(6) })
        let inkA = try #require(try await S.noteInk(a, inkedA))
        #expect(S.paragraph(of: noteStrokesB[0], in: inkA, text: inkedA.text) == "Inked")
        #expect(S.paragraph(of: noteStrokes[0], in: inkA, text: inkedA.text) == "note")

        // A deletion each way.
        try await a.store.deleteBook(id: otherA.id, origin: nil)
        try await world.settle("deleted on A")
        #expect(try b.store.books.book(id: otherB.id) == nil)
        try await b.store.deleteBook(id: smallB.id, origin: nil)
        try await world.settle("deleted on B")
        #expect(try a.store.books.allBooks().isEmpty)
    }

    @Test func aJoinOfTwoLibrariesRemovesNothing() async throws {
        let world = try World()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        let date = Date(timeIntervalSinceReferenceDate: 790_000_000)
        // Both have small.pdf with notes of their own on one page and on others; each has a
        // book the other lacks.
        let smallA = try await a.importBook()
        try a.store.notes.save(Note(bookID: smallA.id, target: .page(1), text: "From A", createdAt: date))
        try a.store.bookmarks.setBookmarked(true, bookID: smallA.id, pageIndex: 3)
        try await S.addPageInk(a, smallA.id, page: 2, [S.stroke(50)])
        _ = try await a.importBook(BackupTestSupport.noOutline)
        let smallB = try await b.importBook()
        try b.store.notes.save(Note(bookID: smallB.id, target: .page(1), text: "From B", createdAt: date))
        try b.store.notes.save(Note(bookID: smallB.id, target: .page(4), text: "Only B", createdAt: date))
        try await S.addPageInk(b, smallB.id, page: 2, [S.stroke(90)])
        _ = try await b.importBook(BackupTestSupport.large)

        try await a.sync()
        try await b.sync()
        try await world.settle("after the join")
        let archive = try a.archive(try #require(a.book(sha256: S.sha256(smallA, in: a))))
        let page1 = try #require(archive.notes.first { $0.target == .page(1) })
        #expect(page1.text.contains("From A") && page1.text.contains("From B"))
        #expect(archive.notes.contains { $0.text == "Only B" })
        #expect(archive.bookmarks.map(\.pageIndex) == [3])
        #expect(try await a.pageStrokes(smallA.id, page: 2).count == 2)
        #expect(try a.store.books.allBooks().count == 3)
    }

    // MARK: Concurrent edits

    @Test func strokesAddedOnBothSidesAreKeptAndAnEraseTravels() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        let base = [S.stroke(40), S.stroke(80)]
        try await S.addPageInk(a, bookA.id, page: 3, base)
        try await world.settle("base ink")

        // Both add a stroke to the same page while apart.
        let fromA = S.stroke(120), fromB = S.stroke(160)
        try await S.addPageInk(a, bookA.id, page: 3, [fromA])
        try await S.addPageInk(b, bookB.id, page: 3, [fromB])
        try await world.settle("both drew")
        let union = Set((base + [fromA, fromB]).map(StrokeIdentity.init))
        #expect(Set(try await a.pageStrokes(bookA.id, page: 3)) == union)

        // A erases a stroke B left alone.
        let kept = try await a.store.pageInk(bookID: bookA.id, pageIndex: 3).map { try PKDrawing(data: $0).strokes } ?? []
        try await Merge.savePageInk(a.store, bookA.id, page: 3, kept.filter { StrokeIdentity($0) != StrokeIdentity(base[0]) })
        try await world.settle("A erased")
        #expect(!(try await b.pageStrokes(bookB.id, page: 3)).contains(StrokeIdentity(base[0])))
        #expect(try await b.pageStrokes(bookB.id, page: 3).count == 3)
    }

    @Test func noteTextChangedOnBothSidesKeepsEachSidesInkOnItsParagraph() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        let alpha = try await Merge.writeNote(a.store, bookA.id, target: .page(1), text: "Alpha\nBeta", strokesOver: [0])[0]
        try await world.settle("base note")

        // A adds Gamma with a stroke on it; B adds Zero above, with a stroke on Beta.
        let gamma = try await Merge.writeNote(a.store, bookA.id, target: .page(1), text: "Alpha\nBeta\nGamma", strokesOver: [2])[0]
        let beta = try await Merge.writeNote(b.store, bookB.id, target: .page(1), text: "Zero\nAlpha\nBeta", strokesOver: [2])[0]
        try await world.settle("both edited")

        for device in [a, b] {
            let book = try #require(device.book(sha256: S.sha256(bookA, in: a)))
            let note = try #require(try device.archive(book).notes.first { $0.target == .page(1) })
            #expect(NoteBandLayout.paragraphs(of: note.text) == ["Zero", "Alpha", "Beta", "Gamma"])
            let ink = try #require(try await S.noteInk(device, note))
            #expect(ink.strokes.count == 3)
            #expect(S.paragraph(of: alpha, in: ink, text: note.text) == "Alpha", "\(device.name)")
            #expect(S.paragraph(of: beta, in: ink, text: note.text) == "Beta", "\(device.name)")
            #expect(S.paragraph(of: gamma, in: ink, text: note.text) == "Gamma", "\(device.name)")
            #expect(note.bandLayout == Merge.layout(note.text))
        }
    }

    @Test func inkOnAParagraphTheOtherSideRemovedIsKept() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        try await Merge.writeNote(a.store, bookA.id, target: .page(1), text: "Alpha\nBeta\nGamma")
        try await world.settle("base note")
        // B writes on Beta; A removes the Beta paragraph.
        let onBeta = try await Merge.writeNote(b.store, bookB.id, target: .page(1), text: "Alpha\nBeta\nGamma", strokesOver: [1])[0]
        try await Merge.writeNote(a.store, bookA.id, target: .page(1), text: "Alpha\nGamma")
        try await world.settle("removed and inked")
        for device in [a, b] {
            let book = try #require(device.book(sha256: S.sha256(bookA, in: a)))
            let note = try #require(try device.archive(book).notes.first { $0.target == .page(1) })
            let ink = try #require(try await S.noteInk(device, note), "\(device.name) lost the ink")
            #expect(Merge.count(of: onBeta, in: ink.strokes.map(\.local)) == 1, "\(device.name)")
        }
    }

    // MARK: Edits in progress

    @Test func aBusyNoteIsNotLostAndTheRemoteChangeArrivesNextRound() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        try a.store.notes.save(Note(bookID: bookA.id, target: .page(3), text: "Start", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        try await world.settle("base note")
        let noteB = try #require(try b.archive(bookB).notes.first { $0.target == .page(3) })

        var editedA = try #require(try a.store.notes.note(bookID: bookA.id, target: .page(3)))
        editedA.text = "Start\nfrom A"
        try a.store.notes.save(editedA)
        try await a.sync()
        // B's reader is typing in the note (its own edit stored, more coming).
        var editedB = noteB
        editedB.text = "Start\nfrom B"
        try b.store.notes.save(editedB)
        b.editors.busy[bookB.id] = SyncBusyEditors(notes: [noteB.id], noteTargets: [.page(3)])
        let report = try await b.sync()
        #expect(report.books.contains { $0.skipped.contains(.busy([.note(noteB.id)])) })
        #expect(try b.store.notes.note(id: noteB.id)?.text == "Start\nfrom B", "the note being edited is left alone")

        b.editors.busy = [:]
        try await world.settle("after editing")
        let merged = try #require(try b.store.notes.note(id: noteB.id))
        #expect(NoteBandLayout.paragraphs(of: merged.text).sorted() == ["Start", "from A", "from B"])
    }

    @Test func aBusyPageIsNotLostAndTheRemoteStrokesArriveNextRound() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        let fromA = S.stroke(60), fromB = S.stroke(140)
        try await S.addPageInk(a, bookA.id, page: 4, [fromA])
        try await a.sync()
        try await S.addPageInk(b, bookB.id, page: 4, [fromB])
        b.editors.busy[bookB.id] = SyncBusyEditors(pages: [4])
        let report = try await b.sync()
        #expect(report.books.contains { $0.skipped.contains(.busy([.page(4)])) })
        #expect(try await b.pageStrokes(bookB.id, page: 4) == [StrokeIdentity(fromB)])
        b.editors.busy = [:]
        try await world.settle("after drawing")
        #expect(Set(try await b.pageStrokes(bookB.id, page: 4)) == [StrokeIdentity(fromA), StrokeIdentity(fromB)])
    }

    @Test func aSurfaceThatBecameBusyAfterTheSnapshotIsRefusedAndTakenUpLater() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        try await S.addPageInk(a, bookA.id, page: 2, [S.stroke(70)])
        try await a.sync()
        let armed = SyncTestBox(true)
        b.core.beforeApply = { [b] id in
            if armed.value { b.editors.busy[id] = SyncBusyEditors(pages: [2]) }
        }
        let report = try await b.sync()
        // The apply was refused; computed again, the page is left for later.
        #expect(report.failures.isEmpty)
        #expect(report.books.contains { $0.skipped.contains(.busy([.page(2)])) })
        #expect(try await b.pageStrokes(bookB.id, page: 2).isEmpty)
        armed.value = false
        b.editors.busy = [:]
        b.core.beforeApply = nil
        try await world.settle("after the stroke")
        #expect(try await b.pageStrokes(bookB.id, page: 2).count == 1)
    }

    @Test func aSnapshotThatWentStaleMakesTheRoundTryAgain() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        try a.store.notes.save(Note(bookID: bookA.id, target: .page(5), text: "From A", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        try await a.sync()
        // The reader bookmarks a page between B's snapshot and its apply, once.
        let changes = SyncTestBox(0)
        b.core.beforeApply = { [b] id in
            guard changes.value == 0 else { return }
            changes.value += 1
            try? b.store.bookmarks.setBookmarked(true, bookID: id, pageIndex: 6)
        }
        let report = try await b.sync()
        #expect(report.failures.isEmpty)
        #expect(changes.value == 1)
        let archive = try b.archive(bookB)
        #expect(archive.notes.contains { $0.text == "From A" })
        #expect(archive.bookmarks.map(\.pageIndex) == [6])
        b.core.beforeApply = nil
        try await world.settle("after the stale snapshot")
        #expect(try a.archive(bookA).bookmarks.map(\.pageIndex) == [6])
    }

    @Test func aSecondWindowSeesTheAppliedChangesWithSyncsOriginAndNothingCloses() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        try a.store.notes.save(Note(bookID: bookA.id, target: .page(1), text: "Hello", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        try a.store.highlights.save(Highlight(bookID: bookA.id, pageIndex: 3, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                              color: .blue, text: "x", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        try await S.addPageInk(a, bookA.id, page: 2, [S.stroke(30)])
        try await a.sync()

        var seen: [StoreChangeEvent] = []
        let window = b.store.hub.observe { event in if event.change.bookID == bookB.id { seen.append(event) } }
        try await b.sync()
        _ = window
        #expect(seen.allSatisfy { $0.isFrom(b.core.origin) })
        #expect(seen.contains { if case .noteSaved(_, .page(1), _) = $0.change { true } else { false } })
        #expect(seen.contains { $0.change == .highlightsChanged(bookID: bookB.id, pageIndex: 3) })
        #expect(seen.contains { $0.change == .pageInkChanged(bookID: bookB.id, pageIndex: 2) })
        #expect(!seen.contains { $0.change == .bookDeleted(bookID: bookB.id) }, "no window closes")
    }

    // MARK: Reading position

    @Test func theReadingPositionSyncsButAnOpenReaderIsNotMovedAndDoesNotWriteItBack() async throws {
        let (world, bookA, bookB) = try await sharedWorld()
        defer { world.cleanUp() }
        let (a, b) = (world.a, world.b)
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        configuration.lastReadSaveDelay = .seconds(60)
        let open = ReaderSession(book: try #require(try b.store.books.book(id: bookB.id)), store: b.store, configuration: configuration)
        open.pdfReportedCurrentPage(2)
        await open.suspend()
        #expect(try b.store.books.book(id: bookB.id)?.lastReadPageIndex == 2)
        try await world.settle("B read to page 3")

        // A reads on, later.
        var readA = try #require(try a.store.books.book(id: bookA.id))
        readA.lastReadPageIndex = 7
        readA.lastOpenedAt = Date().addingTimeInterval(3600)
        try a.store.books.save(readA)
        try await a.sync()
        try await b.sync()
        #expect(try b.store.books.book(id: bookB.id)?.lastReadPageIndex == 7, "applied to the record")
        #expect(open.currentPageIndex == 2, "the open reader is not moved")

        // The open reader saves (backgrounded, a flush): it writes nothing back.
        await open.suspend()
        #expect(try b.store.books.book(id: bookB.id)?.lastReadPageIndex == 7)
        try await world.settle("no ping-pong")
        #expect(try a.store.books.book(id: bookA.id)?.lastReadPageIndex == 7)
        #expect(open.currentPageIndex == 2)

        // A reader opened now opens at the synced page.
        let next = ReaderSession(book: try #require(try b.store.books.book(id: bookB.id)), store: b.store, configuration: configuration)
        #expect(next.currentPageIndex == 7)
        open.close()
        next.close()
    }
}
