import Foundation

// MARK: - Concurrency
//
// `RecordStore` is a `@MainActor` protocol with synchronous `throws` methods that take and return
// value types. The persistent store implements it with SwiftData on the main `ModelContext`, and
// it is called from `@MainActor` SwiftUI / `@Observable` code, so main-actor isolation is the
// honest contract: no `@Model` object ever crosses an actor boundary, and callers need no `await`
// for small, indexed reads and writes. Anything that must not run on the main thread (outline
// building, notebook building, export) takes the value types these return.
//
// `InkStore` does file I/O of up to megabytes and is `Sendable` with `async throws` methods so
// implementations can do the work off the main thread (an `actor` or a type with a private queue).
//
// A record store never touches files: deleting a note or a book must be followed by the matching
// `InkStore` call by the caller (all `InkStore` deletes are idempotent, so a store that also
// schedules them does no harm). `LibraryStore` provides the compound operations that do both.
// A record store posts a `StoreChange` for each successful write once a `LibraryStore` owns it;
// app code reaches it through `LibraryStore` (`store.books`, `store.notes`, …).

/// Errors every record store must report in these situations.
public enum RepositoryError: Error, Hashable, Sendable {
    /// A record referenced a book that does not exist.
    case bookNotFound(UUID)
    /// `RecordStore.save(_:)` (a note) or `retarget` would create a second note for a target that already
    /// has one (with this ID).
    case noteTargetOccupied(existingNoteID: UUID)
    /// `RecordStore.save(_:)` was given a note whose ID is stored under a different target; use
    /// `retarget(noteID:to:)` to move a note.
    case noteTargetMismatch(noteID: UUID)
    /// The record with this ID does not exist.
    case notFound(UUID)

    // `RecordStore.replaceBook(_:removing:)` refusals. Each one leaves the store unchanged.
    // The first five are about the archive alone (`BookArchive.validateForReplacement()`); the
    // last two compare it with the store.

    /// The archive is not `isConsistent`: the record with this ID has a `bookID` other than
    /// `archive.book.id`.
    case archiveInconsistent(recordID: UUID)
    /// Two records of one kind in the archive (two notes, two highlights, two bookmarks or two
    /// user headings) share this ID.
    case archiveDuplicateRecordID(UUID)
    /// The archive holds two notes for one target; this is the ID of the second.
    case archiveDuplicateNoteTarget(noteID: UUID)
    /// The archive holds two bookmarks on this page.
    case archiveDuplicateBookmarkPage(pageIndex: Int)
    /// The archive holds an empty note (`Note.isEmpty`), which the store never keeps.
    case archiveEmptyNote(noteID: UUID)
    /// A record in the archive has the ID of a stored record of a book that is not being
    /// replaced or removed (`bookID`). Inserting it would take the row from that book.
    case recordOwnedByOtherBook(recordID: UUID, bookID: UUID)
    /// Another book that is not being replaced or removed has the archive book's fingerprint
    /// (the library holds one book per fingerprint).
    case fingerprintInUse(existingBookID: UUID)
}

/// How many records a book owns; with `InkStore.inkedPageIndices` this is the "N notes, M
/// highlights, K pages of ink" in the delete-book confirmation.
public struct BookRecordCounts: Hashable, Sendable {
    /// Page notes plus heading notes.
    public var notes: Int
    /// Highlights of the book.
    public var highlights: Int
    /// Bookmarked pages.
    public var bookmarks: Int
    /// User headings (PDF headings are not stored).
    public var userHeadings: Int

    public init(notes: Int = 0, highlights: Int = 0, bookmarks: Int = 0, userHeadings: Int = 0) {
        self.notes = notes
        self.highlights = highlights
        self.bookmarks = bookmarks
        self.userHeadings = userHeadings
    }
}

/// What deleting a book will remove; shown in its confirmation.
public struct BookDeletionSummary: Hashable, Sendable {
    /// Record counts from `RecordStore.recordCounts(bookID:)`.
    public var records: BookRecordCounts
    /// Number of pages with page ink (`InkStore.inkedPageIndices(bookID:).count`).
    public var inkedPages: Int

    public init(records: BookRecordCounts, inkedPages: Int) {
        self.records = records
        self.inkedPages = inkedPages
    }

    /// "N notes" in the confirmation.
    public var notes: Int { records.notes }
    /// "M highlights" in the confirmation.
    public var highlights: Int { records.highlights }
}

// MARK: - The record store

/// Where a record store announces its writes: a `LibraryStore`'s hub, and the origin of the
/// `LibraryStore.perform(as:_:)` in progress. One per `LibraryStore`, shared with its record
/// store.
@MainActor
public final class StoreChangePoster {
    /// The hub the changes are posted on.
    public let hub: StoreChangeHub
    /// Who is making the writes right now (`nil`: unattributed).
    public internal(set) var origin: ChangeOrigin?

    public init(hub: StoreChangeHub) { self.hub = hub }

    /// Posts `changes` in order, as separate events with the current origin.
    func post(_ changes: [StoreChange]) { hub.post(changes, origin: origin) }
    func post(_ changes: StoreChange...) { hub.post(changes, origin: origin) }
}

/// What `RecordStore.storeNote(_:)` did.
public enum NoteStoreOutcome: Hashable, Sendable {
    /// The note is stored as given (inserted, or replaced in place).
    case stored(Note)
    /// The note given was empty, so the note stored for its target (this one) was deleted.
    case removed(Note)
    /// The note given was empty and nothing was stored for its target.
    case unchanged
}

/// One store for every kind of record: books, notes, highlights, bookmarks and user headings.
/// Main-actor, synchronous, value types in and out (see "Concurrency" above).
///
/// **Two layers.** An implementation supplies the reads and the *primitive* writes
/// (`storeBook`, `removeNote`, …), each of which returns what it replaced or removed. The writes
/// the app calls (`save`, `deleteNote`, `retarget`, `setBookmarked`, `replaceBook`, …) are
/// defined once, in the extension below: each runs its primitive and then announces what
/// changed on `changePoster`, from what the primitive returned. So change posting is part of
/// the store, it is the same for every implementation, and no write reads a record a second
/// time to find out what to announce.
///
/// **What posts what** is listed on `LibraryStore` and checked for every implementation by
/// `RepositoryConformance.verifyChangePosting`. A write that throws posts nothing.
///
/// **Refusals.** A primitive reads the record it replaces or removes *before* changing anything,
/// and throws if that record cannot be read (a persistent store may report a corrupt row), so
/// such a record is never silently overwritten or deleted.
///
/// Implementations never touch files (see `InkStore`, and the compound operations on
/// `LibraryStore`).
@MainActor
public protocol RecordStore: AnyObject {
    /// Where the writes announce what they changed; `nil` announces nothing. Set by the
    /// `LibraryStore` that owns the store (one `LibraryStore` per store).
    var changePoster: StoreChangePoster? { get set }

    // MARK: Books

    /// All books, in no particular order (the Library sorts).
    func allBooks() throws -> [Book]
    /// The book with this ID, or `nil`.
    func book(id: UUID) throws -> Book?
    /// The book with this content fingerprint, or `nil` (import de-duplication).
    func book(fingerprint: String) throws -> Book?
    /// Counts of the records `deleteBook` would remove (all zero for an unknown book).
    func recordCounts(bookID: UUID) throws -> BookRecordCounts
    /// Inserts or replaces the book with `book.id`.
    func storeBook(_ book: Book) throws
    /// Deletes the book and, in the same transaction, all of its notes, highlights, bookmarks
    /// and user headings. Returns whether the book existed (an unknown ID is a no-op).
    func removeBook(id: UUID) throws -> Bool
    /// `replaceBook(_:removing:)`'s work (see there for the rules and refusals). Returns the IDs
    /// among `ids ∪ {archive.book.id}` whose book existed before, in no particular order.
    func storeArchive(_ archive: BookArchive, removing ids: Set<UUID>) throws -> [UUID]

    // MARK: Notes (at most one note per (book, target); an empty note is never stored)

    /// The note for this target, or `nil` (show an empty placeholder; do not create a record).
    func note(bookID: UUID, target: NoteTarget) throws -> Note?
    /// The note with this ID, or `nil`.
    func note(id: UUID) throws -> Note?
    /// Every note of the book (page and heading notes), in no particular order.
    func notes(bookID: UUID) throws -> [Note]
    /// Page notes whose page index lies in `pages`, ascending by page index.
    func pageNotes(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Note]
    /// Number of notes of the book.
    func noteCount(bookID: UUID) throws -> Int
    /// `save(_:)`'s work for a note (see there for the upsert rules and errors).
    func storeNote(_ note: Note) throws -> NoteStoreOutcome
    /// Deletes the note with this ID and returns it as it was stored (`nil` if unknown).
    func removeNote(id: UUID) throws -> Note?
    /// `retarget(noteID:to:)`'s work. Returns the note as it was before the move, or `nil` when
    /// it was already at `target`.
    func moveNote(id: UUID, to target: NoteTarget) throws -> Note?

    // MARK: Highlights

    /// The highlight with this ID, or `nil`.
    func highlight(id: UUID) throws -> Highlight?
    /// All highlights of the book, sorted by `Highlight.readingOrder`.
    func highlights(bookID: UUID) throws -> [Highlight]
    /// Highlights on one page, sorted by `Highlight.readingOrder`.
    func highlights(bookID: UUID, pageIndex: Int) throws -> [Highlight]
    /// Highlights on pages in `pages`, sorted by `Highlight.readingOrder`.
    func highlights(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Highlight]
    /// Number of highlights of the book.
    func highlightCount(bookID: UUID) throws -> Int
    /// Inserts or replaces the highlight with `highlight.id` and returns the one it replaced.
    /// Throws `.bookNotFound` for an unknown book.
    func storeHighlight(_ highlight: Highlight) throws -> Highlight?
    /// Deletes the highlight and returns it as it was stored (`nil` if unknown).
    func removeHighlight(id: UUID) throws -> Highlight?

    // MARK: Bookmarks (at most one per (book, page))

    /// The book's bookmarks, ascending by page index.
    func bookmarks(bookID: UUID) throws -> [Bookmark]
    /// Whether the page is bookmarked.
    func isBookmarked(bookID: UUID, pageIndex: Int) throws -> Bool
    /// Adds (`true`) or removes (`false`) the page's bookmark and returns whether the page's
    /// bookmark state changed. Idempotent: adding an existing bookmark keeps the existing
    /// record. Throws `.bookNotFound` for an unknown book when adding.
    func storeBookmark(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws -> Bool

    // MARK: User headings (the PDF's own headings are never stored)

    /// The book's user headings, in no particular order (`Outline` orders them).
    func userHeadings(bookID: UUID) throws -> [UserHeading]
    /// The user heading with this ID, or `nil`.
    func userHeading(id: UUID) throws -> UserHeading?
    /// Inserts or replaces the user heading with `heading.id` and returns the one it replaced.
    /// Throws `.bookNotFound` for an unknown book.
    func storeUserHeading(_ heading: UserHeading) throws -> UserHeading?
    /// Deletes the user heading and returns it as it was stored (`nil` if unknown).
    func removeUserHeading(id: UUID) throws -> UserHeading?
}

// MARK: The writes the app calls (each announces what it changed)

extension RecordStore {
    private func post(_ changes: [StoreChange]) {
        guard !changes.isEmpty else { return }
        changePoster?.post(changes)
    }

    /// Inserts or replaces the book with `book.id`. Posts `.bookSaved`.
    public func save(_ book: Book) throws {
        try storeBook(book)
        post([.bookSaved(bookID: book.id)])
    }

    /// Deletes the book and, in the same transaction, all of its notes, highlights, bookmarks
    /// and user headings. Does not touch files (call `InkStore.removeBook` and remove the PDF,
    /// or use `LibraryStore.deleteBook(id:origin:)`). Deleting an unknown ID is a no-op. Posts
    /// `.bookDeleted` if the book existed.
    public func deleteBook(id: UUID) throws {
        if try removeBook(id: id) { post([.bookDeleted(bookID: id)]) }
    }

    /// Replaces whole books with one archive, in one transaction (all or nothing; the restore of
    /// a backup).
    ///
    /// Deletes the book and every record (notes, highlights, bookmarks, user headings) of each ID
    /// in `ids` and of `archive.book.id` (unknown IDs are skipped), then inserts `archive.book`
    /// and all of the archive's records verbatim: IDs, dates and every other field unchanged.
    /// Idempotent: a second call with the same arguments leaves the same state. Does not touch
    /// files (the caller moves the books' directories).
    ///
    /// Refuses, changing nothing, with:
    /// - the archive's own errors, in this order (`BookArchive.validateForReplacement()`):
    ///   `.archiveInconsistent`, `.archiveDuplicateRecordID`, `.archiveDuplicateNoteTarget`,
    ///   `.archiveDuplicateBookmarkPage`, `.archiveEmptyNote`;
    /// - `.fingerprintInUse` when a book outside `ids ∪ {archive.book.id}` has
    ///   `archive.book.fingerprint`;
    /// - `.recordOwnedByOtherBook` when a record ID in the archive is stored for a book outside
    ///   `ids ∪ {archive.book.id}`.
    ///
    /// Posts `.bookDeleted` for each ID of `ids ∪ {archive.book.id}` whose book existed
    /// (ascending by `uuidString`), then `.bookSaved(archive.book.id)`.
    public func replaceBook(_ archive: BookArchive, removing ids: Set<UUID>) throws {
        let existed = try storeArchive(archive, removing: ids).sorted { $0.uuidString < $1.uuidString }
        post(existed.map { .bookDeleted(bookID: $0) } + [.bookSaved(bookID: archive.book.id)])
    }

    /// Upsert by target.
    /// - If `note.isEmpty`: deletes the stored note for `(note.bookID, note.target)` if any and
    ///   returns `nil`.
    /// - Else if no note exists for the target: inserts `note` (keeping `note.id`) and returns it.
    /// - Else if the stored note for the target has `note.id`: replaces all its fields; returns it.
    /// - Else throws `.noteTargetOccupied(existingNoteID:)`.
    /// Throws `.noteTargetMismatch` if `note.id` is stored under another target, and
    /// `.bookNotFound` if the book does not exist. Fields are stored verbatim (the caller sets
    /// `modifiedAt`). Posts `.noteSaved` for a stored note, `.noteRemoved` for a deleted one.
    @discardableResult
    public func save(_ note: Note) throws -> Note? {
        switch try storeNote(note) {
        case .stored(let saved):
            post([.noteSaved(bookID: saved.bookID, target: saved.target, noteID: saved.id)])
            return saved
        case .removed(let existing):
            post([.noteRemoved(bookID: existing.bookID, target: existing.target, noteID: existing.id)])
            return nil
        case .unchanged:
            return nil
        }
    }

    /// Deletes the note with this ID (no-op if unknown). The caller deletes its ink file (or
    /// uses `LibraryStore.deleteNote(id:origin:)`). Posts `.noteRemoved` if it existed.
    public func deleteNote(id: UUID) throws {
        if let existing = try removeNote(id: id) {
            post([.noteRemoved(bookID: existing.bookID, target: existing.target, noteID: id)])
        }
    }

    /// Moves a note to another target of the same book (used to repair stale heading anchors
    /// after `Outline.resolveAll`). No-op if already there; throws `.noteTargetOccupied` if
    /// another note has that target, `.notFound` for an unknown ID. Posts `.noteRemoved` for the
    /// old target, then `.noteSaved` for the new one, when the note moved.
    public func retarget(noteID: UUID, to target: NoteTarget) throws {
        if let existing = try moveNote(id: noteID, to: target), existing.target != target {
            post([.noteRemoved(bookID: existing.bookID, target: existing.target, noteID: noteID),
                  .noteSaved(bookID: existing.bookID, target: target, noteID: noteID)])
        }
    }

    /// Inserts or replaces the highlight with `highlight.id` (recolour = save with a new
    /// colour). Throws `.bookNotFound` for an unknown book. Posts `.highlightsChanged` for its
    /// page, after one for the previous page if an existing highlight moved pages.
    public func save(_ highlight: Highlight) throws {
        let existing = try storeHighlight(highlight)
        var changes: [StoreChange] = []
        if let existing, existing.pageIndex != highlight.pageIndex || existing.bookID != highlight.bookID {
            changes.append(.highlightsChanged(bookID: existing.bookID, pageIndex: existing.pageIndex))
        }
        changes.append(.highlightsChanged(bookID: highlight.bookID, pageIndex: highlight.pageIndex))
        post(changes)
    }

    /// Deletes the highlight (no-op if unknown). Posts `.highlightsChanged` if it existed.
    public func deleteHighlight(id: UUID) throws {
        if let existing = try removeHighlight(id: id) {
            post([.highlightsChanged(bookID: existing.bookID, pageIndex: existing.pageIndex)])
        }
    }

    /// Adds (`true`) or removes (`false`) the page's bookmark. Idempotent: adding an existing
    /// bookmark keeps the existing record. Throws `.bookNotFound` for an unknown book when
    /// adding. Posts `.bookmarksChanged` only if the page's bookmark state changed.
    public func setBookmarked(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws {
        if try storeBookmark(bookmarked, bookID: bookID, pageIndex: pageIndex) {
            post([.bookmarksChanged(bookID: bookID, pageIndex: pageIndex)])
        }
    }

    /// Inserts or replaces the user heading with `heading.id` (rename, move).
    /// Throws `.bookNotFound` for an unknown book. Posts `.userHeadingsChanged` for its book,
    /// after one for the previous book if an existing heading changed books.
    public func save(_ heading: UserHeading) throws {
        let existing = try storeUserHeading(heading)
        var changes: [StoreChange] = []
        if let existing, existing.bookID != heading.bookID { changes.append(.userHeadingsChanged(bookID: existing.bookID)) }
        changes.append(.userHeadingsChanged(bookID: heading.bookID))
        post(changes)
    }

    /// Deletes the user heading (no-op if unknown). Does not touch its notes or its child
    /// headings: before deleting, the caller should re-parent children to the deleted heading's
    /// `parent` (otherwise they become top level), and should delete or keep its heading note
    /// (a kept note becomes an orphan in the Notebook). Posts `.userHeadingsChanged` if it
    /// existed.
    public func deleteUserHeading(id: UUID) throws {
        if let existing = try removeUserHeading(id: id) {
            post([.userHeadingsChanged(bookID: existing.bookID)])
        }
    }
}

/// File storage for ink drawings: one blob per page and one per note.
///
/// Data is opaque here (page ink and the note page store `PKDrawing.dataRepresentation()` or their own container).
/// **Presence means ink:** callers delete rather than save an empty drawing, so
/// `inkedPageIndices` is the set of pages with ink. Writes are atomic (a reader sees the old or
/// the new blob, never a partial one). All deletes are idempotent: deleting something missing
/// succeeds. File layout: `BookStorageLayout`.
public protocol InkStore: Sendable {
    /// The page's ink, or `nil` if none.
    func pageInk(bookID: UUID, pageIndex: Int) async throws -> Data?
    /// Atomically writes the page's ink, replacing any previous blob.
    func savePageInk(_ data: Data, bookID: UUID, pageIndex: Int) async throws
    /// Removes the page's ink.
    func deletePageInk(bookID: UUID, pageIndex: Int) async throws
    /// Page indices that have ink, ascending.
    func inkedPageIndices(bookID: UUID) async throws -> [Int]
    /// The note's ink, or `nil` if none.
    func noteInk(bookID: UUID, noteID: UUID) async throws -> Data?
    /// Atomically writes the note's ink, replacing any previous blob.
    func saveNoteInk(_ data: Data, bookID: UUID, noteID: UUID) async throws
    /// Removes the note's ink.
    func deleteNoteInk(bookID: UUID, noteID: UUID) async throws
    /// Removes the book's whole directory (`BookStorageLayout.bookDirectory`): page ink, note
    /// ink, and anything else stored there (the PDF copy and cover if the importer puts them there).
    func removeBook(bookID: UUID) async throws
}

/// Relative paths of a book's files under the app's `Application Support` directory, so the
/// importer and the ink store (ReaderStore) agree. UUIDs are written with `uuidString`
/// (upper case); page files use the zero-based page index.
public enum BookStorageLayout {
    /// `Books/<bookID>`
    public static func bookDirectory(bookID: UUID) -> String {
        "Books/\(bookID.uuidString)"
    }
    /// `Books/<bookID>/<fileName>`: the imported PDF copy.
    public static func documentPath(bookID: UUID, fileName: String) -> String {
        "\(bookDirectory(bookID: bookID))/\(fileName)"
    }
    /// File name of the kept original of a converted book: `original.<ext>` (`original` when the
    /// source had no extension). The extension is lower-cased.
    public static func originalFileName(extension ext: String) -> String {
        ext.isEmpty ? "original" : "original.\(ext.lowercased())"
    }
    /// Whether `name`, an entry at the top of a book's directory, is the kept original of a
    /// converted book (`originalFileName(extension:)`; a file, or a directory for a package such
    /// as a Pages document).
    public static func isOriginalFileName(_ name: String) -> Bool {
        name == "original" || (name.hasPrefix("original.") && !name.dropFirst("original.".count).contains("."))
    }
    /// `Books/<bookID>/original.<ext>`: the unmodified file a converted book was made from.
    public static func originalPath(bookID: UUID, extension ext: String) -> String {
        "\(bookDirectory(bookID: bookID))/\(originalFileName(extension: ext))"
    }
    /// `Books/<bookID>/ink`
    public static func pageInkDirectory(bookID: UUID) -> String {
        "\(bookDirectory(bookID: bookID))/ink"
    }
    /// `Books/<bookID>/ink/<pageIndex>.drawing`
    public static func pageInkPath(bookID: UUID, pageIndex: Int) -> String {
        "\(pageInkDirectory(bookID: bookID))/\(pageIndex).drawing"
    }
    /// `Books/<bookID>/notes`
    public static func noteInkDirectory(bookID: UUID) -> String {
        "\(bookDirectory(bookID: bookID))/notes"
    }
    /// `Books/<bookID>/notes/<noteID>.drawing`
    public static func noteInkPath(bookID: UUID, noteID: UUID) -> String {
        "\(noteInkDirectory(bookID: bookID))/\(noteID.uuidString).drawing"
    }
    /// File name of the full-content hash sidecar inside a book's directory.
    public static let contentHashFileName = "document.sha256"
    /// `Books/<bookID>/document.sha256`: JSON `{"sha256": <64 hex digits>, "size": <bytes>}` of the
    /// book's PDF. Written when the hash is first computed (the imported PDF never changes), and
    /// written from a backup's manifest when a book is restored without its PDF, in which case it
    /// is the hash a PDF must match to be linked to the book.
    public static func contentHashPath(bookID: UUID) -> String {
        "\(bookDirectory(bookID: bookID))/\(contentHashFileName)"
    }
    /// The page index encoded in a page-ink file name (`"311.drawing"` → `311`), or `nil`.
    public static func pageIndex(fromPageInkFileName name: String) -> Int? {
        guard name.hasSuffix(".drawing") else { return nil }
        let stem = name.dropLast(".drawing".count)
        guard !stem.isEmpty, stem.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(stem)
    }
}
