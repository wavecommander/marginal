import Foundation
import Observation
import ReaderCore

/// The live Notebook of one book, for one Notebook screen (one per window showing it).
///
/// **Building.** The tree is the book's shared one (`BookIndex`: one per book, for every reader
/// and Notebook window on it, kept current from the store's change hub). `start()` reads the
/// book, joins its index, asks it for the pages with ink (`BookIndex.wantInkedPages()`: only a
/// Notebook lists them) and waits for the first tree that has them.
///
/// **Staying live.** The model takes each tree the index builds (`buildCount` counts them): after
/// a note, highlight, bookmark or user-heading change from any window (debounced by
/// `rebuildDelay`), and after a page-ink write or deletion, so a page appears when inked and goes
/// when all its ink is erased (the pages with ink come from `store.inkedPages`, cached for every
/// window and re-listed once after a change). The model itself observes `store.hub`, filtered to
/// its book, for what is its own: note-ink writes bump `inkVersions[noteID]` so an on-screen row
/// reloads that note's ink; page-ink writes and deletions bump `pageInkVersions[page]` (the
/// handwriting row's preview reloads); `bookDeleted`
/// moves to `.missing` (the window's `WindowContext` drops the route or closes the window).
///
/// **Anchor repairs.** After the first tree, `Notebook.anchorRepairs` are applied once
/// (`BookIndex.applyAnchorRepairs`, attributed to `origin`; the tree is not rebuilt for them), so
/// heading notes re-attach to headings that moved.
@Observable
@MainActor
final class NotebookModel {
    enum Phase: Equatable, Sendable {
        case loading
        case ready
        /// The book does not exist (deleted, from any window).
        case missing
    }

    let bookID: UUID
    private(set) var phase: Phase = .loading
    private(set) var book: Book?
    private(set) var notebook: Notebook?
    /// Increases with every tree taken from the book's index (for views and tests).
    private(set) var buildCount = 0
    /// Per note: increases when its ink file is written or deleted (a row reloads its ink).
    private(set) var inkVersions: [UUID: Int] = [:]
    /// Per page: increases when its page-ink file is written or deleted (a handwriting row
    /// reloads its preview).
    private(set) var pageInkVersions: [Int: Int] = [:]
    /// Previews of inked pages for the handwriting rows (rendered off the main thread, cached).
    @ObservationIgnored let pagePreviews: NotebookPagePreviews
    /// Crops of scanned-page highlights for their rows (rendered off the main thread, cached in
    /// memory only; S4).
    @ObservationIgnored let highlightCrops: HighlightCropCache

    @ObservationIgnored let store: LibraryStore
    /// Attributes the anchor repairs this model makes.
    @ObservationIgnored let origin = ChangeOrigin(label: "notebook")
    @ObservationIgnored private let rebuildDelay: Duration
    @ObservationIgnored private let loadOutlineEntries: (@Sendable (URL) async -> [RawOutlineEntry])?
    @ObservationIgnored private var observation: StoreChangeObservation?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// The book's shared outline and Notebook tree.
    @ObservationIgnored private var index: BookIndex?
    @ObservationIgnored private var indexObservation: BookIndexObservation?
    @ObservationIgnored private var inkedPagesDemand: BookIndex.InkedPagesDemand?
    @ObservationIgnored private var adoptedBuild = 0
    /// `start()` waiting for the first tree that lists the pages with ink.
    @ObservationIgnored private var firstTreeWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var repairsApplied = false
    @ObservationIgnored private var snapshots = NotebookSnapshotCache(capacity: 48)

    /// - Parameters:
    ///   - rebuildDelay: debounce of rebuilds after a change (the book's index uses the shortest
    ///     any of its windows asked for).
    ///   - outlineEntries: how to flatten the PDF outline (default: the shell's background
    ///     loader). Used when this model is the first window on the book.
    init(store: LibraryStore, bookID: UUID, rebuildDelay: Duration = .milliseconds(250),
         outlineEntries: (@Sendable (URL) async -> [RawOutlineEntry])? = nil) {
        self.store = store
        self.bookID = bookID
        self.rebuildDelay = rebuildDelay
        self.pagePreviews = NotebookPagePreviews(store: store, bookID: bookID)
        let documentURL = (try? store.books.book(id: bookID)).flatMap { $0 }.map { store.documentURL(for: $0) }
        self.highlightCrops = HighlightCropCache(documentURL: documentURL ?? URL(fileURLWithPath: "/dev/null"))
        self.loadOutlineEntries = outlineEntries
    }

    /// Starts observing and builds the first time. Idempotent; concurrent callers share one start.
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    /// Stops observing and lets go of the pages with ink.
    func stop() {
        observation?.cancel()
        indexObservation?.cancel()
        inkedPagesDemand = nil
        resumeFirstTreeWaiter()
        pagePreviews.purge()
        highlightCrops.purge()
    }

    private func performStart() async {
        let bookID = self.bookID
        observation = store.hub.observe { [weak self] event in
            guard event.change.bookID == bookID else { return }
            self?.handle(event)
        }
        guard let book = try? store.books.book(id: bookID) else {
            phase = .missing
            return
        }
        self.book = book
        let index = BookIndex.shared(for: book, in: store, rebuildDelay: rebuildDelay, outlineEntries: loadOutlineEntries)
        self.index = index
        inkedPagesDemand = index.wantInkedPages()
        indexObservation = index.observe { [weak self] update in
            if case .notebook = update { self?.adoptNotebook() }
        }
        await index.load()
        adoptNotebook()
        if phase == .loading, indexObservation?.isActive == true {
            // The index was built for a reader, without the pages with ink: the tree that lists
            // them is on its way (`adoptNotebook` ends the wait; so do `stop()` and a deleted book).
            await withCheckedContinuation { firstTreeWaiter = $0 }
        }
    }

    // MARK: Building

    /// Takes the index's tree, once per build, as soon as it lists the pages with ink.
    private func adoptNotebook() {
        guard phase != .missing, let index, index.notebookIncludesInk, index.buildCount != adoptedBuild,
              let built = index.notebook else { return }
        adoptedBuild = index.buildCount
        notebook = built
        phase = .ready
        buildCount += 1
        applyRepairsOnce(built)
        resumeFirstTreeWaiter()
    }

    private func resumeFirstTreeWaiter() {
        firstTreeWaiter?.resume()
        firstTreeWaiter = nil
    }

    /// Deletes a note and its ink (design: "Deleting a note"; the Notebook row's Delete Note).
    /// Not attributed to this model's origin, so this Notebook rebuilds from the change like every
    /// other window; a reader showing the note resets it to the empty placeholder. Returns
    /// `false` when the store failed.
    @discardableResult
    func deleteNote(_ note: Note) async -> Bool {
        do {
            try await store.deleteNote(id: note.id, origin: nil)
            return true
        } catch {
            return false
        }
    }

    private func applyRepairsOnce(_ notebook: Notebook) {
        guard !repairsApplied else { return }
        repairsApplied = true
        guard !notebook.anchorRepairs.isEmpty else { return }
        index?.applyAnchorRepairs(as: origin)
    }

    // MARK: Changes

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .bookDeleted:
            phase = .missing
            notebook = nil
            indexObservation?.cancel()
            inkedPagesDemand = nil
            resumeFirstTreeWaiter()
        case .bookSaved:
            if let stored = try? store.books.book(id: bookID) { book = stored }
        case .userHeadingsChanged, .noteSaved, .noteRemoved, .highlightsChanged, .bookmarksChanged:
            break  // The book's index rebuilds the tree (`adoptNotebook`).
        case .noteInkChanged(_, let noteID):
            inkVersions[noteID, default: 0] += 1
            snapshots.remove(noteID: noteID)
        case .pageInkChanged(_, let page):
            // Ink added or erased on a page, in any window: its row's preview reloads (the row
            // itself appears or goes with the index's next tree).
            pageInkVersions[page, default: 0] += 1
        case .recognisedTextChanged, .recognitionStateChanged:
            break
        }
    }

    // MARK: Note ink for rows

    /// The note laid out with its ink, for a row on screen. Reads the ink off the main thread
    /// (the ink store is an actor), then lays it out (main actor, `NotePageRenderer`). Cached for
    /// a few dozen notes; returns `nil` if the task was cancelled (the row scrolled away).
    func snapshot(for note: Note) async -> NotePageSnapshot? {
        let key = NotebookSnapshotCache.Key(noteID: note.id, modifiedAt: note.modifiedAt,
                                            inkVersion: inkVersions[note.id] ?? 0, text: note.text)
        if let cached = snapshots[key] { return cached }
        let data = try? await store.noteInk(bookID: bookID, noteID: note.id)
        guard !Task.isCancelled else { return nil }
        let snapshot = NotePageRenderer.snapshot(note: note, inkData: data)
        snapshots[key] = snapshot
        return snapshot
    }
}

/// A small most-recently-used cache of laid-out notes (bounded so scrolling through thousands
/// of inked notes never keeps more than `capacity` drawings alive).
@MainActor
struct NotebookSnapshotCache {
    struct Key: Hashable {
        let noteID: UUID
        let modifiedAt: Date
        let inkVersion: Int
        let text: String
    }

    let capacity: Int
    private var values: [Key: NotePageSnapshot] = [:]
    private var order: [Key] = []

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: Key) -> NotePageSnapshot? {
        get { values[key] }
        set {
            order.removeAll { $0 == key }
            values[key] = newValue
            guard newValue != nil else { return }
            order.append(key)
            while order.count > capacity { values[order.removeFirst()] = nil }
        }
    }

    mutating func remove(noteID: UUID) {
        for key in order where key.noteID == noteID { values[key] = nil }
        order.removeAll { $0.noteID == noteID }
    }
}
