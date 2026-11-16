import Foundation
import CoreGraphics
import Testing
import ReaderCore
import ReaderStore

/// App-hosted checks of the persistence layer on a real iOS runtime (the deployment floor is
/// iOS 17; `swift test` only exercises SwiftData on the macOS host).
@MainActor
struct PersistenceFloorTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PersistenceFloor-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func conformanceOnDiskStore() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore.live(rootDirectory: root)
        try RepositoryConformance.verifyRecordStores(books: store.books, notes: store.notes, highlights: store.highlights,
                                                     bookmarks: store.bookmarks, headings: store.headings)
        try await RepositoryConformance.verifyInkStore(store.inkStore)
        try await RepositoryConformance.verifyChangePosting(store)
    }

    @Test func uniquenessThrowsAndReopenRoundTrips() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(title: "Floor / Ünï", fingerprint: "floor", fileName: "f.pdf", pageCount: 50, fileSize: 9)
        let note = Note(bookID: book.id, target: .heading(HeadingAnchor(pdfPath: [1, 2], pageIndex: 7, title: "A/B 数")), text: "kept",
                        hasInk: true,
                        bandLayout: NoteBandLayout(pageWidth: 600, paragraphs: [NoteParagraphBand(text: "kept", top: 0, height: 20)], trailingTop: 20))
        let pageNote = Note(bookID: book.id, target: .page(3), text: "p3")
        let highlights = (0..<6).map {
            Highlight(bookID: book.id, pageIndex: 2, rects: [CGRect(x: Double($0 % 3) * 10, y: Double($0 % 2) * 100, width: 5, height: 5)],
                      color: .pink, text: "h\($0)", createdAt: Date(timeIntervalSince1970: 100))
        }
        do {
            let store = try LibraryStore.live(rootDirectory: root)
            try store.books.save(book)
            try store.notes.save(note)
            try store.notes.save(pageNote)
            #expect(throws: RepositoryError.noteTargetOccupied(existingNoteID: pageNote.id)) {
                try store.notes.save(Note(bookID: book.id, target: .page(3), text: "dup"))
            }
            for h in highlights { try store.highlights.save(h) }
            try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 8)
            try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 8)
            try await store.savePageInk(Data([1, 2, 3]), bookID: book.id, pageIndex: 5, origin: nil)
        }
        let again = try LibraryStore.live(rootDirectory: root)
        #expect(try again.books.book(id: book.id) == book)
        #expect(try again.notes.note(id: note.id) == note)
        #expect(try again.notes.pageNotes(bookID: book.id, in: 0...10).map(\.id) == [pageNote.id])
        #expect(try again.notes.noteCount(bookID: book.id) == 2)
        #expect(try again.highlights.highlights(bookID: book.id) == highlights.sorted(by: Highlight.readingOrder))
        #expect(try again.highlights.highlights(bookID: book.id, in: 2...2).count == 6)
        #expect(try again.bookmarks.bookmarks(bookID: book.id).count == 1)
        #expect(try await again.pageInk(bookID: book.id, pageIndex: 5) == Data([1, 2, 3]))
        try await again.deleteBook(id: book.id, origin: nil)
        #expect(try again.books.recordCounts(bookID: book.id) == BookRecordCounts())

        let reset = try LibraryStore.live(rootDirectory: root, reset: true)
        #expect(try reset.books.allBooks().isEmpty)
        #expect(try await reset.sweepOrphanedBookDirectories().isEmpty)
    }
}
