import Foundation
import CoreGraphics

/// Executable contract checks for store implementations. WP2 calls these from its own tests
/// against the SwiftData repositories and the file-backed ink store; ReaderCore's tests run them
/// against the in-memory reference stores. Each check creates its own book with a fresh ID,
/// and removes everything it created, also when it fails.
public enum RepositoryConformance {
    /// A violated contract rule.
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    private static func expectError(_ expected: RepositoryError, _ label: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as RepositoryError {
            try check(error == expected, "\(label): expected \(expected), got \(error)")
            return
        }
        throw Failure(description: "\(label): expected \(expected), but no error was thrown")
    }

    /// Checks the record repositories together (pass the same object several times if one type
    /// implements them all). Covers: book save/fetch/fingerprint, note upsert by target, the
    /// empty-note rule, one note per target, retarget, page-note range queries, highlight order
    /// and range queries, idempotent bookmarks, user headings, counts, and cascade delete.
    @MainActor
    public static func verifyRecordStores(books: some BookRepository, notes: some NoteRepository,
                                          highlights: some HighlightRepository,
                                          bookmarks: some BookmarkRepository,
                                          headings: some HeadingRepository) throws {
        let bookID = UUID()
        let fingerprint = "conformance-\(bookID.uuidString)"
        defer { try? books.deleteBook(id: bookID) }

        // Books
        let book = Book(id: bookID, title: "Conformance", fingerprint: fingerprint, fileName: "c.pdf",
                        pageCount: 100, fileSize: 1234, addedAt: Date(timeIntervalSince1970: 1_000))
        try books.save(book)
        try check(try books.book(id: bookID) == book, "book(id:) must return the saved book")
        try check(try books.book(fingerprint: fingerprint)?.id == bookID, "book(fingerprint:) must find the book")
        var renamed = book
        renamed.title = "Renamed"
        try books.save(renamed)
        try check(try books.book(id: bookID)?.title == "Renamed", "save(book) must replace by id")
        try check(try books.allBooks().filter { $0.id == bookID }.count == 1, "allBooks must hold the book once")

        // Notes: upsert by target, one per target, empty rule
        let created = Date(timeIntervalSince1970: 2_000)
        let page3 = Note(bookID: bookID, target: .page(3), text: "first", createdAt: created)
        try check(try notes.save(page3) == page3, "save(new note) must return the note")
        try check(try notes.note(bookID: bookID, target: .page(3)) == page3, "note(target:) must find the saved note")
        try check(try notes.note(id: page3.id) == page3, "note(id:) must find the saved note")
        var edited = page3
        edited.text = "second"
        try notes.save(edited)
        try check(try notes.note(bookID: bookID, target: .page(3))?.text == "second", "save must update in place")
        try check(try notes.noteCount(bookID: bookID) == 1, "updating must not add a note")
        try expectError(.noteTargetOccupied(existingNoteID: page3.id), "second note for one target") {
            try notes.save(Note(bookID: bookID, target: .page(3), text: "other"))
        }
        var moved = edited
        moved.target = .page(4)
        try expectError(.noteTargetMismatch(noteID: page3.id), "save under another target") {
            try notes.save(moved)
        }
        var emptied = edited
        emptied.text = " \n "
        try check(try notes.save(emptied) == nil, "saving an empty note must return nil")
        try check(try notes.note(bookID: bookID, target: .page(3)) == nil, "saving an empty note must delete it")
        try check(try notes.save(Note(bookID: bookID, target: .page(5), text: "")) == nil, "an empty new note must not be stored")
        try check(try notes.noteCount(bookID: bookID) == 0, "no empty notes may be stored")
        var inkOnly = Note(bookID: bookID, target: .page(6), text: "", hasInk: true)
        inkOnly.bandLayout = NoteBandLayout(pageWidth: 320, paragraphs: [NoteParagraphBand(text: "", top: 0, height: 20)], trailingTop: 20)
        try check(try notes.save(inkOnly) == inkOnly, "a note with ink and no text is not empty")
        try check(try notes.note(id: inkOnly.id)?.bandLayout == inkOnly.bandLayout, "bandLayout must round-trip")

        let anchor = HeadingAnchor(pdfPath: [0, 1], pageIndex: 10, title: "1.2 Something")
        let headingNote = Note(bookID: bookID, target: .heading(anchor), text: "section")
        try notes.save(headingNote)
        try notes.save(Note(bookID: bookID, target: .page(20), text: "twenty"))
        try notes.save(Note(bookID: bookID, target: .page(2), text: "two"))
        let inRange = try notes.pageNotes(bookID: bookID, in: 2...6)
        try check(inRange.compactMap(\.target.pageIndex) == [2, 6], "pageNotes(in:) must filter page notes and sort by page, got \(inRange.map(\.target))")
        try check(try notes.notes(bookID: bookID).count == 4, "notes(bookID:) must return page and heading notes")

        // Retarget
        let newAnchor = HeadingAnchor(pdfPath: [0, 2], pageIndex: 10, title: "1.2 Something")
        try notes.retarget(noteID: headingNote.id, to: .heading(newAnchor))
        try check(try notes.note(bookID: bookID, target: .heading(newAnchor))?.id == headingNote.id, "retarget must move the note")
        try check(try notes.note(bookID: bookID, target: .heading(anchor)) == nil, "retarget must free the old target")
        let pageTwo = try notes.note(bookID: bookID, target: .page(2))!
        try expectError(.noteTargetOccupied(existingNoteID: pageTwo.id), "retarget onto an occupied target") {
            try notes.retarget(noteID: headingNote.id, to: .page(2))
        }
        try expectError(.bookNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!), "note for unknown book") {
            try notes.save(Note(bookID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, target: .page(0), text: "x"))
        }
        try notes.deleteNote(id: pageTwo.id)
        try notes.deleteNote(id: pageTwo.id)
        try check(try notes.note(id: pageTwo.id) == nil, "deleteNote must delete, and be idempotent")

        // Highlights
        let low = Highlight(bookID: bookID, pageIndex: 7, rects: [CGRect(x: 50, y: 100, width: 100, height: 12)], color: .yellow, text: "low")
        let high = Highlight(bookID: bookID, pageIndex: 7, rects: [CGRect(x: 50, y: 600, width: 100, height: 12)], color: .green, text: "high")
        let other = Highlight(bookID: bookID, pageIndex: 9, rects: [CGRect(x: 0, y: 0, width: 10, height: 10)], color: .pink, text: "other")
        try highlights.save(low)
        try highlights.save(high)
        try highlights.save(other)
        try check(try highlights.highlight(id: high.id) == high, "highlight(id:) must find the saved highlight")
        try check(try highlights.highlight(id: UUID()) == nil, "highlight(id:) must return nil for an unknown id")
        try check(try highlights.highlights(bookID: bookID, pageIndex: 7).map(\.text) == ["high", "low"], "highlights must be in reading order (top first)")
        try check(try highlights.highlights(bookID: bookID, in: 8...9).map(\.id) == [other.id], "highlights(in:) must filter by page")
        var recoloured = low
        recoloured.color = .blue
        try highlights.save(recoloured)
        try check(try highlights.highlights(bookID: bookID).first { $0.id == low.id }?.color == .blue, "save(highlight) must replace by id")
        try highlights.deleteHighlight(id: other.id)
        try check(try highlights.highlightCount(bookID: bookID) == 2, "deleteHighlight must delete")

        // Bookmarks
        try bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 12)
        try bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 12)
        try bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 1)
        try check(try bookmarks.bookmarks(bookID: bookID).map(\.pageIndex) == [1, 12], "bookmarks: one per page, sorted by page")
        try bookmarks.setBookmarked(false, bookID: bookID, pageIndex: 1)
        try check(try !bookmarks.isBookmarked(bookID: bookID, pageIndex: 1), "setBookmarked(false) must remove")
        try check(try bookmarks.isBookmarked(bookID: bookID, pageIndex: 12), "isBookmarked must report a bookmark")

        // User headings
        var heading = UserHeading(bookID: bookID, title: "Mine", pageIndex: 30, parent: anchor)
        try headings.save(heading)
        heading.title = "Mine, renamed"
        try headings.save(heading)
        try check(try headings.userHeadings(bookID: bookID) == [heading], "save(heading) must upsert by id")
        try check(try headings.userHeading(id: heading.id) == heading, "userHeading(id:) must find the heading")
        let doomed = UserHeading(bookID: bookID, title: "Doomed", pageIndex: 31, parent: nil)
        try headings.save(doomed)
        try headings.deleteUserHeading(id: doomed.id)
        try headings.deleteUserHeading(id: doomed.id)
        try check(try headings.userHeading(id: doomed.id) == nil, "deleteUserHeading must delete, and be idempotent")

        // Counts and cascade
        let counts = try books.recordCounts(bookID: bookID)
        try check(counts == BookRecordCounts(notes: 3, highlights: 2, bookmarks: 1, userHeadings: 1), "recordCounts wrong: \(counts)")
        try books.deleteBook(id: bookID)
        try check(try books.book(id: bookID) == nil, "deleteBook must delete the book")
        try check(try books.recordCounts(bookID: bookID) == BookRecordCounts(), "deleteBook must cascade to every record")
        try check(try notes.notes(bookID: bookID).isEmpty && headings.userHeadings(bookID: bookID).isEmpty
                  && highlights.highlights(bookID: bookID).isEmpty && bookmarks.bookmarks(bookID: bookID).isEmpty,
                  "deleteBook must leave no records behind")
    }

    /// Checks an ink store: round trips, replacement, idempotent deletes, the sorted inked-page
    /// list, note ink, and whole-book removal.
    public static func verifyInkStore(_ store: some InkStore) async throws {
        let bookID = UUID()
        let noteID = UUID()
        do {
            try check(try await store.pageInk(bookID: bookID, pageIndex: 0) == nil, "missing page ink must read as nil")
            try await store.savePageInk(Data([1, 2, 3]), bookID: bookID, pageIndex: 10)
            try await store.savePageInk(Data([4]), bookID: bookID, pageIndex: 2)
            try await store.savePageInk(Data([5, 6]), bookID: bookID, pageIndex: 10)
            try check(try await store.pageInk(bookID: bookID, pageIndex: 10) == Data([5, 6]), "savePageInk must replace")
            try check(try await store.inkedPageIndices(bookID: bookID) == [2, 10], "inkedPageIndices must be sorted")
            try await store.deletePageInk(bookID: bookID, pageIndex: 2)
            try await store.deletePageInk(bookID: bookID, pageIndex: 2)
            try check(try await store.inkedPageIndices(bookID: bookID) == [10], "deletePageInk must delete, idempotently")

            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == nil, "missing note ink must read as nil")
            try await store.saveNoteInk(Data([9]), bookID: bookID, noteID: noteID)
            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == Data([9]), "note ink must round-trip")
            try check(try await store.inkedPageIndices(bookID: bookID) == [10], "note ink must not count as page ink")
            try await store.deleteNoteInk(bookID: bookID, noteID: noteID)
            try await store.deleteNoteInk(bookID: bookID, noteID: noteID)
            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == nil, "deleteNoteInk must delete, idempotently")

            try await store.saveNoteInk(Data([9]), bookID: bookID, noteID: noteID)
            try await store.removeBook(bookID: bookID)
            try check(try await store.inkedPageIndices(bookID: bookID).isEmpty, "removeBook must remove page ink")
            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == nil, "removeBook must remove note ink")
            try await store.removeBook(bookID: bookID)
        } catch {
            try? await store.removeBook(bookID: bookID)
            throw error
        }
    }
}
