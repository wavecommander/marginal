import Foundation

/// Reference implementation of every record repository, held in memory.
///
/// It defines the contract's semantics executable-ly (the persistent store in WP2 must behave
/// the same; `RepositoryConformance` checks that) and serves tests and SwiftUI previews.
@MainActor
public final class InMemoryRecordStore: BookRepository, NoteRepository, HighlightRepository,
    BookmarkRepository, HeadingRepository {
    private var books: [UUID: Book] = [:]
    private var notesByID: [UUID: Note] = [:]
    private var highlightsByID: [UUID: Highlight] = [:]
    private var bookmarksByID: [UUID: Bookmark] = [:]
    private var headingsByID: [UUID: UserHeading] = [:]

    public init() {}

    private func requireBook(_ id: UUID) throws {
        guard books[id] != nil else { throw RepositoryError.bookNotFound(id) }
    }

    // MARK: BookRepository

    public func allBooks() throws -> [Book] { Array(books.values) }
    public func book(id: UUID) throws -> Book? { books[id] }
    public func book(fingerprint: String) throws -> Book? { books.values.first { $0.fingerprint == fingerprint } }
    public func save(_ book: Book) throws { books[book.id] = book }

    public func deleteBook(id: UUID) throws {
        books[id] = nil
        notesByID = notesByID.filter { $0.value.bookID != id }
        highlightsByID = highlightsByID.filter { $0.value.bookID != id }
        bookmarksByID = bookmarksByID.filter { $0.value.bookID != id }
        headingsByID = headingsByID.filter { $0.value.bookID != id }
    }

    public func recordCounts(bookID: UUID) throws -> BookRecordCounts {
        BookRecordCounts(
            notes: notesByID.values.count { $0.bookID == bookID },
            highlights: highlightsByID.values.count { $0.bookID == bookID },
            bookmarks: bookmarksByID.values.count { $0.bookID == bookID },
            userHeadings: headingsByID.values.count { $0.bookID == bookID }
        )
    }

    // MARK: NoteRepository

    public func note(bookID: UUID, target: NoteTarget) throws -> Note? {
        notesByID.values.first { $0.bookID == bookID && $0.target == target }
    }

    public func note(id: UUID) throws -> Note? { notesByID[id] }

    public func notes(bookID: UUID) throws -> [Note] {
        notesByID.values.filter { $0.bookID == bookID }
    }

    public func pageNotes(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Note] {
        notesByID.values
            .filter { $0.bookID == bookID && $0.target.pageIndex.map(pages.contains) == true }
            .sorted { $0.target.pageIndex! < $1.target.pageIndex! }
    }

    @discardableResult
    public func save(_ note: Note) throws -> Note? {
        try requireBook(note.bookID)
        if let stored = notesByID[note.id], stored.target != note.target || stored.bookID != note.bookID {
            throw RepositoryError.noteTargetMismatch(noteID: note.id)
        }
        let existing = try self.note(bookID: note.bookID, target: note.target)
        if note.isEmpty {
            if let existing { notesByID[existing.id] = nil }
            return nil
        }
        if let existing, existing.id != note.id {
            throw RepositoryError.noteTargetOccupied(existingNoteID: existing.id)
        }
        notesByID[note.id] = note
        return note
    }

    public func deleteNote(id: UUID) throws { notesByID[id] = nil }

    public func retarget(noteID: UUID, to target: NoteTarget) throws {
        guard var note = notesByID[noteID] else { throw RepositoryError.notFound(noteID) }
        guard note.target != target else { return }
        if let other = try self.note(bookID: note.bookID, target: target) {
            throw RepositoryError.noteTargetOccupied(existingNoteID: other.id)
        }
        note.target = target
        notesByID[noteID] = note
    }

    public func noteCount(bookID: UUID) throws -> Int {
        notesByID.values.count { $0.bookID == bookID }
    }

    // MARK: HighlightRepository

    public func highlights(bookID: UUID) throws -> [Highlight] {
        highlightsByID.values.filter { $0.bookID == bookID }.sorted(by: Highlight.readingOrder)
    }

    public func highlights(bookID: UUID, pageIndex: Int) throws -> [Highlight] {
        try highlights(bookID: bookID, in: pageIndex...pageIndex)
    }

    public func highlights(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Highlight] {
        highlightsByID.values
            .filter { $0.bookID == bookID && pages.contains($0.pageIndex) }
            .sorted(by: Highlight.readingOrder)
    }

    public func save(_ highlight: Highlight) throws {
        try requireBook(highlight.bookID)
        highlightsByID[highlight.id] = highlight
    }

    public func deleteHighlight(id: UUID) throws { highlightsByID[id] = nil }

    public func highlightCount(bookID: UUID) throws -> Int {
        highlightsByID.values.count { $0.bookID == bookID }
    }

    // MARK: BookmarkRepository

    public func bookmarks(bookID: UUID) throws -> [Bookmark] {
        bookmarksByID.values.filter { $0.bookID == bookID }.sorted { $0.pageIndex < $1.pageIndex }
    }

    public func isBookmarked(bookID: UUID, pageIndex: Int) throws -> Bool {
        bookmarksByID.values.contains { $0.bookID == bookID && $0.pageIndex == pageIndex }
    }

    public func setBookmarked(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws {
        let existing = bookmarksByID.values.filter { $0.bookID == bookID && $0.pageIndex == pageIndex }
        if bookmarked {
            guard existing.isEmpty else { return }
            try requireBook(bookID)
            let bookmark = Bookmark(bookID: bookID, pageIndex: pageIndex)
            bookmarksByID[bookmark.id] = bookmark
        } else {
            for bookmark in existing { bookmarksByID[bookmark.id] = nil }
        }
    }

    // MARK: HeadingRepository

    public func userHeadings(bookID: UUID) throws -> [UserHeading] {
        headingsByID.values.filter { $0.bookID == bookID }
    }

    public func save(_ heading: UserHeading) throws {
        try requireBook(heading.bookID)
        headingsByID[heading.id] = heading
    }

    public func deleteUserHeading(id: UUID) throws { headingsByID[id] = nil }
}

/// Reference `InkStore` held in memory. Same semantics as the file-backed store.
public actor InMemoryInkStore: InkStore {
    private var pages: [UUID: [Int: Data]] = [:]
    private var notes: [UUID: [UUID: Data]] = [:]

    public init() {}

    public func pageInk(bookID: UUID, pageIndex: Int) async throws -> Data? { pages[bookID]?[pageIndex] }
    public func savePageInk(_ data: Data, bookID: UUID, pageIndex: Int) async throws { pages[bookID, default: [:]][pageIndex] = data }
    public func deletePageInk(bookID: UUID, pageIndex: Int) async throws { pages[bookID]?[pageIndex] = nil }
    public func inkedPageIndices(bookID: UUID) async throws -> [Int] { (pages[bookID]?.keys).map { $0.sorted() } ?? [] }
    public func noteInk(bookID: UUID, noteID: UUID) async throws -> Data? { notes[bookID]?[noteID] }
    public func saveNoteInk(_ data: Data, bookID: UUID, noteID: UUID) async throws { notes[bookID, default: [:]][noteID] = data }
    public func deleteNoteInk(bookID: UUID, noteID: UUID) async throws { notes[bookID]?[noteID] = nil }
    public func removeBook(bookID: UUID) async throws {
        pages[bookID] = nil
        notes[bookID] = nil
    }
}
