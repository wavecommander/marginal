import Foundation

/// Storage for scanned books' recognised text (one `RecognisedPage` per page) and their
/// `RecognitionState` sidecar. File layout: `BookStorageLayout.recognisedTextDirectory` and
/// `recognitionStatePath`; everything lives in the book's directory, so it goes when the
/// directory is removed with the book.
///
/// **Synchronous and thread-safe.** Unlike `InkStore`, the methods are plain `throws`: the
/// readers are the search worker and the recognition queue, which run on their own threads
/// and read one small file per page. Never call them on the main thread; main-actor code goes
/// through the `LibraryStore` methods, which do the work off the main actor.
///
/// **Writes** are atomic (a reader sees the old or the new file, never a partial one), and
/// `LibraryStore` posts the matching `StoreChange` after a write succeeds; writes made directly
/// through a raw store post nothing. Removals are idempotent. Callers serialise writes for one
/// book (the app has one recognition queue): a page saved while the book's text is being
/// removed may survive the removal.
public protocol RecognisedTextStore: Sendable {
    /// The recognised page, or `nil` if the page has not been recognised.
    func recognisedPage(bookID: UUID, pageIndex: Int) throws -> RecognisedPage?
    /// Atomically writes `page` (at `page.pageIndex`), replacing any previous one.
    func saveRecognisedPage(_ page: RecognisedPage, bookID: UUID) throws
    /// Pages that have been recognised, ascending.
    func recognisedPageIndices(bookID: UUID) throws -> [Int]
    /// Removes every recognised page of the book (not the state).
    func removeRecognisedText(bookID: UUID) throws
    /// The book's recognition state, or `nil` when it has none (a book with a text layer).
    func recognitionState(bookID: UUID) throws -> RecognitionState?
    /// Atomically writes the book's state; `nil` removes it.
    func saveRecognitionState(_ state: RecognitionState?, bookID: UUID) throws
    /// Removes the book's recognised pages and state.
    func removeBook(bookID: UUID) throws
}

/// Reference `RecognisedTextStore` held in memory. Same semantics as the file-backed store.
public final class InMemoryRecognisedTextStore: RecognisedTextStore, @unchecked Sendable {
    // `@unchecked`: every access to the dictionaries holds `lock`.
    private let lock = NSLock()
    private var pages: [UUID: [Int: RecognisedPage]] = [:]
    private var states: [UUID: RecognitionState] = [:]

    public init() {}

    public func recognisedPage(bookID: UUID, pageIndex: Int) throws -> RecognisedPage? {
        lock.withLock { pages[bookID]?[pageIndex] }
    }

    public func saveRecognisedPage(_ page: RecognisedPage, bookID: UUID) throws {
        lock.withLock { pages[bookID, default: [:]][page.pageIndex] = page }
    }

    public func recognisedPageIndices(bookID: UUID) throws -> [Int] {
        lock.withLock { (pages[bookID]?.keys).map { $0.sorted() } ?? [] }
    }

    public func removeRecognisedText(bookID: UUID) throws {
        lock.withLock { pages[bookID] = nil }
    }

    public func recognitionState(bookID: UUID) throws -> RecognitionState? {
        lock.withLock { states[bookID] }
    }

    public func saveRecognitionState(_ state: RecognitionState?, bookID: UUID) throws {
        lock.withLock { states[bookID] = state }
    }

    public func removeBook(bookID: UUID) throws {
        lock.withLock {
            pages[bookID] = nil
            states[bookID] = nil
        }
    }
}
