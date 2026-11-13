import Foundation

// MARK: - Concurrency
//
// The record repositories are `@MainActor` protocols with synchronous `throws` methods that take
// and return value types. WP2 implements them with SwiftData on the main `ModelContext`, and they
// are called from `@MainActor` SwiftUI / `@Observable` code, so main-actor isolation is the
// honest contract: no `@Model` object ever crosses an actor boundary, and callers need no `await`
// for small, indexed reads and writes. Anything that must not run on the main thread (outline
// building, notebook building, export) takes the value types these return.
//
// `InkStore` does file I/O of up to megabytes and is `Sendable` with `async throws` methods so
// implementations can do the work off the main thread (an `actor` or a type with a private queue).
//
// Repositories never touch files: deleting a note or a book must be followed by the matching
// `InkStore` call by the caller (all `InkStore` deletes are idempotent, so a repository that
// also schedules them does no harm). `LibraryStore` provides the compound operations that do
// both, and wraps every repository so each successful mutation posts a `StoreChange`; app code
// should mutate through `LibraryStore`, never through a raw repository.

/// Errors every repository implementation must report in these situations.
public enum RepositoryError: Error, Hashable, Sendable {
    /// A record referenced a book that does not exist.
    case bookNotFound(UUID)
    /// `NoteRepository.save` or `retarget` would create a second note for a target that already
    /// has one (with this ID).
    case noteTargetOccupied(existingNoteID: UUID)
    /// `NoteRepository.save` was given a note whose ID is stored under a different target; use
    /// `retarget(noteID:to:)` to move a note.
    case noteTargetMismatch(noteID: UUID)
    /// The record with this ID does not exist.
    case notFound(UUID)
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
    /// Record counts from `BookRepository.recordCounts(bookID:)`.
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

/// Books in the library.
@MainActor
public protocol BookRepository {
    /// All books, in no particular order (the Library sorts).
    func allBooks() throws -> [Book]
    /// The book with this ID, or `nil`.
    func book(id: UUID) throws -> Book?
    /// The book with this content fingerprint, or `nil` (import de-duplication).
    func book(fingerprint: String) throws -> Book?
    /// Inserts or replaces the book with `book.id`.
    func save(_ book: Book) throws
    /// Deletes the book and, in the same transaction, all of its notes, highlights, bookmarks
    /// and user headings. Does not touch files (call `InkStore.removeBook` and remove the PDF).
    /// Deleting an unknown ID is a no-op.
    func deleteBook(id: UUID) throws
    /// Counts of the records `deleteBook` would remove (all zero for an unknown book).
    func recordCounts(bookID: UUID) throws -> BookRecordCounts
}

/// Notes. **At most one note per (book, target)**; an empty note is never stored.
@MainActor
public protocol NoteRepository {
    /// The note for this target, or `nil` (show an empty placeholder; do not create a record).
    func note(bookID: UUID, target: NoteTarget) throws -> Note?
    /// The note with this ID, or `nil`.
    func note(id: UUID) throws -> Note?
    /// Every note of the book (page and heading notes), in no particular order.
    func notes(bookID: UUID) throws -> [Note]
    /// Page notes whose page index lies in `pages`, ascending by page index ("page notes in this
    /// section").
    func pageNotes(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Note]
    /// Upsert by target.
    /// - If `note.isEmpty`: deletes the stored note for `(note.bookID, note.target)` if any and
    ///   returns `nil`.
    /// - Else if no note exists for the target: inserts `note` (keeping `note.id`) and returns it.
    /// - Else if the stored note for the target has `note.id`: replaces all its fields; returns it.
    /// - Else throws `.noteTargetOccupied(existingNoteID:)`.
    /// Throws `.noteTargetMismatch` if `note.id` is stored under another target, and
    /// `.bookNotFound` if the book does not exist. Fields are stored verbatim (the caller sets
    /// `modifiedAt`).
    @discardableResult
    func save(_ note: Note) throws -> Note?
    /// Deletes the note with this ID (no-op if unknown). The caller deletes its ink file.
    func deleteNote(id: UUID) throws
    /// Moves a note to another target of the same book (used to repair stale heading anchors
    /// after `Outline.resolveAll`). No-op if already there; throws `.noteTargetOccupied` if
    /// another note has that target, `.notFound` for an unknown ID.
    func retarget(noteID: UUID, to target: NoteTarget) throws
    /// Number of notes of the book.
    func noteCount(bookID: UUID) throws -> Int
}

/// Text highlights.
@MainActor
public protocol HighlightRepository {
    /// The highlight with this ID, or `nil`.
    func highlight(id: UUID) throws -> Highlight?
    /// All highlights of the book, sorted by `Highlight.readingOrder`.
    func highlights(bookID: UUID) throws -> [Highlight]
    /// Highlights on one page, sorted by `Highlight.readingOrder`.
    func highlights(bookID: UUID, pageIndex: Int) throws -> [Highlight]
    /// Highlights on pages in `pages`, sorted by `Highlight.readingOrder`.
    func highlights(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Highlight]
    /// Inserts or replaces the highlight with `highlight.id` (recolour = save with a new
    /// colour). Throws `.bookNotFound` for an unknown book.
    func save(_ highlight: Highlight) throws
    /// Deletes the highlight (no-op if unknown).
    func deleteHighlight(id: UUID) throws
    /// Number of highlights of the book.
    func highlightCount(bookID: UUID) throws -> Int
}

/// Page bookmarks. At most one per (book, page).
@MainActor
public protocol BookmarkRepository {
    /// The book's bookmarks, ascending by page index.
    func bookmarks(bookID: UUID) throws -> [Bookmark]
    /// Whether the page is bookmarked.
    func isBookmarked(bookID: UUID, pageIndex: Int) throws -> Bool
    /// Adds (`true`) or removes (`false`) the page's bookmark. Idempotent: adding an existing
    /// bookmark keeps the existing record. Throws `.bookNotFound` for an unknown book when adding.
    func setBookmarked(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws
}

/// User headings (the PDF's own headings are never stored).
@MainActor
public protocol HeadingRepository {
    /// The book's user headings, in no particular order (`Outline` orders them).
    func userHeadings(bookID: UUID) throws -> [UserHeading]
    /// The user heading with this ID, or `nil`.
    func userHeading(id: UUID) throws -> UserHeading?
    /// Inserts or replaces the user heading with `heading.id` (rename, move).
    /// Throws `.bookNotFound` for an unknown book.
    func save(_ heading: UserHeading) throws
    /// Deletes the user heading (no-op if unknown). Does not touch its notes or its child
    /// headings: before deleting, the caller should re-parent children to the deleted heading's
    /// `parent` (otherwise they become top level), and should delete or keep its heading note
    /// (a kept note becomes an orphan in the Notebook).
    func deleteUserHeading(id: UUID) throws
}

/// File storage for ink drawings: one blob per page and one per note.
///
/// Data is opaque here (WP6/WP13 store `PKDrawing.dataRepresentation()` or their own container).
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
    /// ink, and anything else stored there (the PDF copy and cover if WP3 puts them there).
    func removeBook(bookID: UUID) async throws
}

/// Relative paths of a book's files under the app's `Application Support` directory, so the
/// importer (WP3) and the ink store (WP2) agree. UUIDs are written with `uuidString`
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
    /// The page index encoded in a page-ink file name (`"311.drawing"` → `311`), or `nil`.
    public static func pageIndex(fromPageInkFileName name: String) -> Int? {
        guard name.hasSuffix(".drawing") else { return nil }
        let stem = name.dropLast(".drawing".count)
        guard !stem.isEmpty, stem.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(stem)
    }
}
