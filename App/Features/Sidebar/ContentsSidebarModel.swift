import Foundation
import Observation
import ReaderCore

/// The sidebar's per-window state (one per `ReaderSession`, kept in `session.featureState`, so
/// it survives hiding the sidebar, switching tabs and rebuilding the outline): the Contents
/// expansion and its flattened visible rows, current-section tracking, the bookmark list, page
/// marks for the Pages grid (notes and highlights; ink is not flagged: owner decision, ink
/// navigation lives in the Notebook), and the thumbnail loader.
///
/// It reads only its own window's session and reacts to changes through observation of the
/// session (`outline`, `headingPath`, `history`, `notebook`, `revisions.bookmarks`,
/// `memoryWarningCount`, `pendingAddHeadingRequest`);
/// it never subscribes to `store.hub`. It never moves the PDF: the only navigation is
/// `session.jump(…)` from an explicit tap.
@Observable
@MainActor
final class ContentsSidebarModel {
    /// The add/edit heading sheet to show.
    struct HeadingSheetRequest: Identifiable, Equatable {
        enum Mode: Equatable {
            case add(pageIndex: Int, title: String)
            case edit(anchor: HeadingAnchor)
        }
        let id = UUID()
        let mode: Mode
    }

    /// A request for the Contents list to scroll a row into view (the view performs it).
    struct ScrollRequest: Equatable {
        let anchor: HeadingAnchor
        let serial: Int
        let animated: Bool
    }

    /// What the Pages grid flags on a page (from the Notebook).
    struct PageMarks: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let note = PageMarks(rawValue: 1)
        static let highlight = PageMarks(rawValue: 2)
    }

    // MARK: Contents

    private(set) var expansion = ContentsExpansion()
    /// The visible rows of the Contents tree (children of collapsed headings excluded).
    private(set) var rows: [ContentsRow] = []
    /// Anchors of the current page's heading path.
    private(set) var currentPath: Set<HeadingAnchor> = []
    /// The row standing for the current section (the deepest visible heading of the path).
    private(set) var currentRow: HeadingAnchor?
    /// The latest scroll request for the Contents list.
    private(set) var scrollRequest: ScrollRequest?

    // MARK: The reader's headings

    /// The add/edit heading sheet to show (any entry point sets it; the sidebar presents it).
    var headingSheet: HeadingSheetRequest?
    /// The heading just added or edited: revealed and shown selected in Contents until the reader
    /// taps a heading or adds another.
    private(set) var selectedHeading: HeadingAnchor?
    /// The placement used last in this window (the sheet re-applies it).
    @ObservationIgnored private(set) var lastPlacement: HeadingPlacementMemory?
    /// Increases when a heading was added or edited, so the sidebar can switch to Contents.
    private(set) var headingSaveCount = 0

    // MARK: Pages and bookmarks

    /// The book's bookmarks, ascending by page.
    private(set) var bookmarks: [Bookmark] = []
    private(set) var bookmarkedPages: Set<Int> = []
    /// Pages with a page note or highlights.
    private(set) var pageMarks: [Int: PageMarks] = [:]
    /// Thumbnails for the Pages grid and the Bookmarks list.
    @ObservationIgnored let thumbnails: ThumbnailLoader

    // MARK: Private

    @ObservationIgnored unowned let session: ReaderSession
    /// Rows the Contents list has on screen (from row appear/disappear; not observed).
    @ObservationIgnored private(set) var onScreen: Set<HeadingAnchor> = []
    @ObservationIgnored private var rowAnchors: Set<HeadingAnchor> = []
    @ObservationIgnored private var lastHistory: SectionHistory?
    @ObservationIgnored private var pendingReveal: HeadingAnchor?
    @ObservationIgnored private var scrollSerial = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastMemoryWarningCount = 0

    init(session: ReaderSession, thumbnails: ThumbnailLoader? = nil) {
        self.session = session
        self.thumbnails = thumbnails ?? ThumbnailLoader(session: session)
    }

    /// The window's model (created on first use).
    static func shared(for session: ReaderSession) -> ContentsSidebarModel {
        let model = session.featureState { ContentsSidebarModel(session: session) }
        model.start()
        return model
    }

    /// Starts following the session. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        SidebarDebugSeed.seedIfRequested(session: session)
        #endif
        track({ $0.session.outline }, then: { $0.outlineDidChange() })
        track({ ($0.session.headingPath, $0.session.history) }, then: { $0.sectionDidChange() })
        track({ $0.session.notebook }, then: { $0.notebookDidChange() })
        track({ $0.session.revisions.bookmarks }, then: { $0.reloadBookmarks() })
        lastMemoryWarningCount = session.memoryWarningCount
        track({ $0.session.memoryWarningCount }, then: { $0.memoryWarningDidChange() })
        track({ $0.session.pendingAddHeadingRequest }, then: { $0.takeAddHeadingRequest() })
    }

    /// The shell's (or the selection menu's) add-heading request: handled once.
    private func takeAddHeadingRequest() {
        guard session.pendingAddHeadingRequest != nil, let request = session.takeAddHeadingRequest() else { return }
        presentAddHeading(atPage: request.pageIndex, title: request.suggestedTitle ?? "")
    }

    private func memoryWarningDidChange() {
        guard session.memoryWarningCount != lastMemoryWarningCount else { return }
        lastMemoryWarningCount = session.memoryWarningCount
        thumbnails.purge()
    }

    // MARK: Contents: reader actions

    /// The reader tapped a heading: jump through the session (records section history).
    func select(_ node: OutlineNode) {
        selectedHeading = nil
        session.jump(to: node)
    }

    // MARK: The reader's headings

    /// Opens the add-heading sheet at a zero-based page with an optional suggested title.
    func presentAddHeading(atPage pageIndex: Int, title: String = "") {
        let page = PageNumbering.isValid(pageIndex, pageCount: session.pageCount) ? pageIndex : session.currentPageIndex
        headingSheet = HeadingSheetRequest(mode: .add(pageIndex: page, title: title))
    }

    /// Opens the edit sheet (title, page, placement) for a reader's heading.
    func presentEdit(_ node: OutlineNode) {
        guard node.isEditable else { return }
        headingSheet = HeadingSheetRequest(mode: .edit(anchor: node.anchor))
    }

    /// The sheet saved a heading: remember the placement, reveal and select it.
    func headingSaved(_ anchor: HeadingAnchor, placement: HeadingParentChoice, isNew: Bool) {
        if isNew { lastPlacement = HeadingPlacementMemory(parent: placement.anchor, childLevel: placement.childLevel) }
        selectedHeading = anchor
        headingSaveCount += 1
        revealWhenAvailable(anchor)
    }

    /// The reader tapped a disclosure chevron.
    func toggle(_ anchor: HeadingAnchor) {
        expansion.toggle(anchor)
        rebuildRows()
    }

    /// Expands or collapses (VoiceOver actions, keyboard).
    func setExpanded(_ anchor: HeadingAnchor, _ expanded: Bool) {
        guard expansion.isExpanded(anchor) != expanded else { return }
        toggle(anchor)
    }

    /// Reveal a heading in the outline the session builds next (after adding or moving it): its
    /// ancestors open and the list scrolls to it. If it is already in the current outline it is
    /// revealed now too.
    func revealWhenAvailable(_ anchor: HeadingAnchor) {
        pendingReveal = anchor
        if !session.outline.lineage(of: anchor).isEmpty {
            applyPendingReveal()
            pendingReveal = anchor  // again after the rebuild (its place may have changed)
        }
    }

    // MARK: Contents: list callbacks

    func rowAppeared(_ anchor: HeadingAnchor) { onScreen.insert(anchor) }
    func rowDisappeared(_ anchor: HeadingAnchor) { onScreen.remove(anchor) }

    /// The Contents list appeared (sidebar shown, tab selected): reveal the current section and
    /// centre it, without animation.
    func contentsAppeared() {
        if expansion.reveal(path: session.headingPath) { rebuildRows() }
        updateCurrent()
        if let currentRow { requestScroll(to: currentRow, animated: false) }
    }

    func contentsDisappeared() {
        onScreen.removeAll()
    }

    // MARK: Observation handlers

    private func outlineDidChange() {
        let outline = session.outline
        guard session.isOutlineLoaded else { return }
        if !expansion.hasDefaults {
            expansion.applyDefaultsIfNeeded(for: outline)
            expansion.reveal(path: session.headingPath)
        }
        rebuildRows()
        applyPendingReveal()
    }

    /// Current-section tracking (see `ContentsTree.shouldFollow` for the rule).
    private func sectionDidChange() {
        let path = session.headingPath
        let history = session.history
        let isJump = lastHistory.map { $0 != history } ?? false
        lastHistory = history
        let follow = ContentsTree.shouldFollow(isJump: isJump, previousCurrentRow: currentRow, onScreen: onScreen)
        if follow, expansion.reveal(path: path) {
            rebuildRows()
        } else {
            updateCurrent()
        }
        if follow, let currentRow, !onScreen.contains(currentRow) {
            requestScroll(to: currentRow, animated: true)
        }
    }

    private func notebookDidChange() {
        guard let notebook = session.notebook else { pageMarks = [:]; return }
        let marks = Self.pageMarks(notebook)
        if marks != pageMarks { pageMarks = marks }
    }

    func reloadBookmarks() {
        let list = ((try? session.store.bookmarks.bookmarks(bookID: session.book.id)) ?? [])
        let sorted = Self.sortedBookmarks(list)
        if sorted != bookmarks {
            bookmarks = sorted
            bookmarkedPages = Set(sorted.map(\.pageIndex))
        }
    }

    // MARK: Rows and current

    private func rebuildRows() {
        let newRows = ContentsTree.visibleRows(session.outline, expanded: expansion.expanded)
        if newRows != rows { rows = newRows }
        rowAnchors = Set(newRows.map(\.anchor))
        updateCurrent()
    }

    private func updateCurrent() {
        let path = session.headingPath
        let pathSet = Set(path.map(\.anchor))
        if pathSet != currentPath { currentPath = pathSet }
        let row = ContentsTree.currentRowAnchor(path: path, visibleAnchors: rowAnchors)
        if row != currentRow { currentRow = row }
    }

    private func applyPendingReveal() {
        guard let anchor = pendingReveal else { return }
        let lineage = session.outline.lineage(of: anchor)
        guard !lineage.isEmpty else { return }
        pendingReveal = nil
        expansion.expandLineage(lineage)
        rebuildRows()
        requestScroll(to: anchor, animated: true)
    }

    private func requestScroll(to anchor: HeadingAnchor, animated: Bool) {
        scrollSerial += 1
        scrollRequest = ScrollRequest(anchor: anchor, serial: scrollSerial, animated: animated)
    }

    // MARK: Pure helpers

    /// Pages with a page note or highlights, from the Notebook tree.
    static func pageMarks(_ notebook: Notebook) -> [Int: PageMarks] {
        var marks: [Int: PageMarks] = [:]
        func add(_ pages: [NotebookPage]) {
            for page in pages {
                var mark: PageMarks = []
                if page.note != nil { mark.insert(.note) }
                if !page.highlights.isEmpty { mark.insert(.highlight) }
                if !mark.isEmpty { marks[page.pageIndex, default: []].formUnion(mark) }
            }
        }
        add(notebook.frontMatter)
        var stack = notebook.sections
        while let section = stack.popLast() {
            add(section.pages)
            stack.append(contentsOf: section.children)
        }
        return marks
    }

    /// Bookmarks in page order (ties by creation time); one entry per page.
    static func sortedBookmarks(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var seen = Set<Int>()
        return bookmarks.sorted { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
            .filter { seen.insert($0.pageIndex).inserted }
    }

    // MARK: Observation

    /// Calls `then` now and again (on the next main-actor turn) every time a property read in
    /// `read` changes. `read` must only read the session (never this model), so handlers that
    /// mutate the model cannot re-trigger themselves.
    private func track<T>(_ read: @escaping @MainActor (ContentsSidebarModel) -> T,
                          then handler: @escaping @MainActor (ContentsSidebarModel) -> Void) {
        withObservationTracking {
            _ = read(self)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.track(read, then: handler)
            }
        }
        handler(self)
    }
}
