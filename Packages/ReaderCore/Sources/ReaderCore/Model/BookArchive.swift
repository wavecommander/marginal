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
