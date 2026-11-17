import Foundation

/// What changed in one kind of record between two archives of a book, by record ID.
public struct RecordDiff<Record: Identifiable & Hashable & Sendable>: Hashable, Sendable where Record.ID == UUID {
    /// Records the new archive has and the old one does not, in the new archive's order.
    public var added: [Record] = []
    /// Records both have whose fields differ (`bookID` aside), as the new archive has them, in its order.
    public var changed: [Record] = []
    /// IDs of records the old archive has and the new one does not, in the old archive's order.
    public var removed: [UUID] = []

    public init(added: [Record] = [], changed: [Record] = [], removed: [UUID] = []) {
        self.added = added
        self.changed = changed
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }

    /// How many records were added, changed or removed.
    public var count: Int { added.count + changed.count + removed.count }
}

/// What changed between two archives of one book: the records, added, changed and removed by ID,
/// and the book fields sync carries (title and reading position).
///
/// **Comparison:** records are matched by ID; a record's `bookID` is not compared, since the two
/// archives may be copies of the book imported under different IDs. Of the `Book`, only `title`
/// and the reading position (`lastReadPageIndex`, `lastOpenedAt`) are compared; its identity,
/// file and import fields belong to each device. Where an archive repeats an ID (bad input), the
/// first record in its array order is the one compared.
///
/// Used by sync to tell whether there is anything to push (`BookArchiveDiff(from: remote, to:
/// merged).isEmpty`) and which records to write locally, and as a report.
public struct BookArchiveDiff: Hashable, Sendable {
    public var titleChanged: Bool
    public var readingPositionChanged: Bool
    public var notes: RecordDiff<Note>
    public var highlights: RecordDiff<Highlight>
    public var bookmarks: RecordDiff<Bookmark>
    public var userHeadings: RecordDiff<UserHeading>

    /// The changes that turn `old` into `new`.
    public init(from old: BookArchive, to new: BookArchive) {
        titleChanged = old.book.title != new.book.title
        readingPositionChanged = old.book.lastReadPageIndex != new.book.lastReadPageIndex
            || old.book.lastOpenedAt != new.book.lastOpenedAt
        let bookID = new.book.id
        notes = Self.diff(old.notes, new.notes) { var r = $0; r.bookID = bookID; return r }
        highlights = Self.diff(old.highlights, new.highlights) { var r = $0; r.bookID = bookID; return r }
        bookmarks = Self.diff(old.bookmarks, new.bookmarks) { var r = $0; r.bookID = bookID; return r }
        userHeadings = Self.diff(old.userHeadings, new.userHeadings) { var r = $0; r.bookID = bookID; return r }
    }

    /// `true` when nothing sync carries differs.
    public var isEmpty: Bool {
        !titleChanged && !readingPositionChanged && recordsUnchanged
    }

    /// `true` when no record was added, changed or removed (the book's fields may differ).
    public var recordsUnchanged: Bool {
        notes.isEmpty && highlights.isEmpty && bookmarks.isEmpty && userHeadings.isEmpty
    }

    private static func diff<R>(_ old: [R], _ new: [R], rekey: (R) -> R) -> RecordDiff<R> {
        var oldByID: [UUID: R] = [:]
        for record in old where oldByID[record.id] == nil { oldByID[record.id] = rekey(record) }
        var result = RecordDiff<R>()
        var seen = Set<UUID>()
        for record in new where seen.insert(record.id).inserted {
            if let before = oldByID[record.id] {
                if before != rekey(record) { result.changed.append(record) }
            } else {
                result.added.append(record)
            }
        }
        var removedSeen = Set<UUID>()
        for record in old where !seen.contains(record.id) && removedSeen.insert(record.id).inserted {
            result.removed.append(record.id)
        }
        return result
    }
}
