import Foundation
import CoreGraphics
import SwiftData
import ReaderCore

/// SwiftData implementation of `RecordStore` over one container's `mainContext`.
///
/// Semantics are those of `InMemoryRecordStore` (checked by `RepositoryConformance`).
///
/// **Durability:** every mutating method ends with `context.save()` before it returns, so a
/// record is in the SQLite store (WAL) when the call returns; nothing is pending at app
/// backgrounding. If the save fails the context is rolled back and the error is thrown, so a
/// failed mutation leaves neither a stored nor a pending change.
///
/// **Posting:** the writes the app calls are `RecordStore`'s (in ReaderCore); this type supplies
/// the primitives they run, each returning what it replaced or removed. A record that is
/// replaced or removed is read first, so a row that cannot be decoded
/// (`ReaderStoreError.corruptRecord`) refuses the write, as it always has.
///
/// Fetches always use predicates (and sort descriptors) on the database; per-book queries never
/// load other books' rows.
@MainActor
final class SwiftDataRecordStore: RecordStore {
    var changePoster: StoreChangePoster?
    /// Held so the container (and its store) outlives every context use.
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
        container.mainContext.autosaveEnabled = false
    }

    // MARK: Helpers

    /// Runs `body` then saves; rolls back and rethrows if either fails.
    private func transaction(_ body: () throws -> Void) throws {
        do {
            try body()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func requireBook(_ id: UUID) throws {
        let count = try context.fetchCount(FetchDescriptor<BookModel>(predicate: #Predicate { $0.id == id }))
        guard count > 0 else { throw RepositoryError.bookNotFound(id) }
    }

    private nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ReaderStoreError.corruptRecord("\(what): \(error)")
        }
    }

    // MARK: Books

    private func value(_ m: BookModel) -> Book {
        Book(id: m.id, title: m.title, fingerprint: m.fingerprint, fileName: m.fileName, pageCount: m.pageCount,
             fileSize: m.fileSize, addedAt: m.addedAt, lastOpenedAt: m.lastOpenedAt,
             lastReadPageIndex: m.lastReadPageIndex,
             sourceFormat: m.sourceFormatRaw.flatMap(ImportFormat.init(rawValue:)),
             originalFileName: m.originalFileName, converterVersion: m.converterVersion)
    }

    private func bookModel(_ id: UUID) throws -> BookModel? {
        var d = FetchDescriptor<BookModel>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func allBooks() throws -> [Book] {
        try context.fetch(FetchDescriptor<BookModel>()).map(value)
    }

    func book(id: UUID) throws -> Book? {
        try bookModel(id).map(value)
    }

    func book(fingerprint: String) throws -> Book? {
        var d = FetchDescriptor<BookModel>(predicate: #Predicate { $0.fingerprint == fingerprint },
                                           sortBy: [SortDescriptor(\.addedAt)])
        d.fetchLimit = 1
        return try context.fetch(d).first.map(value)
    }

    func storeBook(_ book: Book) throws {
        try transaction {
            if let m = try bookModel(book.id) {
                m.title = book.title
                m.fingerprint = book.fingerprint
                m.fileName = book.fileName
                m.pageCount = book.pageCount
                m.fileSize = book.fileSize
                m.addedAt = book.addedAt
                m.lastOpenedAt = book.lastOpenedAt
                m.lastReadPageIndex = book.lastReadPageIndex
                m.sourceFormatRaw = book.sourceFormat?.rawValue
                m.originalFileName = book.originalFileName
                m.converterVersion = book.converterVersion
            } else {
                context.insert(BookModel(book))
            }
        }
    }

    func removeBook(id: UUID) throws -> Bool {
        let existed = try bookModel(id) != nil
        try transaction { try deleteRecords(ofBook: id) }
        return existed
    }

    /// The deletes of `deleteBook`, for use inside a `transaction`.
    private func deleteRecords(ofBook id: UUID) throws {
        try context.delete(model: NoteModel.self, where: #Predicate { $0.bookID == id })
        try context.delete(model: HighlightModel.self, where: #Predicate { $0.bookID == id })
        try context.delete(model: BookmarkModel.self, where: #Predicate { $0.bookID == id })
        try context.delete(model: UserHeadingModel.self, where: #Predicate { $0.bookID == id })
        try context.delete(model: BookModel.self, where: #Predicate { $0.id == id })
    }

    /// Every refusal is decided by reads before anything changes. Then one `transaction`: the
    /// batch deletes of `deleteBook` for each removed ID and the inserts, saved together (rolled
    /// back on failure). An inserted row may reuse the ID or composite key of a row deleted in the
    /// same save; the checks guarantee every such row belongs to a removed book, so the unique
    /// constraint's upsert never reaches a row that stays. After the save the rows are exactly the
    /// archive's (`replaceBookSurvivesReopen` checks this on disk, after reopening).
    func storeArchive(_ archive: BookArchive, removing ids: Set<UUID>) throws -> [UUID] {
        let removed = ids.union([archive.book.id])
        let existed = try removed.sorted { $0.uuidString < $1.uuidString }.filter { try bookModel($0) != nil }
        try archive.validateForReplacement()
        let fingerprint = archive.book.fingerprint
        let sameFingerprint = FetchDescriptor<BookModel>(predicate: #Predicate { $0.fingerprint == fingerprint },
                                                         sortBy: [SortDescriptor(\.addedAt)])
        if let other = try context.fetch(sameFingerprint).first(where: { !removed.contains($0.id) }) {
            throw RepositoryError.fingerprintInUse(existingBookID: other.id)
        }
        try requireNoForeignOwner(archive.notes.map(\.id), removed: removed) { chunk in
            try context.fetch(FetchDescriptor<NoteModel>(predicate: #Predicate { chunk.contains($0.id) })).map { ($0.id, $0.bookID) }
        }
        try requireNoForeignOwner(archive.highlights.map(\.id), removed: removed) { chunk in
            try context.fetch(FetchDescriptor<HighlightModel>(predicate: #Predicate { chunk.contains($0.id) })).map { ($0.id, $0.bookID) }
        }
        try requireNoForeignOwner(archive.bookmarks.map(\.id), removed: removed) { chunk in
            try context.fetch(FetchDescriptor<BookmarkModel>(predicate: #Predicate { chunk.contains($0.id) })).map { ($0.id, $0.bookID) }
        }
        try requireNoForeignOwner(archive.userHeadings.map(\.id), removed: removed) { chunk in
            try context.fetch(FetchDescriptor<UserHeadingModel>(predicate: #Predicate { chunk.contains($0.id) })).map { ($0.id, $0.bookID) }
        }
        // Build every row first, so an encoding failure throws before anything changes.
        let noteRows = try archive.notes.map(Self.newModel)
        let highlightRows = try archive.highlights.map(Self.newModel)
        let bookmarkRows = archive.bookmarks.map(Self.newModel)
        let headingRows = archive.userHeadings.map(Self.newModel)
        try transaction {
            for id in removed.sorted(by: { $0.uuidString < $1.uuidString }) { try deleteRecords(ofBook: id) }
            context.insert(BookModel(archive.book))
            for row in noteRows { context.insert(row) }
            for row in highlightRows { context.insert(row) }
            for row in bookmarkRows { context.insert(row) }
            for row in headingRows { context.insert(row) }
        }
        return existed
    }

    /// Throws `.recordOwnedByOtherBook` if any of `ids` is stored for a book outside `removed`.
    /// `fetch` returns `(id, bookID)` of the stored rows among a chunk of IDs; chunks stay well
    /// under SQLite's bound-variable limit.
    private func requireNoForeignOwner(_ ids: [UUID], removed: Set<UUID>,
                                       fetch: ([UUID]) throws -> [(UUID, UUID)]) throws {
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            start += 500
            if let (recordID, owner) = try fetch(chunk).first(where: { !removed.contains($0.1) }) {
                throw RepositoryError.recordOwnedByOtherBook(recordID: recordID, bookID: owner)
            }
        }
    }

    func recordCounts(bookID: UUID) throws -> BookRecordCounts {
        BookRecordCounts(
            notes: try noteCount(bookID: bookID),
            highlights: try highlightCount(bookID: bookID),
            bookmarks: try context.fetchCount(FetchDescriptor<BookmarkModel>(predicate: #Predicate { $0.bookID == bookID })),
            userHeadings: try context.fetchCount(FetchDescriptor<UserHeadingModel>(predicate: #Predicate { $0.bookID == bookID }))
        )
    }

    // MARK: Notes

    private func value(_ m: NoteModel) throws -> Note {
        guard let target = NoteTarget(storageKey: m.targetKey) else {
            throw ReaderStoreError.corruptRecord("note \(m.id) has target key \"\(m.targetKey)\"")
        }
        let layout = try m.bandLayoutData.map { try Self.decode(NoteBandLayout.self, from: $0, what: "note \(m.id) band layout") }
        return Note(id: m.id, bookID: m.bookID, target: target, text: m.text, hasInk: m.hasInk,
                    bandLayout: layout, createdAt: m.createdAt, modifiedAt: m.modifiedAt)
    }

    private func noteModel(id: UUID) throws -> NoteModel? {
        var d = FetchDescriptor<NoteModel>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    private func noteModel(bookID: UUID, target: NoteTarget) throws -> NoteModel? {
        let key = NoteModel.compositeKey(bookID: bookID, targetKey: target.storageKey)
        var d = FetchDescriptor<NoteModel>(predicate: #Predicate { $0.compositeKey == key })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func note(bookID: UUID, target: NoteTarget) throws -> Note? {
        try noteModel(bookID: bookID, target: target).map(value)
    }

    /// A note row for reading, or `nil` when its target is a kind this version does not know (a
    /// newer version wrote it; docs/DESIGN.md "Keeping data openable across versions"). Such rows
    /// stay in the database for that version until the book's rows are replaced (a restore or a
    /// delete); a write that would replace or move one still refuses (`value` throws `corruptRecord`).
    private func readableValue(_ m: NoteModel) throws -> Note? {
        NoteTarget(storageKey: m.targetKey) == nil ? nil : try value(m)
    }

    func note(id: UUID) throws -> Note? {
        try noteModel(id: id).flatMap(readableValue)
    }

    func notes(bookID: UUID) throws -> [Note] {
        try context.fetch(FetchDescriptor<NoteModel>(predicate: #Predicate { $0.bookID == bookID })).compactMap(readableValue)
    }

    func pageNotes(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Note] {
        let lower = pages.lowerBound, upper = pages.upperBound
        let d = FetchDescriptor<NoteModel>(
            predicate: #Predicate { $0.bookID == bookID && $0.pageIndex != nil
                && ($0.pageIndex ?? 0) >= lower && ($0.pageIndex ?? 0) <= upper },
            sortBy: [SortDescriptor(\.pageIndex)])
        return try context.fetch(d).compactMap(readableValue)
    }

    /// A new, uninserted row for `note`: the one place a note's columns are computed for an insert.
    private static func newModel(_ note: Note) throws -> NoteModel {
        NoteModel(id: note.id, bookID: note.bookID, targetKey: note.target.storageKey, pageIndex: note.target.pageIndex,
                  text: note.text, hasInk: note.hasInk, bandLayoutData: try bandLayoutData(note),
                  createdAt: note.createdAt, modifiedAt: note.modifiedAt)
    }

    private static func bandLayoutData(_ note: Note) throws -> Data? {
        try note.bandLayout.map { try encode($0) }
    }

    func storeNote(_ note: Note) throws -> NoteStoreOutcome {
        let existing = try noteModel(bookID: note.bookID, target: note.target)
        let previous = try existing.map(value)
        try requireBook(note.bookID)
        if let stored = try noteModel(id: note.id), stored.compositeKey != NoteModel.compositeKey(bookID: note.bookID, targetKey: note.target.storageKey) {
            throw RepositoryError.noteTargetMismatch(noteID: note.id)
        }
        if note.isEmpty {
            guard let existing, let previous else { return .unchanged }
            try transaction { context.delete(existing) }
            return .removed(previous)
        }
        if let existing, existing.id != note.id {
            throw RepositoryError.noteTargetOccupied(existingNoteID: existing.id)
        }
        let layoutData = try Self.bandLayoutData(note)
        try transaction {
            if let existing {
                existing.text = note.text
                existing.hasInk = note.hasInk
                existing.bandLayoutData = layoutData
                existing.createdAt = note.createdAt
                existing.modifiedAt = note.modifiedAt
            } else {
                context.insert(try Self.newModel(note))
            }
        }
        return .stored(note)
    }

    func removeNote(id: UUID) throws -> Note? {
        guard let m = try noteModel(id: id) else { return nil }
        let previous = try value(m)
        try transaction { context.delete(m) }
        return previous
    }

    func moveNote(id noteID: UUID, to target: NoteTarget) throws -> Note? {
        guard let m = try noteModel(id: noteID) else { throw RepositoryError.notFound(noteID) }
        let previous = try value(m)
        guard m.targetKey != target.storageKey else { return nil }
        if let other = try noteModel(bookID: m.bookID, target: target) {
            throw RepositoryError.noteTargetOccupied(existingNoteID: other.id)
        }
        try transaction {
            m.targetKey = target.storageKey
            m.pageIndex = target.pageIndex
            m.compositeKey = NoteModel.compositeKey(bookID: m.bookID, targetKey: target.storageKey)
        }
        return previous
    }

    func noteCount(bookID: UUID) throws -> Int {
        try context.fetchCount(FetchDescriptor<NoteModel>(predicate: #Predicate { $0.bookID == bookID }))
    }

    // MARK: Highlights

    private func value(_ m: HighlightModel) throws -> Highlight {
        // A colour this version does not know (a newer version wrote it) reads as the fallback.
        let color = HighlightColor(storedValue: m.colorRaw)
        let rects = try Self.decode([CGRect].self, from: m.rectsData, what: "highlight \(m.id) rects")
        return Highlight(id: m.id, bookID: m.bookID, pageIndex: m.pageIndex, rects: rects, color: color,
                         text: m.text, createdAt: m.createdAt)
    }

    /// `Highlight.readingOrder` as database sort keys.
    private static let readingOrderSort: [SortDescriptor<HighlightModel>] = [
        SortDescriptor(\.pageIndex),
        SortDescriptor(\.sortRank),
        SortDescriptor(\.sortMaxY, order: .reverse),
        SortDescriptor(\.sortMinX),
        SortDescriptor(\.createdAt),
        SortDescriptor(\.idString),
    ]

    /// Converts rows the database already sorted and applies the exact contract order. The
    /// database sort does the heavy lifting; the final pass only settles ties, because SwiftData
    /// does not order the `idString` tie-break the way `String <` does (observed on macOS 27).
    private func ordered(_ rows: [HighlightModel]) throws -> [Highlight] {
        try rows.map(value).sorted(by: Highlight.readingOrder)
    }

    private func highlightModel(id: UUID) throws -> HighlightModel? {
        var d = FetchDescriptor<HighlightModel>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func highlight(id: UUID) throws -> Highlight? {
        try highlightModel(id: id).map(value)
    }

    func highlights(bookID: UUID) throws -> [Highlight] {
        let d = FetchDescriptor<HighlightModel>(predicate: #Predicate { $0.bookID == bookID },
                                                sortBy: Self.readingOrderSort)
        return try ordered(context.fetch(d))
    }

    func highlights(bookID: UUID, pageIndex: Int) throws -> [Highlight] {
        let d = FetchDescriptor<HighlightModel>(predicate: #Predicate { $0.bookID == bookID && $0.pageIndex == pageIndex },
                                                sortBy: Self.readingOrderSort)
        return try ordered(context.fetch(d))
    }

    func highlights(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Highlight] {
        let lower = pages.lowerBound, upper = pages.upperBound
        let d = FetchDescriptor<HighlightModel>(
            predicate: #Predicate { $0.bookID == bookID && $0.pageIndex >= lower && $0.pageIndex <= upper },
            sortBy: Self.readingOrderSort)
        return try ordered(context.fetch(d))
    }

    /// The stored rects and the denormalised `Highlight.readingOrder` columns of a highlight: the
    /// one place they are computed, for inserts and updates alike.
    private struct HighlightColumns {
        var rectsData: Data
        var sortRank: Int
        var sortMaxY: Double
        var sortMinX: Double

        init(_ highlight: Highlight) throws {
            rectsData = try SwiftDataRecordStore.encode(highlight.rects)
            let bounds = highlight.bounds
            sortRank = bounds.isNull ? 1 : 0
            sortMaxY = bounds.isNull ? 0 : Double(bounds.maxY)
            sortMinX = bounds.isNull ? 0 : Double(bounds.minX)
        }
    }

    /// A new, uninserted row for `highlight`.
    private static func newModel(_ highlight: Highlight) throws -> HighlightModel {
        let columns = try HighlightColumns(highlight)
        return HighlightModel(id: highlight.id, bookID: highlight.bookID, pageIndex: highlight.pageIndex,
                              rectsData: columns.rectsData, colorRaw: highlight.color.rawValue,
                              text: highlight.text, createdAt: highlight.createdAt,
                              sortRank: columns.sortRank, sortMaxY: columns.sortMaxY, sortMinX: columns.sortMinX)
    }

    func storeHighlight(_ highlight: Highlight) throws -> Highlight? {
        let existing = try highlightModel(id: highlight.id)
        let previous = try existing.map(value)
        try requireBook(highlight.bookID)
        let columns = try HighlightColumns(highlight)
        try transaction {
            if let m = existing {
                m.bookID = highlight.bookID
                m.pageIndex = highlight.pageIndex
                m.rectsData = columns.rectsData
                m.colorRaw = highlight.color.rawValue
                m.text = highlight.text
                m.createdAt = highlight.createdAt
                m.sortRank = columns.sortRank
                m.sortMaxY = columns.sortMaxY
                m.sortMinX = columns.sortMinX
            } else {
                context.insert(try Self.newModel(highlight))
            }
        }
        return previous
    }

    func removeHighlight(id: UUID) throws -> Highlight? {
        guard let m = try highlightModel(id: id) else { return nil }
        let previous = try value(m)
        try transaction { context.delete(m) }
        return previous
    }

    func highlightCount(bookID: UUID) throws -> Int {
        try context.fetchCount(FetchDescriptor<HighlightModel>(predicate: #Predicate { $0.bookID == bookID }))
    }

    // MARK: Bookmarks

    private func value(_ m: BookmarkModel) -> Bookmark {
        Bookmark(id: m.id, bookID: m.bookID, pageIndex: m.pageIndex, createdAt: m.createdAt)
    }

    /// A new, uninserted row for `bookmark` (the model's initialiser computes `compositeKey`).
    private static func newModel(_ bookmark: Bookmark) -> BookmarkModel {
        BookmarkModel(id: bookmark.id, bookID: bookmark.bookID, pageIndex: bookmark.pageIndex, createdAt: bookmark.createdAt)
    }

    private func bookmarkModels(bookID: UUID, pageIndex: Int) throws -> [BookmarkModel] {
        let key = BookmarkModel.compositeKey(bookID: bookID, pageIndex: pageIndex)
        return try context.fetch(FetchDescriptor<BookmarkModel>(predicate: #Predicate { $0.compositeKey == key }))
    }

    func bookmarks(bookID: UUID) throws -> [Bookmark] {
        let d = FetchDescriptor<BookmarkModel>(predicate: #Predicate { $0.bookID == bookID },
                                               sortBy: [SortDescriptor(\.pageIndex)])
        return try context.fetch(d).map(value)
    }

    func isBookmarked(bookID: UUID, pageIndex: Int) throws -> Bool {
        let key = BookmarkModel.compositeKey(bookID: bookID, pageIndex: pageIndex)
        return try context.fetchCount(FetchDescriptor<BookmarkModel>(predicate: #Predicate { $0.compositeKey == key })) > 0
    }

    func storeBookmark(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws -> Bool {
        let existing = try bookmarkModels(bookID: bookID, pageIndex: pageIndex)
        if bookmarked {
            guard existing.isEmpty else { return false }
            try requireBook(bookID)
            try transaction {
                context.insert(Self.newModel(Bookmark(bookID: bookID, pageIndex: pageIndex)))
            }
            return true
        } else if !existing.isEmpty {
            try transaction { for m in existing { context.delete(m) } }
            return true
        }
        return false
    }

    // MARK: User headings

    private func value(_ m: UserHeadingModel) throws -> UserHeading {
        var parent: HeadingAnchor?
        if let raw = m.parentRaw {
            // A parent of a kind this version does not know (a newer version wrote it) reads as
            // top level, as a parent that no longer resolves does.
            parent = HeadingAnchor(rawValue: raw)
        }
        return UserHeading(id: m.id, bookID: m.bookID, title: m.title, pageIndex: m.pageIndex, parent: parent,
                           createdAt: m.createdAt)
    }

    /// A new, uninserted row for `heading`.
    private static func newModel(_ heading: UserHeading) -> UserHeadingModel {
        UserHeadingModel(id: heading.id, bookID: heading.bookID, title: heading.title, pageIndex: heading.pageIndex,
                         parentRaw: heading.parent?.rawValue, createdAt: heading.createdAt)
    }

    private func headingModel(id: UUID) throws -> UserHeadingModel? {
        var d = FetchDescriptor<UserHeadingModel>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func userHeadings(bookID: UUID) throws -> [UserHeading] {
        try context.fetch(FetchDescriptor<UserHeadingModel>(predicate: #Predicate { $0.bookID == bookID })).map(value)
    }

    func userHeading(id: UUID) throws -> UserHeading? {
        try headingModel(id: id).map(value)
    }

    func storeUserHeading(_ heading: UserHeading) throws -> UserHeading? {
        let existing = try headingModel(id: heading.id)
        let previous = try existing.map(value)
        try requireBook(heading.bookID)
        try transaction {
            if let m = existing {
                m.bookID = heading.bookID
                m.title = heading.title
                m.pageIndex = heading.pageIndex
                m.parentRaw = heading.parent?.rawValue
                m.createdAt = heading.createdAt
            } else {
                context.insert(Self.newModel(heading))
            }
        }
        return previous
    }

    func removeUserHeading(id: UUID) throws -> UserHeading? {
        guard let m = try headingModel(id: id) else { return nil }
        let previous = try value(m)
        try transaction { context.delete(m) }
        return previous
    }
}
