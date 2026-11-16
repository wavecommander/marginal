import Foundation

/// Reference implementation of `RecordStore`, held in memory.
///
/// It defines the contract's semantics executable-ly (the persistent store in WP2 must behave
/// the same; `RepositoryConformance` checks that) and serves tests and SwiftUI previews.
@MainActor
public class InMemoryRecordStore: RecordStore {
    public var changePoster: StoreChangePoster?
    private var books: [UUID: Book] = [:]
    private var notesByID: [UUID: Note] = [:]
    private var highlightsByID: [UUID: Highlight] = [:]
    private var bookmarksByID: [UUID: Bookmark] = [:]
    private var headingsByID: [UUID: UserHeading] = [:]

    public init() {}

    private func requireBook(_ id: UUID) throws {
        guard books[id] != nil else { throw RepositoryError.bookNotFound(id) }
    }

    // MARK: Books

    public func allBooks() throws -> [Book] { Array(books.values) }
    public func book(id: UUID) throws -> Book? { books[id] }
    public func book(fingerprint: String) throws -> Book? { books.values.first { $0.fingerprint == fingerprint } }
    public func storeBook(_ book: Book) throws { books[book.id] = book }

    public func removeBook(id: UUID) throws -> Bool {
        let existed = books[id] != nil
        deleteRecords(ofBook: id)
        return existed
    }

    private func deleteRecords(ofBook id: UUID) {
        books[id] = nil
        notesByID = notesByID.filter { $0.value.bookID != id }
        highlightsByID = highlightsByID.filter { $0.value.bookID != id }
        bookmarksByID = bookmarksByID.filter { $0.value.bookID != id }
        headingsByID = headingsByID.filter { $0.value.bookID != id }
    }

    public func storeArchive(_ archive: BookArchive, removing ids: Set<UUID>) throws -> [UUID] {
        try archive.validateForReplacement()
        let removed = ids.union([archive.book.id])
        if let other = books.values.filter({ $0.fingerprint == archive.book.fingerprint && !removed.contains($0.id) })
            .min(by: { $0.addedAt < $1.addedAt }) {
            throw RepositoryError.fingerprintInUse(existingBookID: other.id)
        }
        let stored: [(UUID, UUID?)] = archive.notes.map { ($0.id, notesByID[$0.id]?.bookID) }
            + archive.highlights.map { ($0.id, highlightsByID[$0.id]?.bookID) }
            + archive.bookmarks.map { ($0.id, bookmarksByID[$0.id]?.bookID) }
            + archive.userHeadings.map { ($0.id, headingsByID[$0.id]?.bookID) }
        for case let (recordID, owner?) in stored where !removed.contains(owner) {
            throw RepositoryError.recordOwnedByOtherBook(recordID: recordID, bookID: owner)
        }
        // Nothing below throws, so the replacement is all or nothing.
        let existed = removed.filter { books[$0] != nil }
        for id in removed { deleteRecords(ofBook: id) }
        books[archive.book.id] = archive.book
        for note in archive.notes { notesByID[note.id] = note }
        for highlight in archive.highlights { highlightsByID[highlight.id] = highlight }
        for bookmark in archive.bookmarks { bookmarksByID[bookmark.id] = bookmark }
        for heading in archive.userHeadings { headingsByID[heading.id] = heading }
        return Array(existed)
    }

    public func recordCounts(bookID: UUID) throws -> BookRecordCounts {
        BookRecordCounts(
            notes: notesByID.values.count { $0.bookID == bookID },
            highlights: highlightsByID.values.count { $0.bookID == bookID },
            bookmarks: bookmarksByID.values.count { $0.bookID == bookID },
            userHeadings: headingsByID.values.count { $0.bookID == bookID }
        )
    }

    // MARK: Notes

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

    public func storeNote(_ note: Note) throws -> NoteStoreOutcome {
        try requireBook(note.bookID)
        if let stored = notesByID[note.id], stored.target != note.target || stored.bookID != note.bookID {
            throw RepositoryError.noteTargetMismatch(noteID: note.id)
        }
        let existing = try self.note(bookID: note.bookID, target: note.target)
        if note.isEmpty {
            guard let existing else { return .unchanged }
            notesByID[existing.id] = nil
            return .removed(existing)
        }
        if let existing, existing.id != note.id {
            throw RepositoryError.noteTargetOccupied(existingNoteID: existing.id)
        }
        notesByID[note.id] = note
        return .stored(note)
    }

    public func removeNote(id: UUID) throws -> Note? { notesByID.removeValue(forKey: id) }

    public func moveNote(id noteID: UUID, to target: NoteTarget) throws -> Note? {
        guard let existing = notesByID[noteID] else { throw RepositoryError.notFound(noteID) }
        guard existing.target != target else { return nil }
        if let other = try self.note(bookID: existing.bookID, target: target) {
            throw RepositoryError.noteTargetOccupied(existingNoteID: other.id)
        }
        var moved = existing
        moved.target = target
        notesByID[noteID] = moved
        return existing
    }

    public func noteCount(bookID: UUID) throws -> Int {
        notesByID.values.count { $0.bookID == bookID }
    }

    // MARK: Highlights

    public func highlight(id: UUID) throws -> Highlight? { highlightsByID[id] }

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

    public func storeHighlight(_ highlight: Highlight) throws -> Highlight? {
        try requireBook(highlight.bookID)
        return highlightsByID.updateValue(highlight, forKey: highlight.id)
    }

    public func removeHighlight(id: UUID) throws -> Highlight? { highlightsByID.removeValue(forKey: id) }

    public func highlightCount(bookID: UUID) throws -> Int {
        highlightsByID.values.count { $0.bookID == bookID }
    }

    // MARK: Bookmarks

    public func bookmarks(bookID: UUID) throws -> [Bookmark] {
        bookmarksByID.values.filter { $0.bookID == bookID }.sorted { $0.pageIndex < $1.pageIndex }
    }

    public func isBookmarked(bookID: UUID, pageIndex: Int) throws -> Bool {
        bookmarksByID.values.contains { $0.bookID == bookID && $0.pageIndex == pageIndex }
    }

    public func storeBookmark(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws -> Bool {
        let existing = bookmarksByID.values.filter { $0.bookID == bookID && $0.pageIndex == pageIndex }
        if bookmarked {
            guard existing.isEmpty else { return false }
            try requireBook(bookID)
            let bookmark = Bookmark(bookID: bookID, pageIndex: pageIndex)
            bookmarksByID[bookmark.id] = bookmark
            return true
        } else {
            for bookmark in existing { bookmarksByID[bookmark.id] = nil }
            return !existing.isEmpty
        }
    }

    // MARK: Headings

    public func userHeadings(bookID: UUID) throws -> [UserHeading] {
        headingsByID.values.filter { $0.bookID == bookID }
    }

    public func userHeading(id: UUID) throws -> UserHeading? { headingsByID[id] }

    public func storeUserHeading(_ heading: UserHeading) throws -> UserHeading? {
        try requireBook(heading.bookID)
        return headingsByID.updateValue(heading, forKey: heading.id)
    }

    public func removeUserHeading(id: UUID) throws -> UserHeading? { headingsByID.removeValue(forKey: id) }
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
