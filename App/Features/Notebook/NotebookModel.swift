import Foundation
import Observation
import ReaderCore

/// The live Notebook of one book, for one Notebook screen (one per window showing it).
///
/// **Building.** `start()` reads the book, flattens its PDF outline once off the main thread
/// (`ReaderDocumentLoader.outlineEntries`), then `rebuild()`s: the records (notes, highlights,
/// bookmarks, user headings) are read on the main actor through the store's repositories (they are
/// main-actor), and the outline and the `Notebook` tree are built off the main thread
/// (`ReaderDocumentLoader.buildOutline` / `buildNotebook`). A newer rebuild supersedes an older
/// one still in flight (generation check).
///
/// **Staying live.** A Notebook window has no reader session, so the model observes `store.hub`
/// itself, filtered to its book: note, highlight and bookmark changes from any window schedule a
/// debounced rebuild (`rebuildDelay`); user-heading changes also rebuild the outline; note-ink
/// writes bump `inkVersions[noteID]` so an on-screen row reloads that note's ink; page-ink writes
/// and deletions bump `pageInkVersions[page]` (the handwriting row's preview reloads) and schedule
/// a rebuild, which reads the pages with ink from `store.inkedPages` (cached for every window,
/// re-listed once after a change), so a page appears when inked and goes when all its ink is
/// erased; `bookDeleted`
/// moves to `.missing` (the window's `WindowContext` drops the route or closes the window).
///
/// **Anchor repairs.** After the first successful build, `Notebook.anchorRepairs` are applied
/// once with `store.notes.retarget` (attributed to `origin`, whose own echoes are ignored), so
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
    /// Increases after every completed build (for views and tests).
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
    @ObservationIgnored private let loadOutlineEntries: @Sendable (URL) async -> [RawOutlineEntry]
    @ObservationIgnored private var rawEntries: [RawOutlineEntry]?
    @ObservationIgnored private var outline: Outline?
    @ObservationIgnored private var observation: StoreChangeObservation?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var repairsApplied = false
    @ObservationIgnored private var snapshots = NotebookSnapshotCache(capacity: 48)

    /// - Parameters:
    ///   - rebuildDelay: debounce of rebuilds after a change.
    ///   - outlineEntries: how to flatten the PDF outline (default: the shell's background loader).
    init(store: LibraryStore, bookID: UUID, rebuildDelay: Duration = .milliseconds(250),
         outlineEntries: (@Sendable (URL) async -> [RawOutlineEntry])? = nil) {
        self.store = store
        self.bookID = bookID
        self.rebuildDelay = rebuildDelay
        self.pagePreviews = NotebookPagePreviews(store: store, bookID: bookID)
        let documentURL = (try? store.books.book(id: bookID)).flatMap { $0 }.map { store.documentURL(for: $0) }
        self.highlightCrops = HighlightCropCache(documentURL: documentURL ?? URL(fileURLWithPath: "/dev/null"))
        self.loadOutlineEntries = outlineEntries ?? { url in await ReaderDocumentLoader.outlineEntries(at: url) }
    }

    /// Starts observing and builds the first time. Idempotent; concurrent callers share one start.
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    /// Stops observing and cancels pending work.
    func stop() {
        observation?.cancel()
        rebuildTask?.cancel()
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
        rawEntries = await loadOutlineEntries(store.documentURL(for: book))
        await rebuild()
    }

    // MARK: Building

    /// Re-reads the book's records and rebuilds the tree now.
    func rebuild() async {
        guard phase != .missing, let book else { return }
        generation += 1
        let current = generation
        let records = readRecords()
        // Cached across windows; one directory listing only after a page-ink change.
        let inkedPages = (try? await store.inkedPages.pages(bookID: book.id)) ?? []
        let outline: Outline
        if let cached = self.outline {
            outline = cached
        } else {
            outline = await ReaderDocumentLoader.buildOutline(entries: rawEntries ?? [], userHeadings: records.headings,
                                                              pageCount: book.pageCount)
        }
        let built = await Self.buildNotebook(outline: outline, notes: records.notes, highlights: records.highlights,
                                             bookmarks: records.bookmarks, inkedPages: inkedPages)
        guard current == generation, phase != .missing else { return }
        self.outline = outline
        notebook = built
        phase = .ready
        buildCount += 1
        applyRepairsOnce(built)
    }

    /// Builds the tree, pages with ink included, off the main thread.
    @concurrent
    private nonisolated static func buildNotebook(outline: Outline, notes: [Note], highlights: [Highlight],
                                                  bookmarks: [Bookmark], inkedPages: [Int]) async -> Notebook {
        NotebookBuilder.build(outline: outline, notes: notes, highlights: highlights, bookmarks: bookmarks,
                              inkedPages: inkedPages)
    }

    private func readRecords() ->(notes: [Note], highlights: [Highlight], bookmarks: [Bookmark], headings: [UserHeading]) {
        ((try? store.notes.notes(bookID: bookID)) ?? [],
         (try? store.highlights.highlights(bookID: bookID)) ?? [],
         (try? store.bookmarks.bookmarks(bookID: bookID)) ?? [],
         (try? store.headings.userHeadings(bookID: bookID)) ?? [])
    }

    private func scheduleRebuild() {
        guard phase != .missing, book != nil else { return }
        rebuildTask?.cancel()
        let delay = rebuildDelay
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
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
        store.perform(as: origin) {
            for repair in notebook.anchorRepairs {
                try? store.notes.retarget(noteID: repair.noteID, to: repair.target)
            }
        }
    }

    // MARK: Changes

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .bookDeleted:
            phase = .missing
            notebook = nil
            rebuildTask?.cancel()
            generation += 1
        case .bookSaved:
            if let stored = try? store.books.book(id: bookID) { book = stored }
        case .userHeadingsChanged:
            outline = nil
            scheduleRebuild()
        case .noteSaved, .noteRemoved:
            // The only notes this model writes are anchor repairs, which change nothing shown.
            if event.isFrom(origin) { return }
            scheduleRebuild()
        case .highlightsChanged, .bookmarksChanged:
            scheduleRebuild()
        case .noteInkChanged(_, let noteID):
            inkVersions[noteID, default: 0] += 1
            snapshots.remove(noteID: noteID)
        case .pageInkChanged(_, let page):
            // Ink added or erased on a page, in any window: its row appears, changes or goes.
            pageInkVersions[page, default: 0] += 1
            scheduleRebuild()
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
