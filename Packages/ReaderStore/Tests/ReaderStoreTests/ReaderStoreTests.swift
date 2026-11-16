import Foundation
import CoreGraphics
import Testing
import SwiftData
import ReaderCore
@testable import ReaderStore

/// A unique temp directory removed by `cleanup()`.
struct TempRoot {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

@MainActor
func makeBook(in store: LibraryStore, pageCount: Int = 1000, title: String = "Book") throws -> Book {
    let book = Book(title: title, fingerprint: UUID().uuidString, fileName: "b.pdf", pageCount: pageCount, fileSize: 10)
    try store.books.save(book)
    return book
}

// MARK: - Conformance

@MainActor
@Suite struct ConformanceTests {
    @Test func rawRecordStore() throws {
        let container = try SchemaFactory.makeContainer(storeURL: nil)
        let s = SwiftDataRecordStore(container: container)
        try RepositoryConformance.verifyRecordStore(s)
    }

    @Test func throughLibraryStore() throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        try RepositoryConformance.verifyRecordStores(books: store.books, notes: store.notes, highlights: store.highlights,
                                                     bookmarks: store.bookmarks, headings: store.headings)
    }

    @Test func swiftDataStorePostsWhatTheContractSays() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        try await RepositoryConformance.verifyChangePosting(store)
    }

    @Test func onDiskStorePostsWhatTheContractSays() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try await RepositoryConformance.verifyChangePosting(try LibraryStore.live(rootDirectory: root.url))
    }

    @Test func fileInkStoreConformance() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try await RepositoryConformance.verifyInkStore(FileInkStore(rootDirectory: root.url))
    }

    @Test func inkThroughLibraryStore() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        try await RepositoryConformance.verifyInkStore(store.inkStore)
    }

    @Test func conformanceOnDiskStore() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try LibraryStore.live(rootDirectory: root.url)
        try RepositoryConformance.verifyRecordStores(books: store.books, notes: store.notes, highlights: store.highlights,
                                                     bookmarks: store.bookmarks, headings: store.headings)
    }
}

// MARK: - Records

@MainActor
@Suite struct RecordTests {
    let store: LibraryStore
    init() throws { store = try LibraryStore.ephemeral() }

    @Test func uniquenessAndThrowingCases() throws {
        let book = try makeBook(in: store)
        let first = Note(bookID: book.id, target: .page(3), text: "a")
        try store.notes.save(first)
        #expect(throws: RepositoryError.noteTargetOccupied(existingNoteID: first.id)) {
            try store.notes.save(Note(bookID: book.id, target: .page(3), text: "b"))
        }
        // The original row is untouched by the failed save.
        #expect(try store.notes.note(bookID: book.id, target: .page(3))?.text == "a")
        #expect(try store.notes.noteCount(bookID: book.id) == 1)
        var moved = first
        moved.target = .page(9)
        #expect(throws: RepositoryError.noteTargetMismatch(noteID: first.id)) { try store.notes.save(moved) }
        let other = Note(bookID: book.id, target: .page(4), text: "c")
        try store.notes.save(other)
        #expect(throws: RepositoryError.noteTargetOccupied(existingNoteID: first.id)) {
            try store.notes.retarget(noteID: other.id, to: .page(3))
        }
        #expect(throws: RepositoryError.notFound(moved.id == first.id ? UUID(uuidString: "11111111-1111-1111-1111-111111111111")! : first.id)) {
            try store.notes.retarget(noteID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, to: .page(1))
        }
        #expect(try store.notes.noteCount(bookID: book.id) == 2)
        // Retarget frees the old key and updates page-range queries.
        try store.notes.retarget(noteID: first.id, to: .page(50))
        #expect(try store.notes.pageNotes(bookID: book.id, in: 0...10).map(\.id) == [other.id])
        #expect(try store.notes.pageNotes(bookID: book.id, in: 50...50).map(\.id) == [first.id])
        try store.notes.save(Note(bookID: book.id, target: .page(3), text: "reuse"))
    }

    @Test func sameTargetInDifferentBooks() throws {
        let a = try makeBook(in: store), b = try makeBook(in: store)
        try store.notes.save(Note(bookID: a.id, target: .page(1), text: "a"))
        try store.notes.save(Note(bookID: b.id, target: .page(1), text: "b"))
        try store.bookmarks.setBookmarked(true, bookID: a.id, pageIndex: 1)
        try store.bookmarks.setBookmarked(true, bookID: b.id, pageIndex: 1)
        #expect(try store.notes.note(bookID: a.id, target: .page(1))?.text == "a")
        #expect(try store.notes.note(bookID: b.id, target: .page(1))?.text == "b")
        #expect(try store.bookmarks.bookmarks(bookID: a.id).count == 1)
    }

    @Test func unknownBookErrors() throws {
        let ghost = UUID()
        #expect(throws: RepositoryError.bookNotFound(ghost)) {
            try store.highlights.save(Highlight(bookID: ghost, pageIndex: 0, rects: [], color: .blue, text: "x"))
        }
        #expect(throws: RepositoryError.bookNotFound(ghost)) { try store.bookmarks.setBookmarked(true, bookID: ghost, pageIndex: 0) }
        #expect(throws: RepositoryError.bookNotFound(ghost)) {
            try store.headings.save(UserHeading(bookID: ghost, title: "t", pageIndex: 0, parent: nil))
        }
        try store.bookmarks.setBookmarked(false, bookID: ghost, pageIndex: 0)
    }

    @Test func roundTripEveryField() throws {
        var book = Book(title: "Ünïcödé / Title 数学", fingerprint: "fp", fileName: "a b.pdf", pageCount: 812,
                        fileSize: Int64.max - 5, addedAt: Date(timeIntervalSince1970: 123.456),
                        lastOpenedAt: Date(timeIntervalSince1970: 999.5), lastReadPageIndex: 77)
        try store.books.save(book)
        #expect(try store.books.book(id: book.id) == book)
        book.lastOpenedAt = nil
        try store.books.save(book)
        #expect(try store.books.book(id: book.id) == book)

        let odd = HeadingAnchor(pdfPath: [3, 0, 12], pageIndex: 40, title: "Cats/Dogs: 5/6 – naïve 😀 \\ done")
        let layout = NoteBandLayout(pageWidth: 612.25, paragraphs: [NoteParagraphBand(text: "p1", top: 0.1, height: 20.3),
                                                                     NoteParagraphBand(text: "", top: 20.4, height: 18)], trailingTop: 38.4)
        let note = Note(bookID: book.id, target: .heading(odd), text: "line1\nline2 😀", hasInk: true, bandLayout: layout,
                        createdAt: Date(timeIntervalSince1970: 5.25), modifiedAt: Date(timeIntervalSince1970: 9.75))
        try store.notes.save(note)
        #expect(try store.notes.note(id: note.id) == note)
        #expect(try store.notes.note(bookID: book.id, target: .heading(odd)) == note)
        #expect(try store.notes.notes(bookID: book.id) == [note])
        #expect(try store.notes.pageNotes(bookID: book.id, in: 0...100_000).isEmpty)

        let h = Highlight(bookID: book.id, pageIndex: 5,
                          rects: [CGRect(x: 10.123456789, y: 700.5, width: 99.9, height: 11.1), CGRect(x: 1, y: 2, width: 3, height: 4)],
                          color: .pink, text: "txt \"q\" 😀", createdAt: Date(timeIntervalSince1970: 77.7))
        try store.highlights.save(h)
        #expect(try store.highlights.highlight(id: h.id) == h)
        let noRects = Highlight(bookID: book.id, pageIndex: 5, rects: [], color: .green, text: "none")
        try store.highlights.save(noRects)
        #expect(try store.highlights.highlights(bookID: book.id, pageIndex: 5).map(\.id) == [h.id, noRects.id])
        #expect(try store.highlights.highlight(id: noRects.id) == noRects)

        let parentUser = UserHeading(bookID: book.id, title: "Mine", pageIndex: 3, parent: nil)
        let child = UserHeading(bookID: book.id, title: "A/B ü", pageIndex: 4, parent: parentUser.anchor)
        let pdfChild = UserHeading(bookID: book.id, title: "C", pageIndex: 4, parent: odd, createdAt: Date(timeIntervalSince1970: 3))
        for u in [parentUser, child, pdfChild] { try store.headings.save(u) }
        #expect(try store.headings.userHeading(id: child.id) == child)
        #expect(try store.headings.userHeading(id: pdfChild.id) == pdfChild)
        #expect(Set(try store.headings.userHeadings(bookID: book.id)) == [parentUser, child, pdfChild])
    }

    @Test func highlightReadingOrderMatchesContract() throws {
        let book = try makeBook(in: store)
        var generator = SystemRandomNumberGenerator()
        let sameDate = Date(timeIntervalSince1970: 500)
        var all: [Highlight] = []
        for i in 0..<300 {
            let page = Int.random(in: 0..<4, using: &generator)
            let rects: [CGRect] = Int.random(in: 0..<8, using: &generator) == 0 ? [] :
                [CGRect(x: Double(Int.random(in: 0..<4, using: &generator) * 50), y: Double(Int.random(in: 0..<4, using: &generator) * 100),
                        width: 40, height: 10)]
            all.append(Highlight(bookID: book.id, pageIndex: page, rects: rects, color: .yellow, text: "h\(i)",
                                 createdAt: i % 2 == 0 ? sameDate : Date(timeIntervalSince1970: Double(i))))
        }
        for h in all { try store.highlights.save(h) }
        let got = try store.highlights.highlights(bookID: book.id), want = all.sorted(by: Highlight.readingOrder)
        if let i = got.indices.first(where: { got[$0] != want[$0] }) {
            Issue.record("first mismatch at \(i): got \(got[i].pageIndex) \(got[i].bounds) \(got[i].createdAt) \(got[i].id), want \(want[i].pageIndex) \(want[i].bounds) \(want[i].createdAt) \(want[i].id)")
        }
        #expect(try store.highlights.highlights(bookID: book.id) == all.sorted(by: Highlight.readingOrder))
        #expect(try store.highlights.highlights(bookID: book.id, in: 1...2) == all.filter { (1...2).contains($0.pageIndex) }.sorted(by: Highlight.readingOrder))
        #expect(try store.highlights.highlights(bookID: book.id, pageIndex: 3) == all.filter { $0.pageIndex == 3 }.sorted(by: Highlight.readingOrder))
        // Moving a highlight to another page and back updates the queries.
        var moved = all[0]
        moved.pageIndex = 10
        try store.highlights.save(moved)
        #expect(try store.highlights.highlights(bookID: book.id, pageIndex: 10).map(\.id) == [moved.id])
        #expect(try store.highlights.highlightCount(bookID: book.id) == 300)
    }

    @Test func bookmarksAreIdempotentAndSorted() throws {
        let book = try makeBook(in: store)
        for p in [9, 2, 2, 5] { try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: p) }
        let first = try store.bookmarks.bookmarks(bookID: book.id)
        #expect(first.map(\.pageIndex) == [2, 5, 9])
        try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 2)
        #expect(try store.bookmarks.bookmarks(bookID: book.id) == first)
        try store.bookmarks.setBookmarked(false, bookID: book.id, pageIndex: 5)
        try store.bookmarks.setBookmarked(false, bookID: book.id, pageIndex: 5)
        #expect(try store.bookmarks.bookmarks(bookID: book.id).map(\.pageIndex) == [2, 9])
        try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 5)
        #expect(try store.bookmarks.isBookmarked(bookID: book.id, pageIndex: 5))
    }

    @Test func cascadeDeleteLeavesOtherBooksAlone() async throws {
        let a = try makeBook(in: store), b = try makeBook(in: store)
        for book in [a, b] {
            try store.notes.save(Note(bookID: book.id, target: .page(1), text: "n"))
            try store.notes.save(Note(bookID: book.id, target: .heading(HeadingAnchor(pdfPath: [0], pageIndex: 0, title: "H")), text: "n"))
            try store.highlights.save(Highlight(bookID: book.id, pageIndex: 1, rects: [], color: .blue, text: "x"))
            try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 3)
            try store.headings.save(UserHeading(bookID: book.id, title: "u", pageIndex: 2, parent: nil))
        }
        try await store.savePageInk(Data([1]), bookID: a.id, pageIndex: 1, origin: nil)
        try await store.savePageInk(Data([1]), bookID: a.id, pageIndex: 7, origin: nil)
        let summary = try await store.deletionSummary(bookID: a.id)
        #expect(summary.records == BookRecordCounts(notes: 2, highlights: 1, bookmarks: 1, userHeadings: 1))
        #expect(summary.inkedPages == 2)
        try await store.deleteBook(id: a.id, origin: nil)
        #expect(try store.books.book(id: a.id) == nil)
        #expect(try store.books.recordCounts(bookID: a.id) == BookRecordCounts())
        #expect(try store.books.recordCounts(bookID: b.id) == BookRecordCounts(notes: 2, highlights: 1, bookmarks: 1, userHeadings: 1))
        #expect(!FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: a.id).path))
        #expect(try await store.inkedPageIndices(bookID: a.id).isEmpty)
        try await store.deleteBook(id: a.id, origin: nil)
    }

    /// The ownership check runs in chunks of IDs; a foreign ID past the first chunk is still found,
    /// and a large archive goes in whole.
    @Test func replaceBookWithManyRecords() throws {
        let book = try makeBook(in: store), other = try makeBook(in: store)
        let foreign = Highlight(bookID: other.id, pageIndex: 0, rects: [], color: .blue, text: "theirs")
        try store.highlights.save(foreign)
        var archive = BookArchive(book: book)
        archive.highlights = (0..<1_200).map {
            Highlight(bookID: book.id, pageIndex: $0 % 50, rects: [CGRect(x: 0, y: Double($0), width: 5, height: 5)], color: .yellow, text: "\($0)")
        }
        archive.notes = (0..<700).map { Note(bookID: book.id, target: .page($0), text: "n\($0)") }
        var clash = archive
        clash.highlights[1_100] = Highlight(id: foreign.id, bookID: book.id, pageIndex: 1, rects: [], color: .blue, text: "stolen")
        #expect(throws: RepositoryError.recordOwnedByOtherBook(recordID: foreign.id, bookID: other.id)) {
            try store.books.replaceBook(clash, removing: [])
        }
        #expect(try store.books.recordCounts(bookID: book.id) == BookRecordCounts())
        try store.books.replaceBook(archive, removing: [])
        #expect(try store.books.recordCounts(bookID: book.id) == BookRecordCounts(notes: 700, highlights: 1_200))
        #expect(try store.highlights.highlights(bookID: book.id) == archive.highlights.sorted(by: Highlight.readingOrder))
        #expect(try store.highlights.highlight(id: foreign.id)?.bookID == other.id)
    }

    @Test func deleteNoteRemovesInk() async throws {
        let book = try makeBook(in: store)
        let note = Note(bookID: book.id, target: .page(1), text: "", hasInk: true)
        try store.notes.save(note)
        try await store.saveNoteInk(Data([1, 2]), bookID: book.id, noteID: note.id, origin: nil)
        try await store.deleteNote(id: note.id, origin: nil)
        #expect(try store.notes.note(id: note.id) == nil)
        #expect(try await store.noteInk(bookID: book.id, noteID: note.id) == nil)
    }

    @Test func twoOriginsSeeEachOther() throws {
        let book = try makeBook(in: store)
        let a = ChangeOrigin(label: "A"), b = ChangeOrigin(label: "B")
        var seenByA: [StoreChangeEvent] = [], seenByB: [StoreChangeEvent] = []
        let tokenA = store.hub.observe { seenByA.append($0) }
        let tokenB = store.hub.observe { seenByB.append($0) }
        let noteA = Note(bookID: book.id, target: .page(2), text: "x")
        _ = try store.perform(as: a) { try store.notes.save(noteA) }
        _ = try store.perform(as: b) { try store.highlights.save(Highlight(bookID: book.id, pageIndex: 2, rects: [], color: .blue, text: "x")) }
        _ = try? store.notes.save(Note(bookID: book.id, target: .page(2), text: "clash"))   // throws: posts nothing
        for seen in [seenByA, seenByB] {
            #expect(seen.count == 2)
            #expect(seen.first?.change == .noteSaved(bookID: book.id, target: .page(2), noteID: noteA.id))
            #expect(seen.first?.isFrom(a) == true)
            #expect(seen.last?.change == .highlightsChanged(bookID: book.id, pageIndex: 2))
            #expect(seen.last?.isFrom(b) == true)
        }
        withExtendedLifetime((tokenA, tokenB)) {}
    }
}

// MARK: - Persistence, reset, sweep

@MainActor
@Suite struct PersistenceTests {
    @Test func survivesReopen() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let book = Book(title: "Persist", fingerprint: "fp", fileName: "p.pdf", pageCount: 10, fileSize: 1)
        let note = Note(bookID: book.id, target: .page(2), text: "kept")
        let hl = Highlight(bookID: book.id, pageIndex: 1, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)], color: .green, text: "hl")
        do {
            let store = try LibraryStore.live(rootDirectory: root.url)
            try store.books.save(book)
            try store.notes.save(note)
            try store.highlights.save(hl)
            try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 4)
            try await store.savePageInk(Data([7, 7]), bookID: book.id, pageIndex: 3, origin: nil)
        }
        let again = try LibraryStore.live(rootDirectory: root.url)
        #expect(try again.books.book(id: book.id) == book)
        #expect(try again.notes.note(id: note.id) == note)
        #expect(try again.highlights.highlights(bookID: book.id) == [hl])
        #expect(try again.bookmarks.isBookmarked(bookID: book.id, pageIndex: 4))
        #expect(try await again.pageInk(bookID: book.id, pageIndex: 3) == Data([7, 7]))
        // The store file lives inside the root.
        let db = root.url.appendingPathComponent("Database/Marginal.store")
        #expect(FileManager.default.fileExists(atPath: db.path))
    }

    /// `replaceBook` on the on-disk store: rows deleted and re-inserted with the same IDs, a
    /// freed note target and bookmark page reused in the same save, all as expected after reopen.
    @Test func replaceBookSurvivesReopen() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let date = Date(timeIntervalSince1970: 1_650_000_000.375)
        let book = Book(title: "Replace", fingerprint: "fp-replace", fileName: "r.pdf", pageCount: 100, fileSize: 9, addedAt: date)
        let other = Book(title: "Other", fingerprint: "fp-other", fileName: "o.pdf", pageCount: 10, fileSize: 1, addedAt: date)
        let replacement: BookArchive
        do {
            let store = try LibraryStore.live(rootDirectory: root.url)
            try store.books.save(book)
            try store.books.save(other)
            try store.notes.save(Note(bookID: other.id, target: .page(1), text: "other"))
            let kept = Note(bookID: book.id, target: .page(1), text: "kept", createdAt: date, modifiedAt: date)
            try store.notes.save(kept)
            try store.notes.save(Note(bookID: book.id, target: .page(2), text: "dropped"))
            try store.highlights.save(Highlight(bookID: book.id, pageIndex: 3, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                                color: .green, text: "h", createdAt: date))
            try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 4)
            var archive = try #require(try store.archive(bookID: book.id))
            archive.book.title = "Restored"
            archive.notes = [Note(id: kept.id, bookID: book.id, target: .page(1), text: "kept, edited", createdAt: date, modifiedAt: date),
                             Note(bookID: book.id, target: .page(2), text: "new on 2", createdAt: date, modifiedAt: date)]
            archive.highlights[0].pageIndex = 30
            archive.bookmarks = [Bookmark(bookID: book.id, pageIndex: 4, createdAt: date)]
            archive.userHeadings = [UserHeading(bookID: book.id, title: "U", pageIndex: 5, parent: nil, createdAt: date)]
            try store.books.replaceBook(archive, removing: [])
            try store.books.replaceBook(archive, removing: [])
            replacement = archive
        }
        let again = try LibraryStore.live(rootDirectory: root.url)
        let restored = try #require(try again.archive(bookID: book.id))
        #expect(restored.book == replacement.book)
        #expect(Set(restored.notes) == Set(replacement.notes))
        #expect(restored.highlights == replacement.highlights)
        #expect(restored.bookmarks == replacement.bookmarks)
        #expect(restored.userHeadings == replacement.userHeadings)
        #expect(try again.books.recordCounts(bookID: book.id) == BookRecordCounts(notes: 2, highlights: 1, bookmarks: 1, userHeadings: 1))
        #expect(try again.notes.note(bookID: book.id, target: .page(2))?.text == "new on 2")
        #expect(try again.highlights.highlights(bookID: book.id, pageIndex: 30).count == 1)
        #expect(try again.highlights.highlights(bookID: book.id, pageIndex: 3).isEmpty)
        #expect(try again.books.allBooks().count == 2)
        #expect(try again.notes.notes(bookID: other.id).map(\.text) == ["other"])
    }

    @Test func convertedBookFieldsSurviveReopen() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let converted = Book(title: "Converted", fingerprint: "fp-epub", fileName: "Converted.pdf", pageCount: 12,
                             fileSize: 9, sourceFormat: .epub, originalFileName: "Converted.epub", converterVersion: 3)
        let native = Book(title: "Native", fingerprint: "fp-pdf", fileName: "Native.pdf", pageCount: 2, fileSize: 1)
        do {
            let store = try LibraryStore.live(rootDirectory: root.url)
            try store.books.save(converted)
            try store.books.save(native)
        }
        let again = try LibraryStore.live(rootDirectory: root.url)
        #expect(try again.books.book(id: converted.id) == converted)
        #expect(try again.books.book(id: converted.id)?.isConverted == true)
        #expect(try again.books.book(id: native.id) == native)
        #expect(try again.books.book(id: native.id)?.isConverted == false)
        // Updating an existing row writes the new fields too.
        var changed = native
        changed.sourceFormat = .markdown
        changed.originalFileName = "notes.md"
        changed.converterVersion = 1
        try again.books.save(changed)
        #expect(try again.books.book(id: native.id) == changed)
    }

    @Test func resetWipesEverythingEvenWithJunk() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let book = Book(title: "Gone", fingerprint: "fp", fileName: "p.pdf", pageCount: 10, fileSize: 1)
        do {
            let store = try LibraryStore.live(rootDirectory: root.url)
            try store.books.save(book)
            try await store.savePageInk(Data([1]), bookID: book.id, pageIndex: 0, origin: nil)
        }
        // Leftovers a crashed run could leave behind.
        let junk = root.url.appendingPathComponent("Books/\(UUID().uuidString)/ink", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data([1]).write(to: junk.appendingPathComponent("0.drawing"))
        try Data([1]).write(to: root.url.appendingPathComponent("Database/Marginal.store-wal"))

        for _ in 0..<2 {
            let fresh = try LibraryStore.live(rootDirectory: root.url, reset: true)
            #expect(try fresh.books.allBooks().isEmpty)
            #expect(try await fresh.inkedPageIndices(bookID: book.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Books").path))
        }
        // reset on a root that does not exist yet.
        let missing = root.url.appendingPathComponent("nested/new")
        _ = try LibraryStore.live(rootDirectory: missing, reset: true)
    }

    @Test func orphanSweep() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try LibraryStore.live(rootDirectory: root.url)
        let kept = try makeBook(in: store)
        try await store.savePageInk(Data([1]), bookID: kept.id, pageIndex: 0, origin: nil)
        let orphan = UUID()
        try await store.savePageInk(Data([1]), bookID: orphan, pageIndex: 0, origin: nil)
        let stray = root.url.appendingPathComponent("Books/not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        #expect(try await store.sweepOrphanedBookDirectories() == [orphan])
        #expect(!FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: orphan).path))
        #expect(FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: kept.id).path))
        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(try await store.sweepOrphanedBookDirectories().isEmpty)
        // No Books directory at all is fine.
        let empty = try LibraryStore.ephemeral()
        #expect(try await empty.sweepOrphanedBookDirectories().isEmpty)
    }
}

// MARK: - File ink store

@Suite struct FileInkStoreTests {
    @Test func layoutIdempotenceAndEmptyData() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let ink = FileInkStore(rootDirectory: root.url)
        let book = UUID(), note = UUID()
        for p in [100, 3, 25, 4] { try await ink.savePageInk(Data([UInt8(p)]), bookID: book, pageIndex: p) }
        #expect(try await ink.inkedPageIndices(bookID: book) == [3, 4, 25, 100])
        let path = root.url.appendingPathComponent(BookStorageLayout.pageInkPath(bookID: book, pageIndex: 25))
        #expect(FileManager.default.fileExists(atPath: path.path))
        try await ink.saveNoteInk(Data([1]), bookID: book, noteID: note)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(BookStorageLayout.noteInkPath(bookID: book, noteID: note)).path))
        // Foreign files in ink/ are ignored.
        try Data([1]).write(to: path.deletingLastPathComponent().appendingPathComponent("junk.txt"))
        #expect(try await ink.inkedPageIndices(bookID: book) == [3, 4, 25, 100])
        // Empty drawing is never stored: it deletes.
        try await ink.savePageInk(Data(), bookID: book, pageIndex: 25)
        #expect(try await ink.pageInk(bookID: book, pageIndex: 25) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try await ink.saveNoteInk(Data(), bookID: book, noteID: UUID())
        // A zero-length file left behind reads as no ink.
        let zero = path.deletingLastPathComponent().appendingPathComponent("9.drawing")
        try Data().write(to: zero)
        #expect(try await ink.pageInk(bookID: book, pageIndex: 9) == nil)
        // removeBook removes extra files too, and is idempotent.
        let pdf = root.url.appendingPathComponent(BookStorageLayout.documentPath(bookID: book, fileName: "x.pdf"))
        try Data([1]).write(to: pdf)
        try await ink.removeBook(bookID: book)
        try await ink.removeBook(bookID: book)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: book)).path))
        #expect(try await ink.pageInk(bookID: book, pageIndex: 3) == nil)
        try await ink.deletePageInk(bookID: book, pageIndex: 3)
        try await ink.deleteNoteInk(bookID: book, noteID: note)
    }

    @Test func atomicReplaceAndConcurrentReads() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let ink = FileInkStore(rootDirectory: root.url)
        let book = UUID()
        let small = Data(repeating: 1, count: 1_000), big = Data(repeating: 2, count: 2_000_000)
        try await ink.savePageInk(small, bookID: book, pageIndex: 0)
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await ink.savePageInk(big, bookID: book, pageIndex: 0); return nil }
            for _ in 0..<20 { group.addTask { try await ink.pageInk(bookID: book, pageIndex: 0) } }
            for try await result in group {
                if let result { #expect(result == small || result == big) }
            }
        }
        #expect(try await ink.pageInk(bookID: book, pageIndex: 0) == big)
        // No temp files left in the directory.
        let dir = root.url.appendingPathComponent(BookStorageLayout.pageInkDirectory(bookID: book))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["0.drawing"])
    }
}

// MARK: - Scale

@MainActor
@Suite struct ScaleTests {
    @Test func fiveThousandHighlightsTwoThousandNotes() throws {
        let container = try SchemaFactory.makeContainer(storeURL: nil)
        let records = SwiftDataRecordStore(container: container)
        let root = TempRoot(); defer { root.cleanup() }
        let store = LibraryStore(records: records, inkStore: FileInkStore(rootDirectory: root.url), rootDirectory: root.url)
        let book = try makeBook(in: store, pageCount: 2000)
        let other = try makeBook(in: store, pageCount: 10)
        try store.highlights.save(Highlight(bookID: other.id, pageIndex: 5, rects: [], color: .blue, text: "other"))
        // Bulk-insert through the container to keep setup fast; the repository is what is measured.
        let context = container.mainContext
        for i in 0..<5000 {
            context.insert(HighlightModel(id: UUID(), bookID: book.id, pageIndex: i % 2000,
                                          rectsData: try JSONEncoder().encode([CGRect(x: 10, y: Double(i % 700), width: 50, height: 10)]),
                                          colorRaw: "yellow", text: "highlight \(i)", createdAt: Date(timeIntervalSince1970: Double(i)),
                                          sortRank: 0, sortMaxY: Double(i % 700) + 10, sortMinX: 10))
        }
        for i in 0..<2000 {
            context.insert(NoteModel(id: UUID(), bookID: book.id, targetKey: "page:\(i)", pageIndex: i, text: "note \(i)",
                                     hasInk: false, bandLayoutData: nil, createdAt: Date(), modifiedAt: Date()))
        }
        try context.save()

        let clock = ContinuousClock()
        var mark = clock.now
        do {
            for page in stride(from: 0, to: 2000, by: 97) {
                #expect(try store.highlights.highlights(bookID: book.id, pageIndex: page).count >= 2)
                #expect(try store.notes.note(bookID: book.id, target: .page(page))?.text == "note \(page)")
            }
            #expect(try store.highlights.highlights(bookID: book.id, in: 100...199).count == 300)
            #expect(try store.notes.pageNotes(bookID: book.id, in: 100...199).count == 100)
            #expect(try store.highlights.highlightCount(bookID: book.id) == 5000)
            #expect(try store.notes.noteCount(bookID: book.id) == 2000)
            #expect(try store.books.recordCounts(bookID: book.id).highlights == 5000)
        }
        let elapsed = clock.now - mark
        #expect(elapsed < .seconds(3), "queries took \(elapsed)")
        mark = clock.now
        _ = try store.highlights.highlights(bookID: book.id)
        let all = clock.now - mark
        #expect(all < .seconds(5), "full-book fetch took \(all)")
        // A single save in a big book stays cheap.
        mark = clock.now
        var edit = try #require(try store.notes.note(bookID: book.id, target: .page(1999)))
        edit.text = "edited"
        try store.notes.save(edit)
        let single = clock.now - mark
        #expect(single < .seconds(1))
    }
}

// MARK: - Migration

@MainActor
@Suite struct MigrationTests {
    /// A store written by version 1 opens as version 2: every record is kept and the new book
    /// fields read as `nil`. Then a converted book can be saved into the migrated store.
    @Test func versionOneStoreOpensAsVersionTwo() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let storeURL = root.url.appendingPathComponent("Marginal.store")
        let book = Book(title: "Old", fingerprint: "fp-old", fileName: "old.pdf", pageCount: 40, fileSize: 123,
                        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_500), lastReadPageIndex: 7)
        let noteID = UUID()
        do {
            let schema = Schema(versionedSchema: MarginalSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            let context = ModelContext(container)
            context.insert(MarginalSchemaV1.BookModel(book))
            context.insert(MarginalSchemaV1.NoteModel(id: noteID, bookID: book.id, targetKey: NoteTarget.page(3).storageKey,
                                                      pageIndex: 3, text: "kept", hasInk: false, bandLayoutData: nil,
                                                      createdAt: book.addedAt, modifiedAt: book.addedAt))
            context.insert(MarginalSchemaV1.BookmarkModel(id: UUID(), bookID: book.id, pageIndex: 5, createdAt: book.addedAt))
            try context.save()
        }

        let store = SwiftDataRecordStore(container: try SchemaFactory.makeContainer(storeURL: storeURL))
        let migrated = try #require(try store.book(id: book.id))
        #expect(migrated == book)
        #expect(migrated.sourceFormat == nil)
        #expect(migrated.originalFileName == nil)
        #expect(migrated.converterVersion == nil)
        #expect(try store.note(id: noteID)?.text == "kept")
        #expect(try store.isBookmarked(bookID: book.id, pageIndex: 5))

        let converted = Book(title: "New", fingerprint: "fp-new", fileName: "new.pdf", pageCount: 3, fileSize: 1,
                             sourceFormat: .comicArchive, originalFileName: "new.cbz", converterVersion: 1)
        try store.save(converted)
        #expect(try store.book(fingerprint: "fp-new") == converted)
        #expect(try store.allBooks().count == 2)
    }

    /// A format name this build does not know (written by a newer build) reads as "not converted"
    /// instead of failing the whole Library.
    @Test func unknownSourceFormatReadsAsNil() throws {
        let container = try SchemaFactory.makeContainer(storeURL: nil)
        let book = Book(title: "B", fingerprint: "f", fileName: "b.pdf", pageCount: 1, fileSize: 1)
        let model = BookModel(book)
        model.sourceFormatRaw = "hologram"
        let context = ModelContext(container)
        context.insert(model)
        try context.save()
        #expect(try SwiftDataRecordStore(container: container).book(id: book.id)?.sourceFormat == nil)
    }
}
