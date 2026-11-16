import Foundation
import ReaderCore

/// What every window on one book shares: the book's merged outline (PDF outline plus the
/// reader's own headings) and its Notebook tree (notes, highlights, bookmarks and, while a
/// Notebook window wants them, the pages with ink, filed along that outline).
///
/// **One per book.** `BookIndex.shared(for:in:)` hands every reader session and Notebook model
/// of a book the same object, for as long as any of them holds it; the PDF's outline is read
/// from the file once, and each change is worked out once, however many windows show the book.
///
/// **Updated from the change hub.** The index reads the book's records once, when it loads, and
/// keeps them. After that each `StoreChange` for the book re-reads only what it names (the one
/// note, one page's highlights, the bookmarks, the user headings), and the tree is rebuilt from
/// the kept records off the main thread, debounced (`rebuildDelay`), so a note's autosave reads
/// one record instead of the whole book in every window. A heading change rebuilds the outline
/// first, at once.
///
/// **Windows follow it** through `observe(_:)`: the handler is called on the main actor, right
/// after `outline` or `notebook` has changed. Reader sessions and Notebook models keep the values
/// they show as their own observable state.
@MainActor
final class BookIndex {
    /// What changed.
    enum Update: Equatable, Sendable {
        /// `outline` was built (the first time, or again after the reader's headings changed).
        case outline
        /// `notebook` was built. `recordsChanged` is `false` when nothing but page ink changed
        /// since the last one: windows that do not show ink (readers) have nothing new.
        case notebook(recordsChanged: Bool)
    }

    /// What a Notebook holds while it wants the pages with ink in the tree (`wantInkedPages()`).
    final class InkedPagesDemand {}

    let bookID: UUID
    /// The merged outline; `.empty` until `isOutlineLoaded`.
    private(set) var outline: Outline = .empty
    private(set) var isOutlineLoaded = false
    /// The Notebook tree along `outline`; `nil` until first built.
    private(set) var notebook: Notebook?
    /// Whether `notebook` was built with the pages that have ink (`retainInkedPages()`).
    private(set) var notebookIncludesInk = false
    /// Completed builds of `notebook` (tests and diagnostics).
    private(set) var buildCount = 0
    /// Times the book's records were read as a whole: once per index, at load (tests and
    /// diagnostics).
    private(set) var wholeBookReadCount = 0
    /// The book was deleted, or replaced by a restore: the index is finished, and a window opened
    /// on a book with this ID gets a new one.
    private(set) var isFinished = false

    private let store: LibraryStore
    private var book: Book
    private var rebuildDelay: Duration
    private let loadOutlineEntries: @Sendable (URL) async -> [RawOutlineEntry]
    private var hubObservation: StoreChangeObservation?
    private var observers: [WeakObservation] = []

    // The PDF's own outline, and whether the PDF was there to read it from.
    private var rawEntries: [RawOutlineEntry] = []
    private var hadDocument = false

    // The book's records, kept current from the hub once `hasRecords`.
    private var hasRecords = false
    private var notes: [UUID: Note] = [:]
    private var highlightsByPage: [Int: [Highlight]] = [:]
    private var bookmarks: [Bookmark] = []
    private var userHeadings: [UserHeading] = []

    // Building.
    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var needsEntries = false
    private var needsOutline = false
    private var needsNotebook = false
    private var recordsChangedSinceBuild = false
    private var isBuilding = false
    private var inkedPagesDemands: [WeakDemand] = []
    private var isApplyingRepairs = false

    private final class WeakObservation {
        weak var value: BookIndexObservation?
        init(_ value: BookIndexObservation) { self.value = value }
    }

    private final class WeakDemand {
        weak var value: InkedPagesDemand?
        init(_ value: InkedPagesDemand) { self.value = value }
    }

    // MARK: One per book

    private struct Entry {
        weak var store: LibraryStore?
        weak var index: BookIndex?
    }

    private struct Key: Hashable {
        let store: ObjectIdentifier
        let bookID: UUID
    }

    private static var registry: [Key: Entry] = [:]

    /// The index every window on `book` in `store` shares, made if no window holds one.
    /// - Parameters:
    ///   - rebuildDelay: debounce of rebuilds after a change; the shortest any window asked for.
    ///   - outlineEntries: how to flatten the PDF outline (default: the reader's background
    ///     loader). Used by whoever makes the index.
    static func shared(for book: Book, in store: LibraryStore, rebuildDelay: Duration = .milliseconds(250),
                       outlineEntries: (@Sendable (URL) async -> [RawOutlineEntry])? = nil) -> BookIndex {
        let key = Key(store: ObjectIdentifier(store), bookID: book.id)
        if let entry = registry[key], entry.store === store, let index = entry.index, !index.isFinished {
            index.rebuildDelay = min(index.rebuildDelay, rebuildDelay)
            return index
        }
        registry = registry.filter { $0.value.store != nil && $0.value.index?.isFinished == false }
        let index = BookIndex(book: book, store: store, rebuildDelay: rebuildDelay,
                              outlineEntries: outlineEntries ?? { url in await ReaderDocumentLoader.outlineEntries(at: url) })
        registry[key] = Entry(store: store, index: index)
        return index
    }

    private init(book: Book, store: LibraryStore, rebuildDelay: Duration,
                 outlineEntries: @escaping @Sendable (URL) async -> [RawOutlineEntry]) {
        self.bookID = book.id
        self.book = book
        self.store = store
        self.rebuildDelay = rebuildDelay
        self.loadOutlineEntries = outlineEntries
        let bookID = book.id
        hubObservation = store.hub.observe { [weak self] event in
            guard event.change.bookID == bookID else { return }
            self?.handle(event.change)
        }
    }

    // MARK: Following

    /// Calls `handler` after each change of `outline` or `notebook`. Keep the token.
    func observe(_ handler: @escaping @MainActor (Update) -> Void) -> BookIndexObservation {
        let observation = BookIndexObservation(handler: handler)
        observers.removeAll { $0.value?.handler == nil }
        observers.append(WeakObservation(observation))
        return observation
    }

    private func notify(_ update: Update) {
        for box in observers { box.value?.handler?(update) }
    }

    // MARK: Loading

    /// Reads the PDF's outline (off the main thread) and the book's records, and builds the
    /// outline, then the first Notebook tree (observers hear of each as it is built). Idempotent;
    /// concurrent callers share one load.
    func load() async {
        if loadTask == nil {
            loadTask = Task { await self.performLoad() }
        }
        await loadTask?.value
    }

    private func performLoad() async {
        guard !isFinished else { return }
        if let stored = try? store.books.book(id: bookID) { book = stored }
        await readEntries()
        guard !isFinished else { return }
        readRecords()
        needsOutline = true
        needsNotebook = true
        recordsChangedSinceBuild = true
        await runBuilds()
    }

    private func readEntries() async {
        needsEntries = false
        let book = book
        hadDocument = store.hasDocument(book)
        rawEntries = await loadOutlineEntries(store.documentURL(for: book))
    }

    /// The whole book, once. From here on `handle(_:)` keeps the records current.
    private func readRecords() {
        wholeBookReadCount += 1
        notes = Dictionary(((try? store.notes.notes(bookID: bookID)) ?? []).map { ($0.id, $0) },
                           uniquingKeysWith: { _, latest in latest })
        highlightsByPage = Dictionary(grouping: (try? store.highlights.highlights(bookID: bookID)) ?? [], by: \.pageIndex)
        bookmarks = (try? store.bookmarks.bookmarks(bookID: bookID)) ?? []
        userHeadings = (try? store.headings.userHeadings(bookID: bookID)) ?? []
        hasRecords = true
    }

    // MARK: Pages with ink

    /// A Notebook window wants the pages with ink in the tree, for as long as it keeps the
    /// returned object. While any does, a page-ink change rebuilds the tree; readers never ask
    /// (ink is not a Contents badge), so drawing in a book with no Notebook window open builds
    /// nothing.
    func wantInkedPages() -> InkedPagesDemand {
        let demand = InkedPagesDemand()
        inkedPagesDemands.removeAll { $0.value == nil }
        inkedPagesDemands.append(WeakDemand(demand))
        if hasRecords, !notebookIncludesInk {
            needsNotebook = true
            scheduleBuilds(immediately: true)
        }
        return demand
    }

    private var wantsInkedPages: Bool { inkedPagesDemands.contains { $0.value != nil } }

    // MARK: Anchor repairs

    /// Re-attaches heading notes whose stored anchor is stale (`Notebook.anchorRepairs` of the
    /// current tree), attributed to `origin`. The kept records follow; the tree is not rebuilt
    /// for it, because a repair changes nothing it shows.
    func applyAnchorRepairs(as origin: ChangeOrigin) {
        guard !isFinished, let repairs = notebook?.anchorRepairs, !repairs.isEmpty else { return }
        isApplyingRepairs = true
        defer { isApplyingRepairs = false }
        store.perform(as: origin) {
            for repair in repairs {
                try? store.notes.retarget(noteID: repair.noteID, to: repair.target)
            }
        }
    }

    // MARK: Changes

    private func handle(_ change: StoreChange) {
        guard !isFinished else { return }
        switch change {
        case .bookDeleted:
            finish()
        case .bookSaved:
            guard let stored = try? store.books.book(id: bookID) else { return }
            let previous = book
            book = stored
            // A PDF located for a book restored without one (or another file in its place): its
            // outline is read again. A PDF that is there never changes.
            let changedFile = stored.fileName != previous.fileName || stored.pageCount != previous.pageCount
            guard hasRecords, changedFile || (!hadDocument && store.hasDocument(stored)) else { return }
            needsEntries = true
            needsOutline = true
            needsNotebook = true
            recordsChangedSinceBuild = true
            scheduleBuilds(immediately: true)
        case .noteSaved(_, _, let noteID), .noteRemoved(_, _, let noteID):
            guard hasRecords else { return }
            // By ID, whichever of the two it is: a note moved by `retarget` is announced as
            // removed from its old target while it exists at the new one.
            notes[noteID] = try? store.notes.note(id: noteID)
            if isApplyingRepairs { return }
            recordsDidChange()
        case .highlightsChanged(_, let pageIndex):
            guard hasRecords else { return }
            let onPage = (try? store.highlights.highlights(bookID: bookID, pageIndex: pageIndex)) ?? []
            highlightsByPage[pageIndex] = onPage.isEmpty ? nil : onPage
            recordsDidChange()
        case .bookmarksChanged:
            guard hasRecords else { return }
            bookmarks = (try? store.bookmarks.bookmarks(bookID: bookID)) ?? []
            recordsDidChange()
        case .userHeadingsChanged:
            guard hasRecords else { return }
            userHeadings = (try? store.headings.userHeadings(bookID: bookID)) ?? []
            needsOutline = true
            needsNotebook = true
            recordsChangedSinceBuild = true
            scheduleBuilds(immediately: true)
        case .pageInkChanged:
            // Ink added or erased on a page, in any window: its Notebook row appears, changes or
            // goes. The list itself comes from `store.inkedPages` when the tree is built.
            guard hasRecords, wantsInkedPages else {
                notebookIncludesInk = false
                return
            }
            needsNotebook = true
            scheduleBuilds(immediately: false)
        case .noteInkChanged:
            break
        }
    }

    private func recordsDidChange() {
        needsNotebook = true
        recordsChangedSinceBuild = true
        scheduleBuilds(immediately: false)
    }

    private func finish() {
        isFinished = true
        hubObservation?.cancel()
        debounceTask?.cancel()
        observers.removeAll()
        notes = [:]
        highlightsByPage = [:]
        bookmarks = []
        userHeadings = []
        notebook = nil
    }

    // MARK: Building

    private func scheduleBuilds(immediately: Bool) {
        debounceTask?.cancel()
        let delay = rebuildDelay
        debounceTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.runBuilds()
        }
    }

    /// Builds whatever is marked as needed, one build at a time, until nothing is: a change that
    /// arrives during a build is picked up by the next round.
    private func runBuilds() async {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        while !isFinished, needsEntries || needsOutline || needsNotebook {
            if needsEntries {
                await readEntries()
                continue
            }
            if needsOutline {
                needsOutline = false
                let built = await ReaderDocumentLoader.buildOutline(entries: rawEntries, userHeadings: userHeadings,
                                                                     pageCount: book.pageCount)
                guard !isFinished else { return }
                if needsEntries || needsOutline { continue }
                outline = built
                isOutlineLoaded = true
                notify(.outline)
                continue
            }
            needsNotebook = false
            let recordsChanged = recordsChangedSinceBuild
            recordsChangedSinceBuild = false
            let withInk = wantsInkedPages
            // Cached for every window; one directory listing only after a page-ink change.
            let inkedPages = withInk ? ((try? await store.inkedPages.pages(bookID: bookID)) ?? []) : []
            guard !isFinished else { return }
            let built = await ReaderDocumentLoader.buildNotebook(
                outline: outline, notes: Array(notes.values), highlights: highlightsByPage.values.flatMap { $0 },
                bookmarks: bookmarks, inkedPages: inkedPages)
            guard !isFinished else { return }
            if needsEntries || needsOutline {
                // The outline changed under this tree: build it again on the new one.
                needsNotebook = true
                recordsChangedSinceBuild = recordsChangedSinceBuild || recordsChanged
                continue
            }
            notebook = built
            notebookIncludesInk = withInk
            buildCount += 1
            notify(.notebook(recordsChanged: recordsChanged))
        }
    }
}

/// An active `BookIndex.observe(_:)`; delivery stops when it is cancelled or released.
@MainActor
final class BookIndexObservation {
    fileprivate var handler: (@MainActor (BookIndex.Update) -> Void)?
    fileprivate init(handler: @escaping @MainActor (BookIndex.Update) -> Void) { self.handler = handler }
    /// `false` once cancelled.
    var isActive: Bool { handler != nil }
    func cancel() { handler = nil }
}
