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
/// - The five repositories it exposes are **change-posting wrappers** around the implementations
///   passed to `init`: every successful mutation through them posts the `StoreChange`s listed on
///   each wrapper method below on `hub`; a mutation that throws posts nothing; reads pass straight
///   through. Mutate only through these (never through the raw implementations), or other
///   windows will not hear about it.
/// - **Origin attribution:** posts made inside `perform(as:_:)` carry that origin; posts made
///   outside it carry `nil`. The async ink and compound methods take `origin:` explicitly.
/// - Ink: read with `pageInk`/`noteInk`/`inkedPageIndices` (or `inkStore` directly); write only
///   with the `LibraryStore` methods, which post after the write succeeds.
/// - Files: `rootDirectory` is the directory `BookStorageLayout` paths are relative to (the app's
///   `Application Support` directory in the live app).
///
/// **What posts what** (wrappers; "existing" means read through the wrapped repository just before):
/// - `books.save(book)` → `.bookSaved(book.id)`.
/// - `books.deleteBook(id)` → `.bookDeleted(id)` if the book existed; nothing otherwise.
///   (Records only; prefer `deleteBook(id:origin:)`, which also removes files.)
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
/// - `headings.save(h)` → `.userHeadingsChanged(h.bookID)`; `deleteUserHeading(id)` → the same
///   for its book if it existed.
/// - `savePageInk`/`deletePageInk` → `.pageInkChanged(bookID, page)`;
///   `saveNoteInk`/`deleteNoteInk` → `.noteInkChanged(bookID, noteID)` (deletes post even if no
///   file existed, since the ink store cannot tell).
/// - `deleteBook(id:origin:)` → `.bookDeleted(id)` (once, after the records are gone).
/// - `deleteNote(id:origin:)` → `.noteRemoved(…)`, then `.noteInkChanged(…)` if the note had ink.
@MainActor
public final class LibraryStore {
    /// The change signal every window observes.
    public let hub: StoreChangeHub
    /// Directory that `BookStorageLayout` relative paths resolve against.
    public let rootDirectory: URL
    /// Books (change-posting wrapper).
    public let books: any BookRepository
    /// Notes (change-posting wrapper).
    public let notes: any NoteRepository
    /// Highlights (change-posting wrapper).
    public let highlights: any HighlightRepository
    /// Bookmarks (change-posting wrapper).
    public let bookmarks: any BookmarkRepository
    /// User headings (change-posting wrapper).
    public let headings: any HeadingRepository
    /// The raw ink store. **Read only**: writes through it post no change; use the `LibraryStore`
    /// ink methods instead.
    public let inkStore: any InkStore

    private let context: PostingContext

    /// Builds the store from any repository implementations (they may be one object) and an ink
    /// store. The implementations are wrapped; keep no other reference to them for mutation.
    /// - Parameter hub: the hub to post on; a new one when `nil`.
    public init(books: some BookRepository, notes: some NoteRepository, highlights: some HighlightRepository,
                bookmarks: some BookmarkRepository, headings: some HeadingRepository, inkStore: some InkStore,
                rootDirectory: URL, hub: StoreChangeHub? = nil) {
        let hub = hub ?? StoreChangeHub()
        let context = PostingContext(hub: hub)
        self.hub = hub
        self.context = context
        self.rootDirectory = rootDirectory
        self.books = PostingBookRepository(inner: books, context: context)
        self.notes = PostingNoteRepository(inner: notes, context: context)
        self.highlights = PostingHighlightRepository(inner: highlights, context: context)
        self.bookmarks = PostingBookmarkRepository(inner: bookmarks, context: context)
        self.headings = PostingHeadingRepository(inner: headings, context: context)
        self.inkStore = inkStore
    }

    /// A store backed by `InMemoryRecordStore` and `InMemoryInkStore`, for previews, unit tests,
    /// and running the app before a persistent store exists. Nothing is written to disk by the
    /// store itself; `rootDirectory` only feeds the URL helpers (default: a `MarginalInMemory`
    /// folder in the temporary directory).
    public static func inMemory(rootDirectory: URL? = nil) -> LibraryStore {
        let records = InMemoryRecordStore()
        let root = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginalInMemory", isDirectory: true)
        return LibraryStore(books: records, notes: records, highlights: records, bookmarks: records,
                            headings: records, inkStore: InMemoryInkStore(), rootDirectory: root)
    }

    // MARK: Origin

    /// The origin attached to repository posts right now: the innermost `perform(as:_:)` in
    /// progress, else `nil`.
    public var currentOrigin: ChangeOrigin? { context.origin }

    /// Runs `body` with `origin` attached to every change the wrapped repositories post inside
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

    // MARK: Compound operations

    /// Counts for the delete-book confirmation: records from `books.recordCounts` and the number
    /// of inked pages from the ink store.
    public func deletionSummary(bookID: UUID) async throws -> BookDeletionSummary {
        let records = try books.recordCounts(bookID: bookID)
        let inked = try await inkStore.inkedPageIndices(bookID: bookID).count
        return BookDeletionSummary(records: records, inkedPages: inked)
    }

    /// Deletes a book completely: first its records (cascade, posting `.bookDeleted` once if the
    /// book existed), then its directory (`inkStore.removeBook`: ink, note ink, and the PDF and
    /// cover if stored there). Records go first so a failure never leaves a visible book whose
    /// files are missing.
    /// - Throws: a repository error (nothing deleted, nothing posted), or
    ///   `LibraryStoreError.bookFilesNotRemoved` when the records are already gone and posted but
    ///   the directory could not be removed.
    public func deleteBook(id: UUID, origin: ChangeOrigin?) async throws {
        try perform(as: origin) { try books.deleteBook(id: id) }
        try await removeBookFiles(bookID: id)
    }

    /// Removes the book's directory through the ink store. Posts nothing. Use to retry after
    /// `bookFilesNotRemoved`.
    /// - Throws: `LibraryStoreError.bookFilesNotRemoved` wrapping the ink store's error.
    public func removeBookFiles(bookID: UUID) async throws {
        do {
            try await inkStore.removeBook(bookID: bookID)
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

    /// `<root>/Books/<bookID>/ink`
    public func pageInkDirectoryURL(bookID: UUID) -> URL {
        rootDirectory.appendingPathComponent(BookStorageLayout.pageInkDirectory(bookID: bookID), isDirectory: true)
    }

    /// `<root>/Books/<bookID>/notes`
    public func noteInkDirectoryURL(bookID: UUID) -> URL {
        rootDirectory.appendingPathComponent(BookStorageLayout.noteInkDirectory(bookID: bookID), isDirectory: true)
    }
}

// MARK: - Change-posting wrappers

/// Shared by a `LibraryStore` and its wrappers: the hub and the origin of the current `perform`.
@MainActor
final class PostingContext {
    let hub: StoreChangeHub
    var origin: ChangeOrigin?

    init(hub: StoreChangeHub) { self.hub = hub }

    func post(_ changes: StoreChange...) { hub.post(changes, origin: origin) }
}

@MainActor
final class PostingBookRepository<Inner: BookRepository>: BookRepository {
    let inner: Inner
    let context: PostingContext
    init(inner: Inner, context: PostingContext) { self.inner = inner; self.context = context }

    func allBooks() throws -> [Book] { try inner.allBooks() }
    func book(id: UUID) throws -> Book? { try inner.book(id: id) }
    func book(fingerprint: String) throws -> Book? { try inner.book(fingerprint: fingerprint) }
    func recordCounts(bookID: UUID) throws -> BookRecordCounts { try inner.recordCounts(bookID: bookID) }

    func save(_ book: Book) throws {
        try inner.save(book)
        context.post(.bookSaved(bookID: book.id))
    }

    func deleteBook(id: UUID) throws {
        let existed = try inner.book(id: id) != nil
        try inner.deleteBook(id: id)
        if existed { context.post(.bookDeleted(bookID: id)) }
    }
}

@MainActor
final class PostingNoteRepository<Inner: NoteRepository>: NoteRepository {
    let inner: Inner
    let context: PostingContext
    init(inner: Inner, context: PostingContext) { self.inner = inner; self.context = context }

    func note(bookID: UUID, target: NoteTarget) throws -> Note? { try inner.note(bookID: bookID, target: target) }
    func note(id: UUID) throws -> Note? { try inner.note(id: id) }
    func notes(bookID: UUID) throws -> [Note] { try inner.notes(bookID: bookID) }
    func pageNotes(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Note] { try inner.pageNotes(bookID: bookID, in: pages) }
    func noteCount(bookID: UUID) throws -> Int { try inner.noteCount(bookID: bookID) }

    @discardableResult
    func save(_ note: Note) throws -> Note? {
        let existing = try inner.note(bookID: note.bookID, target: note.target)
        let saved = try inner.save(note)
        if let saved {
            context.post(.noteSaved(bookID: saved.bookID, target: saved.target, noteID: saved.id))
        } else if let existing {
            context.post(.noteRemoved(bookID: existing.bookID, target: existing.target, noteID: existing.id))
        }
        return saved
    }

    func deleteNote(id: UUID) throws {
        let existing = try inner.note(id: id)
        try inner.deleteNote(id: id)
        if let existing {
            context.post(.noteRemoved(bookID: existing.bookID, target: existing.target, noteID: id))
        }
    }

    func retarget(noteID: UUID, to target: NoteTarget) throws {
        let existing = try inner.note(id: noteID)
        try inner.retarget(noteID: noteID, to: target)
        if let existing, existing.target != target {
            context.post(.noteRemoved(bookID: existing.bookID, target: existing.target, noteID: noteID),
                         .noteSaved(bookID: existing.bookID, target: target, noteID: noteID))
        }
    }
}

@MainActor
final class PostingHighlightRepository<Inner: HighlightRepository>: HighlightRepository {
    let inner: Inner
    let context: PostingContext
    init(inner: Inner, context: PostingContext) { self.inner = inner; self.context = context }

    func highlight(id: UUID) throws -> Highlight? { try inner.highlight(id: id) }
    func highlights(bookID: UUID) throws -> [Highlight] { try inner.highlights(bookID: bookID) }
    func highlights(bookID: UUID, pageIndex: Int) throws -> [Highlight] { try inner.highlights(bookID: bookID, pageIndex: pageIndex) }
    func highlights(bookID: UUID, in pages: ClosedRange<Int>) throws -> [Highlight] { try inner.highlights(bookID: bookID, in: pages) }
    func highlightCount(bookID: UUID) throws -> Int { try inner.highlightCount(bookID: bookID) }

    func save(_ highlight: Highlight) throws {
        let existing = try inner.highlight(id: highlight.id)
        try inner.save(highlight)
        var changes: [StoreChange] = []
        if let existing, existing.pageIndex != highlight.pageIndex || existing.bookID != highlight.bookID {
            changes.append(.highlightsChanged(bookID: existing.bookID, pageIndex: existing.pageIndex))
        }
        changes.append(.highlightsChanged(bookID: highlight.bookID, pageIndex: highlight.pageIndex))
        context.hub.post(changes, origin: context.origin)
    }

    func deleteHighlight(id: UUID) throws {
        let existing = try inner.highlight(id: id)
        try inner.deleteHighlight(id: id)
        if let existing { context.post(.highlightsChanged(bookID: existing.bookID, pageIndex: existing.pageIndex)) }
    }
}

@MainActor
final class PostingBookmarkRepository<Inner: BookmarkRepository>: BookmarkRepository {
    let inner: Inner
    let context: PostingContext
    init(inner: Inner, context: PostingContext) { self.inner = inner; self.context = context }

    func bookmarks(bookID: UUID) throws -> [Bookmark] { try inner.bookmarks(bookID: bookID) }
    func isBookmarked(bookID: UUID, pageIndex: Int) throws -> Bool { try inner.isBookmarked(bookID: bookID, pageIndex: pageIndex) }

    func setBookmarked(_ bookmarked: Bool, bookID: UUID, pageIndex: Int) throws {
        let before = try inner.isBookmarked(bookID: bookID, pageIndex: pageIndex)
        try inner.setBookmarked(bookmarked, bookID: bookID, pageIndex: pageIndex)
        if before != bookmarked { context.post(.bookmarksChanged(bookID: bookID, pageIndex: pageIndex)) }
    }
}

@MainActor
final class PostingHeadingRepository<Inner: HeadingRepository>: HeadingRepository {
    let inner: Inner
    let context: PostingContext
    init(inner: Inner, context: PostingContext) { self.inner = inner; self.context = context }

    func userHeadings(bookID: UUID) throws -> [UserHeading] { try inner.userHeadings(bookID: bookID) }
    func userHeading(id: UUID) throws -> UserHeading? { try inner.userHeading(id: id) }

    func save(_ heading: UserHeading) throws {
        let existing = try inner.userHeading(id: heading.id)
        try inner.save(heading)
        if let existing, existing.bookID != heading.bookID { context.post(.userHeadingsChanged(bookID: existing.bookID)) }
        context.post(.userHeadingsChanged(bookID: heading.bookID))
    }

    func deleteUserHeading(id: UUID) throws {
        let existing = try inner.userHeading(id: id)
        try inner.deleteUserHeading(id: id)
        if let existing { context.post(.userHeadingsChanged(bookID: existing.bookID)) }
    }
}
