import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

@Suite("Model values")
struct ModelTests {
    @Test func pageNumbering() {
        #expect(PageNumbering.displayNumber(forPageIndex: 311) == 312)
        #expect(PageNumbering.pageIndex(forDisplayNumber: 312) == 311)
        #expect(PageNumbering.isValid(0, pageCount: 1) && !PageNumbering.isValid(1, pageCount: 1) && !PageNumbering.isValid(-1, pageCount: 5))
        #expect(PageNumbering.label(forPageIndex: 0) == "p. 1")
        #expect(PageNumbering.label(forPageRange: 300...339) == "pp. 301\u{2013}340")
        #expect(PageNumbering.label(forPageRange: 4...4) == "p. 5")
    }

    @Test func noteTargetStorageKeys() throws {
        let anchor = HeadingAnchor(pdfPath: [1, 2], pageIndex: 40, title: "A: b/c")
        #expect(NoteTarget.page(311).storageKey == "page:311")
        #expect(NoteTarget.heading(anchor).storageKey == "heading:pdf1/1.2/40/A: b/c")
        for target in [NoteTarget.page(0), .page(311), .heading(anchor), .heading(HeadingAnchor(userHeadingID: uuid(5)))] {
            #expect(NoteTarget(storageKey: target.storageKey) == target)
            let data = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(NoteTarget.self, from: data) == target)
        }
        for bad in ["page:", "page:-1", "page:x", "heading:junk", "other:1"] { #expect(NoteTarget(storageKey: bad) == nil) }
    }

    @Test func noteEmptinessRule() {
        #expect(Note(bookID: bookA, target: .page(1), text: "  \n\t").isEmpty)
        #expect(!Note(bookID: bookA, target: .page(1), text: "x").isEmpty)
        #expect(!Note(bookID: bookA, target: .page(1), text: "", hasInk: true).isEmpty)
        #expect(Note(bookID: bookA, target: .page(1), createdAt: fixedDate).modifiedAt == fixedDate)
    }

    @Test func recordsRoundTripThroughJSON() throws {
        let note = Note(id: uuid(1), bookID: bookA, target: .page(2), text: "t", hasInk: true,
                        bandLayout: layout([("t", 20)]), createdAt: fixedDate)
        let highlight = Highlight(id: uuid(2), bookID: bookA, pageIndex: 3, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                  color: .pink, text: "quoted", createdAt: fixedDate)
        let heading = UserHeading(id: uuid(3), bookID: bookA, title: "Mine", pageIndex: 4,
                                  parent: HeadingAnchor(pdfPath: [0], pageIndex: 1, title: "Ch"), createdAt: fixedDate)
        let book = Book(id: bookA, title: "Book", fingerprint: "abc", fileName: "b.pdf", pageCount: 10, fileSize: 99, addedAt: fixedDate)
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note)) == note)
        #expect(try JSONDecoder().decode(Highlight.self, from: JSONEncoder().encode(highlight)) == highlight)
        #expect(try JSONDecoder().decode(UserHeading.self, from: JSONEncoder().encode(heading)) == heading)
        #expect(try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book)) == book)
        #expect(HighlightColor.allCases.map(\.rawValue) == ["yellow", "green", "blue", "pink"])
    }

    @Test func bookProgress() {
        var book = Book(title: "B", fingerprint: "f", fileName: "b.pdf", pageCount: 4, fileSize: 1)
        #expect(book.progress == 0.25)
        book.lastReadPageIndex = 3
        #expect(book.progress == 1)
        book.pageCount = 0
        #expect(book.progress == 0)
    }

    @Test func highlightReadingOrder() {
        func h(_ n: Int, page: Int, x: CGFloat, y: CGFloat) -> Highlight {
            Highlight(id: uuid(n), bookID: bookA, pageIndex: page, rects: [CGRect(x: x, y: y, width: 10, height: 10)],
                      color: .yellow, text: "\(n)", createdAt: fixedDate)
        }
        let unsorted = [h(1, page: 2, x: 0, y: 700), h(2, page: 1, x: 0, y: 100), h(3, page: 1, x: 50, y: 500),
                        h(4, page: 1, x: 10, y: 500),
                        Highlight(id: uuid(5), bookID: bookA, pageIndex: 1, rects: [], color: .blue, text: "5", createdAt: fixedDate)]
        #expect(unsorted.sorted(by: Highlight.readingOrder).map(\.text) == ["4", "3", "2", "5", "1"])
    }

    @Test func storageLayoutPaths() {
        let book = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(BookStorageLayout.pageInkPath(bookID: book, pageIndex: 311) == "Books/11111111-2222-3333-4444-555555555555/ink/311.drawing")
        #expect(BookStorageLayout.noteInkPath(bookID: book, noteID: book) == "Books/11111111-2222-3333-4444-555555555555/notes/11111111-2222-3333-4444-555555555555.drawing")
        #expect(BookStorageLayout.documentPath(bookID: book, fileName: "x.pdf") == "Books/11111111-2222-3333-4444-555555555555/x.pdf")
        #expect(BookStorageLayout.pageIndex(fromPageInkFileName: "311.drawing") == 311)
        #expect(BookStorageLayout.pageIndex(fromPageInkFileName: "x.drawing") == nil)
        #expect(BookStorageLayout.pageIndex(fromPageInkFileName: "3.png") == nil)
    }
}

@Suite("Store contracts")
struct StoreContractTests {
    @Test @MainActor func inMemoryRecordStoreConforms() throws {
        let store = InMemoryRecordStore()
        try RepositoryConformance.verifyRecordStores(books: store, notes: store, highlights: store, bookmarks: store, headings: store)
        #expect(try store.allBooks().isEmpty)   // the check cleans up after itself
    }

    @Test func inMemoryInkStoreConforms() async throws {
        try await RepositoryConformance.verifyInkStore(InMemoryInkStore())
    }

    @Test @MainActor func conformanceCatchesABrokenStore() throws {
        /// Stores empty notes instead of deleting them.
        @MainActor final class Leaky: NoteRepository {
            let inner = InMemoryRecordStore()
            func note(bookID: UUID, target: NoteTarget) throws -> Note? { try inner.note(bookID: bookID, target: target) }
            func note(id: UUID) throws -> Note? { try inner.note(id: id) }
            func notes(bookID: UUID) throws -> [Note] { try inner.notes(bookID: bookID) }
            func pageNotes(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Note] { try inner.pageNotes(bookID: bookID, in: pages) }
            func save(_ note: Note) throws -> Note? {
                var copy = note
                if copy.isEmpty { copy.text = "kept" }
                return try inner.save(copy)
            }
            func deleteNote(id: UUID) throws { try inner.deleteNote(id: id) }
            func retarget(noteID: UUID, to target: NoteTarget) throws { try inner.retarget(noteID: noteID, to: target) }
            func noteCount(bookID: UUID) throws -> Int { try inner.noteCount(bookID: bookID) }
        }
        let leaky = Leaky()
        #expect(throws: RepositoryConformance.Failure.self) {
            try RepositoryConformance.verifyRecordStores(books: leaky.inner, notes: leaky, highlights: leaky.inner,
                                                         bookmarks: leaky.inner, headings: leaky.inner)
        }
    }

    @Test @MainActor func deletionSummaryCounts() async throws {
        let store = InMemoryRecordStore()
        let ink = InMemoryInkStore()
        try store.save(Book(id: bookA, title: "B", fingerprint: "f", fileName: "b.pdf", pageCount: 10, fileSize: 1))
        try store.save(Note(bookID: bookA, target: .page(1), text: "n"))
        try store.save(Highlight(bookID: bookA, pageIndex: 1, rects: [], color: .green, text: "h"))
        try await ink.savePageInk(Data([1]), bookID: bookA, pageIndex: 1)
        try await ink.savePageInk(Data([1]), bookID: bookA, pageIndex: 7)
        let summary = BookDeletionSummary(records: try store.recordCounts(bookID: bookA),
                                          inkedPages: try await ink.inkedPageIndices(bookID: bookA).count)
        #expect(summary.notes == 1 && summary.highlights == 1 && summary.inkedPages == 2)
    }
}
