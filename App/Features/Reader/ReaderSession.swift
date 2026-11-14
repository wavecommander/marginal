import Foundation
import Observation
import PDFKit
import PencilKit
import ReaderCore
import UIKit

/// The state and commands of **one reader window** (a reader shown in place in a Library window,
/// or a reader in its own window). Every reader feature (Contents, ink, highlights, notes,
/// search, Notebook links) reads and commands its own window's session, never another's and
/// never a global one. Get it from the SwiftUI environment (`@Environment(ReaderSession.self)`)
/// inside the reader, or from the initialiser of the placeholder you replace.
///
/// ## Rules
/// - **Main actor only.** All state is `@Observable`; SwiftUI views re-render on what they read.
/// - **Pages are zero-based** (`PageNumbering`); 1-based numbers are for display only.
/// - **Mutate stored data only through `perform(_:)`** (or the `origin:` parameters of the async
///   `LibraryStore` methods, passing `origin`). That attributes the change to this window, so its
///   own feature code can ignore its own echoes while other windows reload.
/// - **React to changes** through `revisions` / `externalRevisions` (SwiftUI) or
///   `observeBookChanges(includeOwn:_:)` (UIKit/imperative code). Never subscribe to
///   `store.hub` directly from a feature: those helpers already filter to this book.
/// - **Lifetime.** The session lives as long as its reader view (`ReaderHost`). `suspend()` runs
///   when the window backgrounds, closes, or the reader is popped; it flushes the debounced
///   last-read save and every markup surface. The hub subscription is dropped with the session.
/// - **PDFKit.** `document` is the on-screen `PDFDocument`; use it only on the main actor and
///   never hand it to another thread (open your own instance from `documentURL` for background
///   work, or use `thumbnails`). The PDF view and its plug points live on `pdf`.
@Observable
@MainActor
final class ReaderSession: Identifiable {

    // MARK: Nested types

    /// Reading or markup. There is one mode for the whole window (page ink and note ink).
    enum Mode: String, Codable, Sendable {
        case reading, markup
    }

    /// The notes panel's tab.
    enum NotesTab: String, Codable, Sendable, CaseIterable {
        case page, section
    }

    /// Document loading progress.
    enum LoadState: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    /// Why the session asks its host to close it.
    enum CloseReason: Equatable, Sendable {
        /// The book was deleted (by any window). Readers on it leave/close.
        case bookDeleted
        /// The book's record could not be found when opening.
        case bookMissing
    }

    /// Per-window state saved for state restoration (scene storage). Markup mode is deliberately
    /// not part of it (the design does not restore markup mode).
    struct RestorableState: Codable, Equatable, Sendable {
        var pageIndex: Int?
        var isContentsVisible = true
        var isNotesVisible = true
        var notesTab: NotesTab = .page
        var notesPanelWidth: Double = ReaderSession.defaultNotesPanelWidth
        /// The window's section history.
        var history: SectionHistory?
    }

    /// How a session starts. Values from launch arguments win over restored state, which wins
    /// over the book's stored `lastReadPageIndex`.
    struct Configuration {
        /// Explicit start page (e.g. `-openPage`); wins over everything.
        var initialPageIndex: Int?
        /// Restored window state, if any.
        var restoredState: RestorableState?
        /// Start in markup mode (`-markup`).
        var startInMarkup = false
        /// Open the notes panel on this tab (`-notesPanel`).
        var openNotesTab: NotesTab?
        /// `-inkAnyInput`: canvases draw with any input.
        var inkAnyInput = false
        /// `-selectionMenuProbe` (UI tests only).
        var selectionMenuProbe = false
        /// `-markupProbeSurface` (UI tests only): register a `MarkupProbeSurface`.
        var markupProbeSurface = false
        /// `-exposeViewportAnchor` (UI tests only): publish the reading anchor for accessibility.
        var exposesViewportAnchor = false
        /// `-exposeSelection` (UI tests only): publish the text selection for accessibility.
        var exposesSelection = false
        /// Delay of the debounced `lastReadPageIndex` save.
        var lastReadSaveDelay: Duration = .seconds(1)
        /// Delay of the debounced Notebook rebuild after a change.
        var notebookRebuildDelay: Duration = .milliseconds(250)
        /// Install the feature controllers (`ReaderFeatureWiring`). Unit tests may turn it off.
        var installsFeatures = true

        init() {}
    }

    /// Counters that increase when stored data of this book changes. Read the counter for the
    /// data you show inside a SwiftUI `body` (or `.onChange(of:)`/`.task(id:)`), then re-read
    /// the data from `store`. One counter per kind of change.
    struct ChangeRevisions: Equatable, Sendable {
        var book = 0
        var notes = 0
        var highlights = 0
        var bookmarks = 0
        var userHeadings = 0
        var pageInk = 0
        var noteInk = 0

        mutating func record(_ change: StoreChange) {
            switch change {
            case .bookSaved, .bookDeleted: book += 1
            case .noteSaved, .noteRemoved: notes += 1
            case .highlightsChanged: highlights += 1
            case .bookmarksChanged: bookmarks += 1
            case .userHeadingsChanged: userHeadings += 1
            case .pageInkChanged: pageInk += 1
            case .noteInkChanged: noteInk += 1
            }
        }
    }

    /// Default (and minimum) width of the notes panel in points: the mockup's 330.
    nonisolated static let defaultNotesPanelWidth: Double = 330
    /// Default width of the Contents sidebar in points.
    nonisolated static let contentsSidebarWidth: Double = 280

    // MARK: Identity and dependencies

    /// Unique per session (and so per reader window).
    let id = UUID()
    /// This session's change origin. Pass it to every store mutation (`perform(_:)` does).
    let origin: ChangeOrigin
    /// The app's shared store (the same object in every window).
    let store: LibraryStore
    /// How the session was started.
    let configuration: Configuration

    // MARK: Book and document

    /// The book, refreshed when another window renames it (`.bookSaved`).
    private(set) var book: Book
    /// The imported PDF on disk. Open your own `PDFDocument` from it for background work.
    let documentURL: URL
    /// The on-screen document, `nil` until `loadState == .ready`. Main actor only.
    private(set) var document: PDFDocument?
    /// Loading progress of `document`.
    private(set) var loadState: LoadState = .loading
    /// Set when the host should leave/close this reader (it does so automatically).
    private(set) var closeReason: CloseReason?

    /// Number of pages (from the document once open, else from the book record).
    var pageCount: Int { document?.pageCount ?? book.pageCount }

    // MARK: Position

    /// The page PDFKit reports as current while scrolling (zero-based). The toolbar subtitle,
    /// the Contents selection and the notes panel follow it.
    private(set) var currentPageIndex: Int
    /// Pages currently on screen, ascending (from `PDFViewVisiblePagesChanged`).
    private(set) var visiblePageIndices: [Int] = []
    /// This window's section history (Back/Forward between sections). Recorded by every
    /// `jump…` call; restored with the window. Read it for the press-and-hold lists
    /// (`history.backList` / `history.forwardList`); move with `goBack()` / `goForward()` /
    /// `goToHistoryEntry(at:)`.
    private(set) var history = SectionHistory()
    /// Whether Back / Forward have somewhere to go.
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    /// `true` while the PDF view auto-fits the page width (false after zooming in/out).
    private(set) var isFitWidth = true

    // MARK: Outline and Notebook

    /// The merged outline (PDF outline + user headings). `.empty` until loaded; rebuilt off the
    /// main thread whenever user headings change. Never blocks the first page.
    private(set) var outline: Outline = .empty
    /// `true` once `outline` has been built at least once.
    private(set) var isOutlineLoaded = false
    /// `outline.headingPath(forPage: currentPageIndex)`: shallowest first.
    private(set) var headingPath: [OutlineNode] = []
    /// The deepest heading containing the current page (the Section note tab opens on it).
    var deepestHeading: OutlineNode? { headingPath.last }
    /// The Notebook tree for this book (note badges, section lists), rebuilt off the main thread
    /// after the outline loads and after any note, highlight, bookmark or heading change (debounced).
    /// `nil` until first built.
    private(set) var notebook: Notebook?

    // MARK: Mode and panels

    /// Reading or markup. Change it with `setMode(_:)` / `toggleMarkup()` / `finishMarkup()`.
    private(set) var mode: Mode = .reading
    /// Convenience for `mode == .markup`.
    var isMarkupMode: Bool { mode == .markup }
    /// The Contents sidebar (wide) or overlay (narrow) is shown.
    var isContentsVisible = true
    /// The Contents overlay is shown (narrow widths only; not restored).
    var isContentsOverlayVisible = false
    /// Set by the shell from the window width: `true` when Contents is an overlay and the notes
    /// panel a sheet. Read-only for features.
    var isNarrowLayout = false
    /// The notes panel (wide) or sheet (narrow) is shown.
    var isNotesVisible = true
    /// The notes panel's tab.
    var notesTab: NotesTab = .page
    /// Requested notes panel width in points. The shell clamps it to
    /// `defaultNotesPanelWidth...windowWidth/2`. WP8/WP13 zoom the note page by
    /// `notesPanelWidth / defaultNotesPanelWidth` instead of re-wrapping it.
    var notesPanelWidth: Double = ReaderSession.defaultNotesPanelWidth
    /// The search UI (WP10) is shown.
    var isSearchVisible = false
    /// The go-to-page field is shown (the page pill was tapped, or Go to Page… was chosen).
    var isGoToPageVisible = false

    // MARK: Changes

    /// Every change to this book's stored data, from any origin (including this session).
    private(set) var revisions = ChangeRevisions()
    /// Only changes made by *other* origins (other windows, importers, unattributed writes).
    /// Editors that save their own changes watch these so they do not reload their own echo.
    private(set) var externalRevisions = ChangeRevisions()
    /// Increases on each memory warning; drop caches when it changes.
    private(set) var memoryWarningCount = 0

    // MARK: Collaborators

    /// The PDF view bridge: navigation, zoom, selection, annotations, plug points.
    @ObservationIgnored private(set) var pdf: ReaderPDFController!
    /// The markup surface registry and the window's one `PKToolPicker`.
    private(set) var markup: ReaderMarkupController!
    /// Off-main page thumbnails from a private `PDFDocument` (created on first use).
    var thumbnails: PDFThumbnailRenderer {
        if let thumbnailsIfCreated { return thumbnailsIfCreated }
        let renderer = PDFThumbnailRenderer(url: documentURL)
        thumbnailsIfCreated = renderer
        return renderer
    }
    @ObservationIgnored private var thumbnailsIfCreated: PDFThumbnailRenderer?

    // MARK: Private state

    @ObservationIgnored private var hubToken: StoreChangeObservation?
    @ObservationIgnored private var lastReadSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedPageIndex: Int?
    @ObservationIgnored private var rawOutlineEntries: [RawOutlineEntry]?
    @ObservationIgnored private var outlineGeneration = 0
    @ObservationIgnored private var notebookTask: Task<Void, Never>?
    @ObservationIgnored private var notebookGeneration = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var featureObjects: [AnyObject] = []
    @ObservationIgnored private var featureStates: [ObjectIdentifier: AnyObject] = [:]

    // MARK: Init

    /// Makes a session for `book`. Call `open()` to load the document (the host does).
    init(book: Book, store: LibraryStore, configuration: Configuration = Configuration()) {
        self.book = book
        self.store = store
        self.configuration = configuration
        self.origin = ChangeOrigin(label: "reader \(book.title)")
        self.documentURL = store.documentURL(for: book)

        let restored = configuration.restoredState
        let startPage = configuration.initialPageIndex ?? restored?.pageIndex ?? book.lastReadPageIndex
        self.currentPageIndex = PageNumbering.isValid(startPage, pageCount: book.pageCount) ? startPage : 0
        self.lastSavedPageIndex = book.lastReadPageIndex
        if let restored {
            isContentsVisible = restored.isContentsVisible
            isNotesVisible = restored.isNotesVisible
            notesTab = restored.notesTab
            notesPanelWidth = max(Self.defaultNotesPanelWidth, restored.notesPanelWidth)
            if let restoredHistory = restored.history { history = restoredHistory }
        }
        if let tab = configuration.openNotesTab {
            isNotesVisible = true
            notesTab = tab
        }

        self.markup = ReaderMarkupController(drawingPolicy: configuration.inkAnyInput ? .anyInput : .default)
        self.pdf = ReaderPDFController(session: self)
        markup.session = self

        hubToken = store.hub.observe { [weak self] event in
            self?.handle(event)
        }
        if configuration.installsFeatures {
            ReaderFeatureWiring.install(on: self)
        }
        if configuration.startInMarkup {
            setMode(.markup)
        }
    }

    // MARK: Lifecycle

    /// Loads the document off the main thread, then the outline (also off the main thread, after
    /// the document is shown). Idempotent. Marks the book opened (`lastOpenedAt`).
    func open() {
        guard openTask == nil else { return }
        openTask = Task { [weak self, documentURL] in
            let box = await ReaderDocumentLoader.openDocument(at: documentURL)
            guard let self else { return }
            guard let document = box?.value else {
                self.loadState = .failed("The PDF could not be opened.")
                return
            }
            self.document = document
            if !PageNumbering.isValid(self.currentPageIndex, pageCount: document.pageCount) {
                self.currentPageIndex = 0
            }
            self.pdf.attach(document, initialPageIndex: self.currentPageIndex)
            self.loadState = .ready
            self.markOpened()
            self.updateHeadingPath()
            await self.loadOutline()
        }
    }

    /// Flushes pending work: the debounced last-read save and every markup surface's ink. Called
    /// by the host when the window goes to the background or closes and when the reader is left.
    func suspend() async {
        saveLastReadPageNow()
        await markup.flushAll()
    }

    /// Memory warning: bumps `memoryWarningCount`, flushes ink. PDFKit purges its own caches.
    func handleMemoryWarning() {
        memoryWarningCount += 1
        let thumbnails = thumbnailsIfCreated
        Task {
            await markup.flushAll()
            await thumbnails?.purge()
        }
    }

    /// The restorable part of the session's state (for scene storage).
    var restorableState: RestorableState {
        RestorableState(pageIndex: currentPageIndex, isContentsVisible: isContentsVisible,
                        isNotesVisible: isNotesVisible, notesTab: notesTab, notesPanelWidth: notesPanelWidth,
                        history: history)
    }

    // MARK: Jumps (record section history)
    //
    // Every navigation that is not scrolling, paging or zooming is a *jump* and must go through
    // one of these: Contents, go to page, bookmarks, thumbnails, search hits, Notebook rows,
    // notes-panel rows, the level picker, first/last page. Each records section history (design:
    // "Section history"). Invalid targets return `false` and change nothing.

    /// Jumps to a zero-based page.
    @discardableResult
    func jump(toPage pageIndex: Int) -> Bool {
        guard PageNumbering.isValid(pageIndex, pageCount: pageCount) else { return false }
        recordJump(toPage: pageIndex)
        moveWithoutRecordingHistory(toPage: pageIndex)
        return true
    }

    /// Jumps to a 1-based page number typed by the reader.
    @discardableResult
    func jump(toDisplayNumber number: Int) -> Bool {
        jump(toPage: PageNumbering.pageIndex(forDisplayNumber: number))
    }

    /// Jumps to a heading's `startPage` (`false` when it has none).
    @discardableResult
    func jump(to heading: OutlineNode) -> Bool {
        guard let page = heading.startPage else { return false }
        return jump(toPage: page)
    }

    /// Resolves a stored anchor against the current outline and jumps to its start page.
    @discardableResult
    func jump(toHeading anchor: HeadingAnchor) -> Bool {
        guard let match = outline.resolve(anchor) else { return false }
        return jump(to: match.node)
    }

    /// Jumps to rects on a page (page space) and, with `mark`, marks the text under them until
    /// `pdf.clearMarks()`: for search hits (WP10).
    @discardableResult
    func jump(toPage pageIndex: Int, revealing rects: [CGRect], mark: Bool = true) -> Bool {
        guard PageNumbering.isValid(pageIndex, pageCount: pageCount) else { return false }
        recordJump(toPage: pageIndex)
        pdf.revealWithoutRecordingHistory(pageIndex: pageIndex, rects: rects, mark: mark)
        setCurrentPage(pageIndex)
        return true
    }

    /// First / last page are jumps.
    func jumpToFirstPage() { jump(toPage: 0) }
    func jumpToLastPage() { jump(toPage: pageCount - 1) }

    // MARK: Section history

    /// Back to the previous section, at the page the reader left it on.
    func goBack() {
        guard let place = history.back(from: placeOnScreen) else { return }
        moveWithoutRecordingHistory(toPage: clampedPage(place.pageIndex))
    }

    /// Forward (undoes Back), at the page the reader left it on.
    func goForward() {
        guard let place = history.forward(from: placeOnScreen) else { return }
        moveWithoutRecordingHistory(toPage: clampedPage(place.pageIndex))
    }

    /// Straight to an entry of `history.backList` / `history.forwardList` (by its `index`).
    func goToHistoryEntry(at index: Int) {
        guard let place = history.goToEntry(at: index, from: placeOnScreen) else { return }
        moveWithoutRecordingHistory(toPage: clampedPage(place.pageIndex))
    }

    // MARK: Paging (never recorded)

    func goToNextPage() { moveWithoutRecordingHistory(toPage: min(currentPageIndex + 1, pageCount - 1)) }
    func goToPreviousPage() { moveWithoutRecordingHistory(toPage: max(currentPageIndex - 1, 0)) }

    var canGoToNextPage: Bool { currentPageIndex + 1 < pageCount }
    var canGoToPreviousPage: Bool { currentPageIndex > 0 }

    /// **Not for features.** Moves the PDF view without recording section history: only for
    /// paging, history moves and restoring a position. Features navigate with `jump…`.
    func moveWithoutRecordingHistory(toPage pageIndex: Int) {
        guard PageNumbering.isValid(pageIndex, pageCount: pageCount) else { return }
        pdf.moveWithoutRecordingHistory(toPage: pageIndex)
        setCurrentPage(pageIndex)
    }

    // MARK: Zoom

    func zoomIn() { pdf.zoomIn() }
    func zoomOut() { pdf.zoomOut() }
    /// 100% (one PDF point per screen point).
    func zoomToActualSize() { pdf.zoomToActualSize() }
    /// Fit the page width to the view (the default).
    func zoomToFitWidth() { pdf.zoomToFitWidth() }

    // MARK: Mode

    /// Enters or leaves markup mode. Leaving flushes every markup surface (as Done does).
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        markup.modeDidChange(to: newMode)
        pdf.modeDidChange(to: newMode)
        if newMode == .reading {
            Task { await markup.flushAll() }
        }
    }

    func toggleMarkup() { setMode(isMarkupMode ? .reading : .markup) }
    /// The Done button: flush ink and return to reading.
    func finishMarkup() { setMode(.reading) }

    /// The drawing policy every canvas must use (`.default`; `.anyInput` under `-inkAnyInput`).
    var drawingPolicy: PKCanvasViewDrawingPolicy { markup.drawingPolicy }

    // MARK: Panels

    /// Toggles Contents: the sidebar at wide widths, the overlay at narrow widths.
    func toggleContents() {
        if isNarrowLayout { isContentsOverlayVisible.toggle() } else { isContentsVisible.toggle() }
    }
    /// Whether Contents is on screen in the current layout.
    var isContentsShown: Bool { isNarrowLayout ? isContentsOverlayVisible : isContentsVisible }
    func toggleNotes() { isNotesVisible.toggle() }
    /// Shows the notes panel on a tab.
    func showNotes(_ tab: NotesTab) {
        notesTab = tab
        isNotesVisible = true
    }

    /// A heading the Section tab should show instead of the current page's deepest heading
    /// (a same-page sibling, a chapter note opened from search or the Notebook). Set by
    /// `showNotes(_:heading:)`; the notes panel observes it, shows that heading, and clears it
    /// with `takeRequestedSectionHeading()`. `nil` when nothing is pending.
    private(set) var requestedSectionHeading: HeadingAnchor?

    /// Shows the notes panel on the Section tab for `heading` (stored anchors are fine: the
    /// panel resolves them against the current outline).
    func showNotes(_ tab: NotesTab, heading: HeadingAnchor?) {
        requestedSectionHeading = tab == .section ? heading : nil
        showNotes(tab)
    }

    /// A request to add a heading of the reader's own (design: "The reader's own headings"),
    /// made from the More menu, the menu bar or a text selection. The Contents sidebar (WP5)
    /// observes `pendingAddHeadingRequest`, presents its add-heading sheet and clears the
    /// request with `takeAddHeadingRequest()`.
    struct AddHeadingRequest: Equatable, Identifiable, Sendable {
        /// Distinguishes two requests for the same page.
        let id = UUID()
        /// Zero-based page the heading starts on.
        var pageIndex: Int
        /// Title to pre-fill (e.g. the selected text), or `nil`.
        var suggestedTitle: String?
    }

    /// The pending add-heading request, `nil` when none. Per window.
    private(set) var pendingAddHeadingRequest: AddHeadingRequest?

    /// Asks the Contents sidebar to add a heading at `atPage` (default: the current page),
    /// optionally pre-filled with `suggestedTitle`. Also shows Contents (the sidebar at wide
    /// widths, the overlay at narrow widths), because the sidebar presents the sheet.
    func requestAddHeading(atPage pageIndex: Int? = nil, suggestedTitle: String? = nil) {
        let page = pageIndex.flatMap { PageNumbering.isValid($0, pageCount: pageCount) ? $0 : nil } ?? currentPageIndex
        let title = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAddHeadingRequest = AddHeadingRequest(pageIndex: page, suggestedTitle: title?.isEmpty == false ? title : nil)
        if isNarrowLayout { isContentsOverlayVisible = true } else { isContentsVisible = true }
    }

    /// For the sidebar: the pending add-heading request, cleared on read.
    func takeAddHeadingRequest() -> AddHeadingRequest? {
        defer { pendingAddHeadingRequest = nil }
        return pendingAddHeadingRequest
    }

    /// For the notes panel: the pending requested heading, cleared on read.
    func takeRequestedSectionHeading() -> HeadingAnchor? {
        defer { requestedSectionHeading = nil }
        return requestedSectionHeading
    }
    func showSearch() { isSearchVisible = true }
    func showGoToPage() { isGoToPageVisible = true }

    // MARK: Store access

    /// Runs a store mutation attributed to this session:
    ///
    ///     try session.perform { try $0.notes.save(note) }
    ///
    /// For the async ink and compound methods pass `origin: session.origin` instead.
    func perform<T>(_ body: (LibraryStore) throws -> T) rethrows -> T {
        try store.perform(as: origin) { try body(store) }
    }

    /// Observes this book's changes imperatively (for UIKit code such as ink canvases). The
    /// handler gets only events whose `bookID` is this book's, and, unless `includeOwn`, only
    /// events not made by this session. Keep the returned token; drop or cancel it to stop.
    /// Capture `self` weakly in the handler.
    func observeBookChanges(includeOwn: Bool = false,
                            _ handler: @escaping @MainActor (StoreChangeEvent) -> Void) -> StoreChangeObservation {
        let bookID = book.id
        let origin = origin
        return store.hub.observe { event in
            guard event.change.bookID == bookID else { return }
            if !includeOwn, event.isFrom(origin) { return }
            handler(event)
        }
    }

    // MARK: Feature plug-in storage

    /// Per-session state for a feature, created on first use and kept for the session's
    /// lifetime (e.g. a search model that should survive closing its popover). One instance per
    /// type: `let model = session.featureState { SearchModel(session: session) }`.
    func featureState<T: AnyObject>(_ make: () -> T) -> T {
        let key = ObjectIdentifier(T.self)
        if let existing = featureStates[key] as? T { return existing }
        let made = make()
        featureStates[key] = made
        return made
    }

    /// The feature state of type `T` if it has been created, without creating it (e.g. menu
    /// commands that are disabled while there is no search).
    func existingFeatureState<T: AnyObject>(_ type: T.Type) -> T? {
        featureStates[ObjectIdentifier(type)] as? T
    }

    /// Keeps a feature controller alive for the session's lifetime (used by
    /// `ReaderFeatureWiring`).
    func retainFeature(_ object: AnyObject) {
        featureObjects.append(object)
    }

    // MARK: - Internal (bridge and tests)

    /// Called by the PDF bridge when PDFKit reports a new current page.
    func pdfReportedCurrentPage(_ pageIndex: Int) {
        guard PageNumbering.isValid(pageIndex, pageCount: pageCount) else { return }
        setCurrentPage(pageIndex)
    }

    /// Called by the PDF bridge when the visible pages change.
    func pdfReportedVisiblePages(_ pages: [Int]) {
        if pages != visiblePageIndices { visiblePageIndices = pages }
    }

    /// Called by the PDF bridge after the scale changes.
    func pdfReportedScale(isFitWidth: Bool) {
        if self.isFitWidth != isFitWidth { self.isFitWidth = isFitWidth }
    }

    /// Called by the PDF bridge just before PDFKit follows a link inside the PDF to a page: a
    /// jump (PDFKit moves the view itself).
    func pdfWillFollowLink(toPage pageIndex: Int) {
        guard PageNumbering.isValid(pageIndex, pageCount: pageCount) else { return }
        recordJump(toPage: pageIndex)
    }

    /// Saves `lastReadPageIndex` now if it changed (cancels the pending debounced save). Each
    /// save posts `.bookSaved` to every window, which is why it is debounced.
    func saveLastReadPageNow() {
        lastReadSaveTask?.cancel()
        lastReadSaveTask = nil
        guard closeReason == nil, lastSavedPageIndex != currentPageIndex else { return }
        do {
            guard var stored = try store.books.book(id: book.id) else { return }
            stored.lastReadPageIndex = currentPageIndex
            stored.lastOpenedAt = Date()
            try perform { try $0.books.save(stored) }
            lastSavedPageIndex = currentPageIndex
            book = stored
        } catch {
            // Keep `lastSavedPageIndex` so the next change retries.
        }
    }

    // MARK: - Private

    /// The place on screen now (current page and its section).
    private var placeOnScreen: SectionPlace { SectionPlace(pageIndex: currentPageIndex, in: outline) }

    private func recordJump(toPage pageIndex: Int) {
        history.recordJump(from: placeOnScreen, to: SectionPlace(pageIndex: pageIndex, in: outline))
    }

    private func clampedPage(_ pageIndex: Int) -> Int {
        min(max(pageIndex, 0), max(pageCount - 1, 0))
    }

    private func setCurrentPage(_ pageIndex: Int) {
        guard pageIndex != currentPageIndex else { return }
        currentPageIndex = pageIndex
        updateHeadingPath()
        scheduleLastReadSave()
    }

    private func updateHeadingPath() {
        let path = outline.headingPath(forPage: currentPageIndex)
        if path.map(\.anchor) != headingPath.map(\.anchor) { headingPath = path }
    }

    private func scheduleLastReadSave() {
        lastReadSaveTask?.cancel()
        let delay = configuration.lastReadSaveDelay
        lastReadSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveLastReadPageNow()
        }
    }

    private func markOpened() {
        guard closeReason == nil, var stored = try? store.books.book(id: book.id) else { return }
        stored.lastOpenedAt = Date()
        try? perform { try $0.books.save(stored) }
        book = stored
    }

    private func handle(_ event: StoreChangeEvent) {
        let change = event.change
        guard change.bookID == book.id else { return }
        revisions.record(change)
        if !event.isFrom(origin) { externalRevisions.record(change) }

        switch change {
        case .bookDeleted:
            lastReadSaveTask?.cancel()
            closeReason = .bookDeleted
            if mode == .markup { mode = .reading; markup.modeDidChange(to: .reading) }
        case .bookSaved:
            if !event.isFrom(origin), let stored = try? store.books.book(id: book.id) {
                book = stored
            }
        case .userHeadingsChanged:
            Task { await rebuildOutline() }
        case .noteSaved, .noteRemoved, .highlightsChanged, .bookmarksChanged:
            scheduleNotebookRebuild()
        case .pageInkChanged, .noteInkChanged:
            break
        }
    }

    private func loadOutline() async {
        if rawOutlineEntries == nil {
            rawOutlineEntries = await ReaderDocumentLoader.outlineEntries(at: documentURL)
        }
        await rebuildOutline()
    }

    private func rebuildOutline() async {
        guard let entries = rawOutlineEntries else { return }
        outlineGeneration += 1
        let generation = outlineGeneration
        let userHeadings = (try? store.headings.userHeadings(bookID: book.id)) ?? []
        let built = await ReaderDocumentLoader.buildOutline(entries: entries, userHeadings: userHeadings,
                                                             pageCount: pageCount)
        guard generation == outlineGeneration else { return }
        outline = built
        isOutlineLoaded = true
        updateHeadingPath()
        scheduleNotebookRebuild(immediately: true)
    }

    private func scheduleNotebookRebuild(immediately: Bool = false) {
        guard isOutlineLoaded else { return }
        notebookTask?.cancel()
        let delay = configuration.notebookRebuildDelay
        notebookTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.rebuildNotebook()
        }
    }

    private func rebuildNotebook() async {
        guard closeReason == nil else { return }
        notebookGeneration += 1
        let generation = notebookGeneration
        let bookID = book.id
        let notes = (try? store.notes.notes(bookID: bookID)) ?? []
        let highlights = (try? store.highlights.highlights(bookID: bookID)) ?? []
        let bookmarks = (try? store.bookmarks.bookmarks(bookID: bookID)) ?? []
        let built = await ReaderDocumentLoader.buildNotebook(outline: outline, notes: notes,
                                                             highlights: highlights, bookmarks: bookmarks)
        guard generation == notebookGeneration else { return }
        notebook = built
    }
}
