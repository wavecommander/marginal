import Foundation

/// Everything the record store holds for one book, as values: the unit of backup and restore.
///
/// Ink is not here (it is `InkStore` files, see `BookStorageLayout`), and neither is the PDF.
/// The `Codable` form is the backup format's `records.json` plus the manifest's book entry, so a
/// change to any of these value types' coding is a backup format change.
///
/// Invariant a well-formed archive keeps: every record's `bookID` is `book.id`.
public struct BookArchive: Hashable, Codable, Sendable {
    public var book: Book
    public var notes: [Note]
    public var highlights: [Highlight]
    public var bookmarks: [Bookmark]
    public var userHeadings: [UserHeading]

    public init(book: Book, notes: [Note] = [], highlights: [Highlight] = [], bookmarks: [Bookmark] = [],
                userHeadings: [UserHeading] = []) {
        self.book = book
        self.notes = notes
        self.highlights = highlights
        self.bookmarks = bookmarks
        self.userHeadings = userHeadings
    }

    /// `true` when every record belongs to `book`.
    public var isConsistent: Bool {
        let id = book.id
        return notes.allSatisfy { $0.bookID == id } && highlights.allSatisfy { $0.bookID == id }
            && bookmarks.allSatisfy { $0.bookID == id } && userHeadings.allSatisfy { $0.bookID == id }
    }

    /// Checks the rules `RecordStore.replaceBook(_:removing:)` applies to the archive on its
    /// own, before it looks at the store, so every implementation refuses the same archives with
    /// the same error. In order: every record belongs to `book` (`.archiveInconsistent`); no ID
    /// repeats within one kind of record (`.archiveDuplicateRecordID`); at most one note per
    /// target (`.archiveDuplicateNoteTarget`) and one bookmark per page
    /// (`.archiveDuplicateBookmarkPage`); no empty note (`.archiveEmptyNote`). Records are
    /// checked in array order, notes first, then highlights, bookmarks and user headings.
    public func validateForReplacement() throws {
        let id = book.id
        let owners: [(UUID, UUID)] = notes.map { ($0.id, $0.bookID) } + highlights.map { ($0.id, $0.bookID) }
            + bookmarks.map { ($0.id, $0.bookID) } + userHeadings.map { ($0.id, $0.bookID) }
        if let stray = owners.first(where: { $0.1 != id }) { throw RepositoryError.archiveInconsistent(recordID: stray.0) }

        for ids in [notes.map(\.id), highlights.map(\.id), bookmarks.map(\.id), userHeadings.map(\.id)] {
            var seen = Set<UUID>()
            for recordID in ids where !seen.insert(recordID).inserted {
                throw RepositoryError.archiveDuplicateRecordID(recordID)
            }
        }
        var targets = Set<NoteTarget>()
        for note in notes where !targets.insert(note.target).inserted {
            throw RepositoryError.archiveDuplicateNoteTarget(noteID: note.id)
        }
        var pages = Set<Int>()
        for bookmark in bookmarks where !pages.insert(bookmark.pageIndex).inserted {
            throw RepositoryError.archiveDuplicateBookmarkPage(pageIndex: bookmark.pageIndex)
        }
        if let empty = notes.first(where: \.isEmpty) { throw RepositoryError.archiveEmptyNote(noteID: empty.id) }
    }

    /// The most recent moment anything in the archive was made or edited (the book's own
    /// `addedAt` when it has no records). Shown beside each book in the restore preview.
    public var lastModifiedAt: Date {
        var latest = book.addedAt
        for note in notes { latest = max(latest, note.modifiedAt) }
        for highlight in highlights { latest = max(latest, highlight.createdAt) }
        for bookmark in bookmarks { latest = max(latest, bookmark.createdAt) }
        for heading in userHeadings { latest = max(latest, heading.createdAt) }
        return latest
    }
}
