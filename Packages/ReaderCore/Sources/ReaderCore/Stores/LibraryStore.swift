import Foundation

/// Errors from `LibraryStore`'s compound operations.
public enum LibraryStoreError: Error, Hashable, Sendable {
    /// `deleteBook` removed the book's records (and posted `.bookDeleted`) but removing its
    /// directory failed. The book is gone from the app; its files are left behind. Retry with
    /// `LibraryStore.removeBookFiles(bookID:)`; a launch-time sweep of `Books/` directories that
    /// have no `Book` record is the backstop.
    case bookFilesNotRemoved(bookID: UUID, reason: String)
    /// `deleteNote` removed the note record (and posted `.noteRemoved`) but deleting its ink file
    /// failed. Retry with `LibraryStore.deleteNoteInk(bookID:noteID:origin:)`.
    case noteInkNotRemoved(bookID: UUID, noteID: UUID, reason: String)
}

/// The one object the app holds for stored data, shared by every window.
///
/// - Records live in one `RecordStore` (`records`). `books`, `notes`, `highlights`, `bookmarks`
///   and `headings` are that same store under the five names the app reads and writes it by
///   (`store.notes.save(note)`). Every successful write through it posts the `StoreChange`s
///   listed below on `hub` (the store does the posting itself, from what the write replaced or
///   removed: `RecordStore`); a write that throws posts nothing.
/// - **Origin attribution:** posts made inside `perform(as:_:)` carry that origin; posts made
///   outside it carry `nil`. The async ink and compound methods take `origin:` explicitly.
/// - Ink: read with `pageInk`/`noteInk`/`inkedPageIndices` (or `inkStore` directly); write only
///   with the `LibraryStore` methods, which post after the write succeeds.
/// - Files: `rootDirectory` is the directory `BookStorageLayout` paths are relative to (the app's
///   `Application Support` directory in the live app).
///
/// **What posts what** (checked for every store by `RepositoryConformance.verifyChangePosting`):
/// - `books.save(book)` → `.bookSaved(book.id)`.
/// - `books.deleteBook(id)` → `.bookDeleted(id)` if the book existed; nothing otherwise.
///   (Records only; prefer `deleteBook(id:origin:)`, which also removes files.)
/// - `books.replaceBook(archive, removing: ids)` → `.bookDeleted(id)` for each ID of
///   `ids ∪ {archive.book.id}` whose book existed (ascending by `uuidString`), then
///   `.bookSaved(archive.book.id)`. The deletes come first on purpose: reader and Notebook windows
///   on a replaced book close, exactly as for a delete. (Records only; the caller moves files.)
/// - `notes.save(note)` returning a note → `.noteSaved(bookID, target, id)`; returning `nil`
///   (empty note) → `.noteRemoved(bookID, target, existing.id)` if a note existed there, else nothing.
/// - `notes.deleteNote(id)` → `.noteRemoved(bookID, target, id)` if it existed.
/// - `notes.retarget(noteID, to)` → `.noteRemoved(old target)` then `.noteSaved(new target)`,
///   if the note existed and the target differs; nothing for a no-op.
/// - `highlights.save(h)` → `.highlightsChanged(bookID, h.pageIndex)`, plus the previous page if
///   an existing highlight moved pages.
/// - `highlights.deleteHighlight(id)` → `.highlightsChanged(bookID, page)` if it existed.
/// - `bookmarks.setBookmarked(b, bookID, page)` → `.bookmarksChanged(bookID, page)` only if the
///   page's bookmark state actually changed.
/// - `bookmarks.save(b)` (a record stored verbatim, by merge and sync) → `.bookmarksChanged` for
///   each other page a replaced bookmark was on, then for `b`'s page; nothing if unchanged.
/// - `headings.save(h)` → `.userHeadingsChanged(h.bookID)`; `deleteUserHeading(id)` → the same
///   for its book if it existed.
/// - `savePageInk`/`deletePageInk` → `.pageInkChanged(bookID, page)`;
///   `saveNoteInk`/`deleteNoteInk` → `.noteInkChanged(bookID, noteID)` (deletes post even if no
///   file existed, since the ink store cannot tell).
/// - `saveRecognisedPage` → `.recognisedTextChanged(bookID, page.pageIndex)`;
///   `removeRecognisedText` → `.recognisedTextChanged(bookID, nil)`;
///   `saveRecognitionState` → `.recognitionStateChanged(bookID)` (also when removing it).
/// - `deleteBook(id:origin:)` → `.bookDeleted(id)` (once, after the records are gone).
/// - `deleteNote(id:origin:)` → `.noteRemoved(…)`, then `.noteInkChanged(…)` if the note had ink.
@MainActor
public final class LibraryStore {
    /// The change signal every window observes.
    public let hub: StoreChangeHub
    /// Directory that `BookStorageLayout` relative paths resolve against.
    public let rootDirectory: URL
    /// The record store: every book, note, highlight, bookmark and user heading. Its writes post
    /// on `hub`.
    public let records: any RecordStore
    /// `records`, read as the books.
    public var books: any RecordStore { records }
    /// `records`, read as the notes.
    public var notes: any RecordStore { records }
    /// `records`, read as the highlights.
    public var highlights: any RecordStore { records }
    /// `records`, read as the bookmarks.
    public var bookmarks: any RecordStore { records }
    /// `records`, read as the user headings.
    public var headings: any RecordStore { records }
    /// The raw ink store. **Read only**: writes through it post no change; use the `LibraryStore`
    /// ink methods instead.
    public let inkStore: any InkStore
    /// The pages with page ink of each book, cached and kept current from this store's hub
    /// (shared by every window; see `InkedPagesCache`).
    public let inkedPages: InkedPagesCache
    /// The raw recognised-text store of scanned books. **Read only** (and only off the main
    /// thread: it is synchronous file I/O): writes through it post no change; use the
    /// `LibraryStore` recognised-text methods instead.
    public let recognisedText: any RecognisedTextStore

    private let context: StoreChangePoster

    /// Builds the store from a record store, an ink store and a recognised-text store. The
    /// record store becomes this store's: its writes post on this store's hub from now on (one
    /// `LibraryStore` per record store).
    /// - Parameter recognisedText: scanned books' recognised text and state; an
    ///   `InMemoryRecognisedTextStore` when `nil`.
    /// - Parameter hub: the hub to post on; a new one when `nil`.
    public init(records: some RecordStore, inkStore: some InkStore, rootDirectory: URL,
                recognisedText: (any RecognisedTextStore)? = nil, hub: StoreChangeHub? = nil) {
        let hub = hub ?? StoreChangeHub()
        let context = StoreChangePoster(hub: hub)
        self.hub = hub
        self.context = context
        self.rootDirectory = rootDirectory
        records.changePoster = context
        self.records = records
        self.inkStore = inkStore
        self.inkedPages = InkedPagesCache(inkStore: inkStore, hub: hub)
        self.recognisedText = recognisedText ?? InMemoryRecognisedTextStore()
    }

    /// A store backed by `InMemoryRecordStore` and `InMemoryInkStore`, for previews, unit tests,
    /// and running the app before a persistent store exists. Nothing is written to disk by the
    /// store itself; `rootDirectory` only feeds the URL helpers (default: a `TactileTextsInMemory`
    /// folder in the temporary directory).
    public static func inMemory(rootDirectory: URL? = nil) -> LibraryStore {
        let records = InMemoryRecordStore()
        let root = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("TactileTextsInMemory", isDirectory: true)
        return LibraryStore(records: records, inkStore: InMemoryInkStore(), rootDirectory: root)
    }

    // MARK: Origin

    /// The origin attached to record-store posts right now: the innermost `perform(as:_:)` in
    /// progress, else `nil`.
    public var currentOrigin: ChangeOrigin? { context.origin }

    /// Runs `body` with `origin` attached to every change the record store posts inside
    /// it. Nesting-safe: the previous origin is restored when `body` returns or throws; an inner
    /// `perform(as: nil)` makes posts unattributed for its duration.
    ///
    ///     try store.perform(as: session.origin) { try store.notes.save(note) }
    public func perform<T>(as origin: ChangeOrigin?, _ body: () throws -> T) rethrows -> T {
        let previous = context.origin
        context.origin = origin
        defer { context.origin = previous }
        return try body()
    }

    // MARK: Ink

    /// The page's ink, or `nil`.
    public func pageInk(bookID: UUID, pageIndex: Int) async throws -> Data? {
        try await inkStore.pageInk(bookID: bookID, pageIndex: pageIndex)
    }

    /// The note's ink, or `nil`.
    public func noteInk(bookID: UUID, noteID: UUID) async throws -> Data? {
        try await inkStore.noteInk(bookID: bookID, noteID: noteID)
    }

    /// Pages with ink, ascending.
    public func inkedPageIndices(bookID: UUID) async throws -> [Int] {
        try await inkStore.inkedPageIndices(bookID: bookID)
    }

    /// Writes the page's ink (off the main actor), then posts `.pageInkChanged`. Save an empty
    /// drawing with `deletePageInk` instead.
    public func savePageInk(_ data: Data, bookID: UUID, pageIndex: Int, origin: ChangeOrigin?) async throws {
        try await inkStore.savePageInk(data, bookID: bookID, pageIndex: pageIndex)
        hub.post(.pageInkChanged(bookID: bookID, pageIndex: pageIndex), origin: origin)
    }

    /// Deletes the page's ink, then posts `.pageInkChanged`.
    public func deletePageInk(bookID: UUID, pageIndex: Int, origin: ChangeOrigin?) async throws {
        try await inkStore.deletePageInk(bookID: bookID, pageIndex: pageIndex)
        hub.post(.pageInkChanged(bookID: bookID, pageIndex: pageIndex), origin: origin)
    }

    /// Writes the note's ink, then posts `.noteInkChanged`. (The note record, with `hasInk` and
    /// `bandLayout`, is saved separately through `notes`.)
    public func saveNoteInk(_ data: Data, bookID: UUID, noteID: UUID, origin: ChangeOrigin?) async throws {
        try await inkStore.saveNoteInk(data, bookID: bookID, noteID: noteID)
        hub.post(.noteInkChanged(bookID: bookID, noteID: noteID), origin: origin)
    }

    /// Deletes the note's ink, then posts `.noteInkChanged`.
    public func deleteNoteInk(bookID: UUID, noteID: UUID, origin: ChangeOrigin?) async throws {
        try await inkStore.deleteNoteInk(bookID: bookID, noteID: noteID)
        hub.post(.noteInkChanged(bookID: bookID, noteID: noteID), origin: origin)
    }

    // MARK: Recognised text (scanned books)

    /// The recognised page, or `nil`. Read off the main actor.
    public func recognisedPage(bookID: UUID, pageIndex: Int) async throws -> RecognisedPage? {
        let store = recognisedText
        return try await Task.detached { try store.recognisedPage(bookID: bookID, pageIndex: pageIndex) }.value
    }

    /// Pages of the book that have been recognised, ascending. Read off the main actor.
    public func recognisedPageIndices(bookID: UUID) async throws -> [Int] {
        let store = recognisedText
        return try await Task.detached { try store.recognisedPageIndices(bookID: bookID) }.value
    }

    /// The book's recognition state, or `nil` when it has none. Read off the main actor.
    public func recognitionState(bookID: UUID) async throws -> RecognitionState? {
        let store = recognisedText
        return try await Task.detached { try store.recognitionState(bookID: bookID) }.value
    }

    /// Writes a recognised page (off the main actor), then posts
    /// `.recognisedTextChanged(bookID, page.pageIndex)`.
    public func saveRecognisedPage(_ page: RecognisedPage, bookID: UUID, origin: ChangeOrigin?) async throws {
        let store = recognisedText
        try await Task.detached { try store.saveRecognisedPage(page, bookID: bookID) }.value
        hub.post(.recognisedTextChanged(bookID: bookID, pageIndex: page.pageIndex), origin: origin)
    }

    /// Removes all of the book's recognised pages (not its state), then posts
    /// `.recognisedTextChanged(bookID, nil)`.
    public func removeRecognisedText(bookID: UUID, origin: ChangeOrigin?) async throws {
        let store = recognisedText
        try await Task.detached { try store.removeRecognisedText(bookID: bookID) }.value
        hub.post(.recognisedTextChanged(bookID: bookID, pageIndex: nil), origin: origin)
    }

    /// Writes the book's recognition state (`nil` removes it), then posts
    /// `.recognitionStateChanged(bookID)`.
    public func saveRecognitionState(_ state: RecognitionState?, bookID: UUID, origin: ChangeOrigin?) async throws {
        let store = recognisedText
        try await Task.detached { try store.saveRecognitionState(state, bookID: bookID) }.value
        hub.post(.recognitionStateChanged(bookID: bookID), origin: origin)
    }

    // MARK: Compound operations

    /// Counts for the delete-book confirmation: records from `books.recordCounts` and the number
    /// of inked pages from the ink store.
    public func deletionSummary(bookID: UUID) async throws -> BookDeletionSummary {
        let records = try books.recordCounts(bookID: bookID)
        let inked = try await inkStore.inkedPageIndices(bookID: bookID).count
        return BookDeletionSummary(records: records, inkedPages: inked)
    }

    /// Deletes a book completely: first its records (cascade, posting `.bookDeleted` once if the
    /// book existed), then its directory (`inkStore.removeBook`: ink, note ink, recognised text
    /// and its state, and the PDF and cover if stored there; then `recognisedText.removeBook`
    /// for a store that keeps them elsewhere). Records go first so a failure never leaves a
    /// visible book whose files are missing.
    /// - Throws: a repository error (nothing deleted, nothing posted), or
    ///   `LibraryStoreError.bookFilesNotRemoved` when the records are already gone and posted but
    ///   the directory could not be removed.
    public func deleteBook(id: UUID, origin: ChangeOrigin?) async throws {
        try perform(as: origin) { try books.deleteBook(id: id) }
        try await removeBookFiles(bookID: id)
    }

    /// Removes the book's directory through the ink store, and its recognised text and state
    /// through the recognised-text store (already gone with the directory for the file-backed
    /// store; idempotent). Posts nothing. Use to retry after `bookFilesNotRemoved`.
    /// - Throws: `LibraryStoreError.bookFilesNotRemoved` wrapping the stores' error.
    public func removeBookFiles(bookID: UUID) async throws {
        do {
            try await inkStore.removeBook(bookID: bookID)
            let store = recognisedText
            try await Task.detached { try store.removeBook(bookID: bookID) }.value
        } catch {
            throw LibraryStoreError.bookFilesNotRemoved(bookID: bookID, reason: String(describing: error))
        }
    }

    /// Deletes a note and its ink: the record first (posting `.noteRemoved`), then the ink file,
    /// posting `.noteInkChanged` if the note had ink. An unknown ID is a no-op (nothing posted).
    /// - Throws: a repository error (nothing deleted or posted), or
    ///   `LibraryStoreError.noteInkNotRemoved` when the record is gone but the ink file is not.
    public func deleteNote(id: UUID, origin: ChangeOrigin?) async throws {
        guard let note = try notes.note(id: id) else { return }
        try perform(as: origin) { try notes.deleteNote(id: id) }
        do {
            try await inkStore.deleteNoteInk(bookID: note.bookID, noteID: id)
        } catch {
            throw LibraryStoreError.noteInkNotRemoved(bookID: note.bookID, noteID: id, reason: String(describing: error))
        }
        if note.hasInk {
            hub.post(.noteInkChanged(bookID: note.bookID, noteID: id), origin: origin)
        }
    }

    // MARK: Archives

    /// Everything the record store holds for the book, as one value (the unit of backup), or
    /// `nil` for an unknown book. Read in one synchronous main-actor pass through the record
    /// store, so it is a consistent snapshot: no mutation can land between the reads.
    /// Records are in the order the record store returns them (highlights in reading order,
    /// bookmarks by page; notes and user headings in no particular order).
    public func archive(bookID: UUID) throws -> BookArchive? {
        guard let book = try books.book(id: bookID) else { return nil }
        return BookArchive(book: book, notes: try notes.notes(bookID: bookID),
                           highlights: try highlights.highlights(bookID: bookID),
                           bookmarks: try bookmarks.bookmarks(bookID: bookID),
                           userHeadings: try headings.userHeadings(bookID: bookID))
    }

    // MARK: File locations

    /// `rootDirectory` + a `BookStorageLayout` relative path.
    public func url(forRelativePath path: String) -> URL {
        rootDirectory.appendingPathComponent(path, isDirectory: false)
    }

    /// `<root>/Books/<bookID>`
    public func bookDirectoryURL(bookID: UUID) -> URL {
        rootDirectory.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: bookID), isDirectory: true)
    }

    /// `<root>/Books/<book.id>/<book.fileName>`: the imported PDF.
    public func documentURL(for book: Book) -> URL {
        url(forRelativePath: BookStorageLayout.documentPath(bookID: book.id, fileName: book.fileName))
    }

    /// `<root>/Books/<bookID>/document.sha256`: the PDF's full-content hash sidecar
    /// (`BookStorageLayout.contentHashPath`). Callable from any thread.
    public nonisolated func contentHashURL(bookID: UUID) -> URL {
        rootDirectory.appendingPathComponent(BookStorageLayout.contentHashPath(bookID: bookID), isDirectory: false)
    }

    /// Whether the book's PDF exists at `documentURL(for:)` (a restored book can have records
    /// but no PDF yet). A plain file-exists check: cheap, but a file-system call, not free.
    /// Callable from any thread; callers checking many books batch the calls off the main thread.
    public nonisolated func hasDocument(_ book: Book) -> Bool {
        let path = BookStorageLayout.documentPath(bookID: book.id, fileName: book.fileName)
        return FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent(path, isDirectory: false).path)
    }

    /// `<root>/Books/<bookID>/ink`
    public func pageInkDirectoryURL(bookID: UUID) -> URL {
        rootDirectory.appendingPathComponent(BookStorageLayout.pageInkDirectory(bookID: bookID), isDirectory: true)
    }

    /// `<root>/Books/<bookID>/notes`
    public func noteInkDirectoryURL(bookID: UUID) -> URL {
        rootDirectory.appendingPathComponent(BookStorageLayout.noteInkDirectory(bookID: bookID), isDirectory: true)
    }
}
