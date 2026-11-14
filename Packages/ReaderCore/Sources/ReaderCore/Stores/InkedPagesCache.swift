import Foundation

/// The pages with page ink of each book, cached for every window (one per `LibraryStore`,
/// `LibraryStore.inkedPages`).
///
/// **Cost.** The first request for a book lists its ink directory once
/// (`InkStore.inkedPageIndices`: one directory listing, no file is read). The result is kept
/// until a `.pageInkChanged` for that book arrives on the store's hub, from any window; the next
/// request then lists again (once, however many changes arrived meanwhile, and shared by
/// concurrent callers). `.bookDeleted` drops the book's entry. Memory is one `[Int]` per book
/// that has been asked for.
///
/// **Why re-list instead of patching.** A `.pageInkChanged` says a page's file was written *or*
/// deleted, not which; answering that for one page would mean reading its whole drawing (up to
/// megabytes), while a listing reads only names.
///
/// Callers that show the list (the Notebook) observe the hub themselves for `.pageInkChanged`
/// and ask again; this type never posts anything.
@MainActor
public final class InkedPagesCache {
    private struct Entry {
        /// The last listing, and the generation it was started at.
        var pages: [Int]?
        var listedGeneration = -1
        /// Bumped by every `.pageInkChanged` for the book.
        var generation = 0
        /// A listing in progress, and the generation it was started at.
        var inFlight: (generation: Int, task: Task<[Int], any Error>)?
    }

    private let inkStore: any InkStore
    private var entries: [UUID: Entry] = [:]
    private var observation: StoreChangeObservation?

    /// Number of directory listings made (tests and diagnostics).
    public private(set) var listingCount = 0

    /// Observes `hub` for page-ink changes and deleted books.
    public init(inkStore: any InkStore, hub: StoreChangeHub) {
        self.inkStore = inkStore
        observation = hub.observe { [weak self] event in
            self?.handle(event.change)
        }
    }

    /// The book's pages with ink, ascending: cached, or listed once if the cache is empty or a
    /// page-ink change arrived since the last listing.
    public func pages(bookID: UUID) async throws -> [Int] {
        var entry = entries[bookID] ?? Entry()
        if let pages = entry.pages, entry.listedGeneration == entry.generation { return pages }
        let generation = entry.generation
        let task: Task<[Int], any Error>
        if let inFlight = entry.inFlight, inFlight.generation == generation {
            task = inFlight.task
        } else {
            let store = inkStore
            task = Task { try await store.inkedPageIndices(bookID: bookID) }
            listingCount += 1
            entry.inFlight = (generation, task)
            entries[bookID] = entry
        }
        let pages = try await task.value
        // Store it unless the book was deleted or a newer listing already landed.
        if var current = entries[bookID], current.listedGeneration < generation {
            current.pages = pages
            current.listedGeneration = generation
            if current.inFlight?.generation == generation { current.inFlight = nil }
            entries[bookID] = current
        }
        return pages
    }

    /// The cached list if it is current (no change since it was listed), else `nil`. Never lists.
    public func cachedPages(bookID: UUID) -> [Int]? {
        guard let entry = entries[bookID], entry.listedGeneration == entry.generation else { return nil }
        return entry.pages
    }

    /// Forgets every cached list (the next request lists again).
    public func removeAll() {
        entries.removeAll()
    }

    private func handle(_ change: StoreChange) {
        switch change {
        case .pageInkChanged(let bookID, _):
            guard var entry = entries[bookID] else { return }
            entry.generation += 1
            entries[bookID] = entry
        case .bookDeleted(let bookID):
            entries[bookID] = nil
        default:
            break
        }
    }
}
