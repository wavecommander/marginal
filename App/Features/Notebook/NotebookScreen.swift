import ReaderCore
import SwiftUI

/// The Notebook of one book: every note and highlight laid out along the book's outline, with
/// a heading filter column, a type filter, search, and export (design: "Notebook · all notes by
/// heading"). At the top, "Exported PDFs" lists the book's marked-up PDF exports, running and
/// finished, with Share and Delete (`MarkedUpExportsSection`).
///
/// Export offers Markdown (one text-only file), Markdown as a ZIP (with the images of handwritten
/// notes and of pages with handwriting, in folders) and PDF. Choosing plain Markdown for an export
/// that has such images first says so and offers the ZIP. Export takes the whole Notebook, or, after "Select", the rows the reader ticked: each row
/// then has a checkbox, a header's checkbox ticks everything shown under it, and the selection
/// is kept while the filters and the search change, so it can span headings.
///
/// Shown in place in any window (pushed on the window's navigation stack, so the system back
/// button returns to the Library) and as the first screen of a Notebook window
/// (`WindowID.notebook`, keyed by book ID). Filter, search and scroll position belong to the
/// window (scene storage keyed by book), so two windows on one Notebook are independent. The
/// scroll position is saved as the feed scrolls and read back once, when the screen loads.
///
/// Rows open the reader at their page (a heading: its start page) in this window through
/// `WindowContext.openReader(bookID:pageIndex:)`; their context menu also opens a new window.
struct NotebookScreen: View {
    let bookID: UUID
    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @State private var model: NotebookModel?
    @SceneStorage private var scopeKey: String
    @SceneStorage private var typeKey: String
    @SceneStorage private var query: String
    @SceneStorage private var scrollAnchor: String?

    init(bookID: UUID) {
        self.bookID = bookID
        let prefix = "notebook.\(bookID.uuidString)"
        _scopeKey = SceneStorage(wrappedValue: NotebookScope.all.storageKey, "\(prefix).scope")
        _typeKey = SceneStorage(wrappedValue: NotebookTypeFilter.all.rawValue, "\(prefix).type")
        _query = SceneStorage(wrappedValue: "", "\(prefix).query")
        _scrollAnchor = SceneStorage("\(prefix).scroll")
    }

    var body: some View {
        Group {
            if let model {
                NotebookContent(model: model, scopeKey: $scopeKey, typeKey: $typeKey, query: $query,
                                scrollAnchor: $scrollAnchor)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await start() }
    }

    private func start() async {
        if model == nil {
            model = NotebookModel(store: environment.store, bookID: bookID)
        }
        #if DEBUG
        if NotebookDebugSeed.isRequested {
            _ = await environment.launchPlan()
            await NotebookDebugSeed.seedIfNeeded(store: environment.store, bookID: bookID)
        }
        #endif
        await model?.start()
        if model?.phase == .missing {
            // Never leave a dead Notebook on screen: drop this route (an empty Notebook window
            // closes, a Library window shows the Library).
            window.bookWasDeleted(bookID)
        }
    }
}

/// The loaded screen.
private struct NotebookContent: View {
    @Environment(\.accentTheme) private var accentTheme
    let model: NotebookModel
    @Binding var scopeKey: String
    @Binding var typeKey: String
    @Binding var query: String
    @Binding var scrollAnchor: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rows: [NotebookFeedRow] = []
    /// `rows` split at every heading: the heading stays pinned while its rows scroll beneath.
    @State private var sections: [NotebookFeedSection] = []
    /// The feed's visible height, for scrolling a row to just below the pinned heading.
    @State private var feedHeight: CGFloat = 600
    @State private var entries: [NotebookScopeEntry] = []
    @State private var feedVersion = 0
    @State private var didRestoreScroll = false
    /// The row at the top of the feed: what the scroll view reads and writes. Kept apart from
    /// `scrollAnchor` (scene storage), which is only written from here and read once, when the
    /// feed first loads. Scene storage is shared by every Notebook screen of the book in the
    /// window (Notebook, a row's reader, its Notebook again), and a scroll view bound to it
    /// straight was pulled back by the screen underneath while it scrolled.
    @State private var topRowID: String?
    @State private var isWide = true
    @State private var export = NotebookExportController()
    /// The note whose deletion is being confirmed.
    @State private var deleteCandidate: Note?
    /// Undo pill state after deleting a note from this Notebook.
    @State private var undoController = DeletedNoteUndoController()
    /// Choosing what to export: rows show checkboxes and tapping one ticks it.
    @State private var isSelecting = false
    /// The ticked items (kept across filter changes; items that no longer exist are dropped).
    @State private var selection: Set<NotebookItemID> = []
    /// A Markdown export waiting for the reader's answer to "Images Are Not Included".
    @State private var textOnlyCandidate: Notebook?
    /// `NotebookFeed.itemsByHeader(rows)`: what each header's checkbox stands for.
    @State private var headerItems: [String: [NotebookItemID]] = [:]
    /// The map of the whole book above the feed (`NotebookMapStrip`), for the current type
    /// filter and search.
    @State private var map: NotebookMap?
    /// The feed rows on screen (iPadOS 18 and later; earlier, only the top row), for the
    /// map's box.
    @State private var visibleRowIDs: Set<String> = []
    /// An item chosen on the map that is outside the chosen heading: the feed scrolls to it
    /// once it shows the whole book again.
    @State private var pendingMapTarget: String?
    /// The reader hid the map. Remembered for every book and window, like the notes panel's
    /// collapsed lists.
    @AppStorage(NotebookMapStrip.hiddenKey) private var isMapHidden = false

    /// Below this window width (or in a compact size class) the filter column collapses into a
    /// toolbar menu.
    static let wideThreshold: CGFloat = 760

    private var filter: NotebookFilter {
        NotebookFilter(scope: NotebookScope(storageKey: scopeKey) ?? .all,
                       type: NotebookTypeFilter(rawValue: typeKey) ?? .all, query: query)
    }

    private struct FeedInput: Equatable {
        let build: Int
        let filter: NotebookFilter
    }

    #if DEBUG
    /// `-notebookDebugWidth <points>`: lays the screen out as if the window were that wide (for
    /// narrow-width screenshots on a simulator that cannot resize windows).
    private let debugWidth = NotebookDebugSeed.debugWidth
    #else
    private let debugWidth: CGFloat? = nil
    #endif

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if isWide {
                    scopeColumn
                        .frame(width: 280)
                    Divider().ignoresSafeArea(edges: .bottom)
                }
                feedColumn
            }
            .frame(maxWidth: debugWidth ?? .infinity)
            .frame(maxWidth: .infinity)
            .onChange(of: min(geometry.size.width, debugWidth ?? .infinity), initial: true) { _, width in
                let wide = sizeClass != .compact && width >= Self.wideThreshold
                if wide != isWide { isWide = wide }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .notebookSubtitle(model.book?.title ?? "", title: title)
        .searchable(text: $query, prompt: "Search Notes and Highlights")
        .toolbar { toolbar }
        // Same wording as the notes panel's Delete Note (design: "Deleting a note").
        .alert("Delete This Note?", isPresented: Binding(get: { deleteCandidate != nil },
                                                         set: { if !$0 { deleteCandidate = nil } }),
               presenting: deleteCandidate) { note in
            Button("Delete", role: .destructive) {
                Task {
                    let result = await model.deleteNoteResult(note)
                    if result.deleted, let snapshot = result.snapshot {
                        undoController.offer(snapshot) { item in
                            await model.restoreDeletedNote(item)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { note in
            Text(NotesPanel.deleteMessage(hasInk: note.hasInk))
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .missing { undoController.dismiss() }
        }
        .overlay(alignment: .bottom) {
            DeletedNoteUndoPill(controller: undoController)
                .padding(.bottom, Space.l)
                .padding(.horizontal, Space.m)
        }
        .overlay(alignment: .topTrailing) {
            NotebookShareSheetAnchor(item: export.sharedResult?.fileURL, onFinish: export.shareDidFinish)
                .frame(width: 1, height: 1)
                .padding(.trailing, 28)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay { exportProgress }
        .alert("Export Failed", isPresented: exportFailed) {
            Button("OK") { export.dismissError() }
        } message: {
            if case .failed(let message) = export.state { Text(message) }
        }
        .alert("Images Are Not Included", isPresented: Binding(get: { textOnlyCandidate != nil },
                                                               set: { if !$0 { textOnlyCandidate = nil } }),
               presenting: textOnlyCandidate) { notebook in
            Button("Export as ZIP") { start(.markdownZip, notebook) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(NotebookAccessibilityID.exportAsZip)
            Button("Export Text Only") { start(.markdown, notebook) }
                .accessibilityIdentifier(NotebookAccessibilityID.exportTextOnly)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Markdown exports text only. To include handwritten notes, handwriting on pages and highlights on scanned pages as images, export as Markdown (ZIP).")
        }
        .task(id: FeedInput(build: model.buildCount, filter: filter)) { await recomputeFeed() }
        .onDisappear { if export.isRunning { export.cancel() } }
    }

    // MARK: Feed

    private func recomputeFeed() async {
        let filter = self.filter
        if filter.isSearching {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
        }
        guard let notebook = model.notebook else {
            rows = []
            sections = []
            entries = []
            headerItems = [:]
            map = nil
            return
        }
        let pageCount = model.book?.pageCount ?? 0
        let computed = await Self.compute(notebook, filter: filter, pageCount: pageCount)
        guard !Task.isCancelled else { return }
        if !selection.isEmpty { selection.formIntersection(computed.items) }
        if computed.entries.contains(where: { $0.scope == filter.scope }) || filter.scope == .all {
            rows = computed.rows
            sections = NotebookFeed.sections(computed.rows)
            headerItems = computed.headerItems
        } else {
            // The chosen heading has no content any more (deleted from another window).
            scopeKey = NotebookScope.all.storageKey
            return
        }
        entries = computed.entries
        map = computed.map
        feedVersion += 1
    }

    @concurrent
    private static func compute(_ notebook: Notebook, filter: NotebookFilter, pageCount: Int) async
        -> (rows: [NotebookFeedRow], entries: [NotebookScopeEntry], headerItems: [String: [NotebookItemID]],
            items: Set<NotebookItemID>, map: NotebookMap) {
        let rows = NotebookFeed.rows(for: notebook, filter: filter)
        // The map always covers the whole book, whatever heading the feed is showing.
        var bookFilter = filter
        bookFilter.scope = .all
        let bookRows = filter.scope == .all ? rows : NotebookFeed.rows(for: notebook, filter: bookFilter)
        let lastPage = bookRows.compactMap(\.targetPage).max() ?? 0
        let map = NotebookMap(notebook: notebook, rows: bookRows, pageCount: max(pageCount, lastPage + 1))
        return (rows, NotebookFeed.scopeEntries(for: notebook), NotebookFeed.itemsByHeader(rows), notebook.itemIDs, map)
    }

    // MARK: Map

    /// The pages the feed has on screen, for the map's box.
    private var pagesInView: ClosedRange<Int>? {
        let ids = visibleRowIDs.isEmpty ? Set([topRowID ?? rows.first?.id].compactMap { $0 }) : visibleRowIDs
        return NotebookMap.pageRange(ofRows: ids, in: rows)
    }

    /// Scrolls the feed to an item chosen on the map; one outside the chosen heading first
    /// widens the feed to the whole book.
    private func scrollToMapItem(_ mark: NotebookMap.Mark) {
        if rows.contains(where: { $0.id == mark.id }) {
            withAnimation(.snappy(duration: 0.3)) { topRowID = mark.id }
        } else {
            pendingMapTarget = mark.id
            scopeKey = NotebookScope.all.storageKey
        }
    }

    @ViewBuilder
    private var mapStrip: some View {
        if let map, !map.marks.isEmpty, !isMapHidden {
            NotebookMapStrip(map: map, inView: pagesInView, choose: scrollToMapItem)
                .frame(maxWidth: 780)
                .padding(.horizontal, isWide ? 36 : 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .zIndex(1)
                .transition(.opacity)
        }
    }

    /// Hides the map and shows it again, at the end of the type filter's row. Only there when
    /// there is a map to show.
    @ViewBuilder
    private var mapToggle: some View {
        if let map, !map.marks.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isMapHidden.toggle() }
            } label: {
                // One glyph either way, like the reader's notes button; the label says the state.
                Label(isMapHidden ? "Show Map" : "Hide Map", systemImage: "rectangle.topthird.inset.filled")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 40, minHeight: 36)
            }
            .tint(Color.primary)
            .accessibilityIdentifier(NotebookAccessibilityID.mapToggle)
        }
    }

    // MARK: Selection

    private var title: String {
        guard isSelecting else { return "Notebook" }
        return selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    /// The items a row's checkbox stands for: its own, or for a header everything shown under it.
    private func items(of row: NotebookFeedRow) -> [NotebookItemID] {
        row.itemID.map { [$0] } ?? headerItems[row.id] ?? []
    }

    /// Ticks the row, or unticks it when all of it is ticked already.
    private func toggle(_ row: NotebookFeedRow) {
        let items = items(of: row)
        if NotebookFeed.selectionState(of: items, in: selection) == .all {
            selection.subtract(items)
        } else {
            selection.formUnion(items)
        }
    }

    /// Whether everything the feed shows now is ticked ("Select All" then reads "Deselect All").
    private var allShownAreSelected: Bool {
        let shown = NotebookFeed.items(in: rows)
        return !shown.isEmpty && selection.isSuperset(of: shown)
    }

    private func toggleAllShown() {
        let shown = NotebookFeed.items(in: rows)
        if selection.isSuperset(of: shown) {
            selection.subtract(shown)
        } else {
            selection.formUnion(shown)
        }
    }

    private func setSelecting(_ selecting: Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            isSelecting = selecting
            if !selecting { selection = [] }
        }
    }

    /// The type filter: segmented when wide; a menu when narrow, where five segments would be
    /// truncated.
    @ViewBuilder
    private var typePicker: some View {
        let picker = Picker("Show", selection: $typeKey) {
            ForEach(NotebookTypeFilter.allCases, id: \.self) { type in
                Text(type.title).tag(type.rawValue)
            }
        }
        if isWide {
            picker.pickerStyle(.segmented)
        } else {
            picker.pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var feedColumn: some View {
        VStack(spacing: 0) {
            MarkedUpExportsSection(book: model.book, bookID: model.bookID, library: environment.markedUpExports,
                                   store: environment.store, isWide: isWide)
            HStack(spacing: 8) {
                typePicker
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(NotebookAccessibilityID.typeFilter)
                mapToggle
            }
            .padding(.horizontal, isWide ? 36 : 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 780 + 72)

            mapStrip

            ZStack {
                feed
                emptyState
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Where a row lands when the feed scrolls to it: just below the pinned heading, not under it.
    private static let pinnedHeadingRoom: CGFloat = 64

    private var rowAnchor: UnitPoint {
        UnitPoint(x: 0.5, y: min(Self.pinnedHeadingRoom / max(feedHeight, 1), 0.4))
    }

    /// One row of the feed (a heading or an item), with its checkbox while selecting.
    private func rowView(_ row: NotebookFeedRow) -> some View {
        NotebookRowView(row: row, model: model, actions: rowActions,
                        selection: isSelecting ? NotebookFeed.selectionState(of: items(of: row), in: selection) : nil,
                        toggle: { toggle(row) })
            .id(row.id)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Each heading stays pinned at the top while its rows scroll beneath it, until the
                // next heading takes its place.
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { row in rowView(row) }
                        } header: {
                            if let header = section.header {
                                rowView(header)
                                    .padding(.bottom, 4)
                                    .background(Color(uiColor: .systemBackground).padding(.horizontal, -12))
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, isWide ? 36 : 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $topRowID, anchor: rowAnchor)
            .onChange(of: topRowID) { _, id in
                // Not before the saved place has been read back (below).
                if didRestoreScroll, id != scrollAnchor { scrollAnchor = id }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { feedHeight = $0 }
            .modifier(NotebookVisibleRows(ids: $visibleRowIDs))
            .accessibilityIdentifier(NotebookAccessibilityID.feed)
            .onChange(of: feedVersion) { _, _ in
                if let target = pendingMapTarget, rows.contains(where: { $0.id == target }) {
                    pendingMapTarget = nil
                    proxy.scrollTo(target, anchor: rowAnchor)
                }
                if !didRestoreScroll {
                    didRestoreScroll = true
                    if let anchor = scrollAnchor, rows.contains(where: { $0.id == anchor }) {
                        topRowID = anchor
                        proxy.scrollTo(anchor, anchor: rowAnchor)
                    }
                }
            }
            .onChange(of: filter) { _, _ in
                if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.phase == .missing {
            ContentUnavailableView("Book Not Found", systemImage: "book.closed",
                                   description: Text("This book is no longer in the library."))
        } else if let notebook = model.notebook, feedVersion > 0, rows.isEmpty {
            Group {
                if NotebookFeed.itemCount(notebook) == 0 {
                    ContentUnavailableView {
                        Label("No Notes Yet", systemImage: "note.text")
                    } description: {
                        Text("Notes, highlights and handwriting you make in this book appear here, laid out along its contents.")
                    } actions: {
                        Button("Open Book") { window.openReader(bookID: model.bookID) }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(accentTheme.onAccent)
                    }
                } else if filter.isSearching {
                    ContentUnavailableView.search(text: filter.trimmedQuery)
                } else {
                    ContentUnavailableView("No \(filter.type.title)", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Nothing of this kind under the chosen heading."))
                }
            }
            .accessibilityIdentifier(NotebookAccessibilityID.empty)
        } else if model.notebook == nil {
            ProgressView()
        }
    }

    private var rowActions: NotebookRowActions {
        let bookID = model.bookID
        let store = environment.store
        return NotebookRowActions(
            open: { page, notesTab, heading in
                window.openReader(bookID: bookID, pageIndex: page, notesTab: notesTab,
                                  notesHeading: heading, hideNotesPanel: notesTab == nil)
            },
            openInNewWindow: { page, notesTab, heading in
                NotebookNavigation.openInNewWindow(bookID: bookID, pageIndex: page, notesTab: notesTab,
                                                   notesHeading: heading, hideNotesPanel: notesTab == nil,
                                                   store: store, window: window)
            },
            deleteNote: { note in deleteCandidate = note })
    }

    // MARK: Filter column

    private var scopeSelection: Binding<String?> {
        Binding(get: { scopeKey }, set: { scopeKey = $0 ?? NotebookScope.all.storageKey })
    }

    private var scopeColumn: some View {
        List(selection: scopeSelection) {
            Section("Headings with notes") {
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .fontWeight(entry.level <= 1 ? .semibold : .regular)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(entry.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.leading, CGFloat(min(max(entry.level - 1, 0), 4)) * 16)
                    .tag(entry.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(entry.title)
                    .accessibilityValue("\(entry.count) \(entry.count == 1 ? "item" : "items")")
                    .accessibilityIdentifier(NotebookAccessibilityID.scope(entry.title))
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(NotebookAccessibilityID.scopeColumn)
    }

    private var currentScopeTitle: String {
        entries.first { $0.id == scopeKey }?.title ?? "Whole book"
    }

    // MARK: Toolbar

    /// While the Notebook loads, Open Book, Select and the Export menu are already enabled (only
    /// the formats inside Export wait for it). Dimming them until the load finished changed the
    /// toolbar a second time just after the push's morph (TSOFT-230). Once loaded, the rules are
    /// as before: Select needs something to select.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isWide {
                Menu {
                    Picker("Heading", selection: $scopeKey) {
                        ForEach(entries) { entry in
                            Text(String(repeating: "   ", count: min(max(entry.level - 1, 0), 4)) + entry.title)
                                .tag(entry.id)
                        }
                    }
                } label: {
                    Label(currentScopeTitle, systemImage: "list.bullet.indent")
                }
                .accessibilityLabel("Heading: \(currentScopeTitle)")
                .accessibilityIdentifier(NotebookAccessibilityID.scopeMenu)
                .toolbarGlyph()
            }
            if isSelecting {
                Button(allShownAreSelected ? "Deselect All" : "Select All") { toggleAllShown() }
                    .disabled(rows.isEmpty)
                    .accessibilityIdentifier(NotebookAccessibilityID.selectAll)
                    .toolbarGlyph()
            } else {
                Button {
                    window.openReader(bookID: model.bookID)
                } label: {
                    Label("Open Book", systemImage: "book")
                }
                .disabled(model.phase == .missing)
                .accessibilityIdentifier(NotebookAccessibilityID.openBook)
                .toolbarGlyph()
                Button("Select") { setSelecting(true) }
                    .disabled(model.notebook.map { NotebookFeed.itemCount($0) == 0 } ?? (model.phase == .missing))
                    .accessibilityHint("Choose which notes to export")
                    .accessibilityIdentifier(NotebookAccessibilityID.select)
                    .toolbarGlyph()
            }
            Menu {
                Section(isSelecting ? "Export \(selection.count) Selected" : "Export Whole Notebook") {
                    ForEach(NotebookExportFormat.allCases) { format in
                        Button {
                            startExport(format)
                        } label: {
                            Label(format.title, systemImage: format.systemImage)
                            Text(format.subtitle)
                        }
                        .accessibilityIdentifier(format.accessibilityID)
                    }
                }
                .disabled(model.notebook == nil)
            } label: {
                if isWide {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                } else {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(model.phase == .missing || export.state != .idle || (isSelecting && selection.isEmpty))
            .accessibilityIdentifier(NotebookAccessibilityID.exportMenu)
            .toolbarGlyph()
            if isSelecting {
                Button("Done") { setSelecting(false) }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier(NotebookAccessibilityID.selectDone)
            }
        }
    }

    /// Exports the whole Notebook, or the ticked items while choosing. Plain Markdown is text
    /// only: when the export has images, the reader is first told to use the ZIP for them.
    private func startExport(_ format: NotebookExportFormat) {
        guard let whole = model.notebook else { return }
        let notebook = isSelecting ? whole.selecting(selection) : whole
        if format == .markdown, NotebookExporter.hasImages(notebook) {
            textOnlyCandidate = notebook
        } else {
            start(format, notebook)
        }
    }

    private func start(_ format: NotebookExportFormat, _ notebook: Notebook) {
        guard let book = model.book else { return }
        export.start(format, notebook: notebook, book: book, store: environment.store)
    }

    @ViewBuilder
    private var exportProgress: some View {
        if case .running(let format, let fraction) = export.state {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                NotebookExportProgressView(format: format, fraction: fraction, cancel: export.cancel)
            }
        }
    }

    private var exportFailed: Binding<Bool> {
        Binding(get: { if case .failed = export.state { true } else { false } },
                set: { if !$0 { export.dismissError() } })
    }
}

/// Opening the reader from the Notebook in another window.
@MainActor
enum NotebookNavigation {
    /// Opens a new reader window on the book at `pageIndex` (the shell applies the page once,
    /// when the window is created; the book's stored last-read page is left alone).
    static func openInNewWindow(bookID: UUID, pageIndex: Int, notesTab: ReaderSession.NotesTab? = nil,
                                notesHeading: HeadingAnchor? = nil, hideNotesPanel: Bool = false,
                                store: LibraryStore, window: WindowContext) {
        window.openReaderInNewWindow(bookID: bookID, pageIndex: pageIndex, notesTab: notesTab,
                                     notesHeading: notesHeading, hideNotesPanel: hideNotesPanel)
    }
}

private extension View {
    /// The book title under "Notebook". iPadOS 26+: the system subtitle. Earlier: a two-line
    /// principal toolbar item. The only availability check of the Notebook screen.
    @ViewBuilder
    func notebookSubtitle(_ subtitle: String, title: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title).font(.headline).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Reports which feed rows are on screen, for the map's box. iPadOS 18 and later only; earlier
/// systems leave `ids` empty and the box follows the top row (`scrollAnchor`). The only
/// availability check of the map.
private struct NotebookVisibleRows: ViewModifier {
    @Binding var ids: Set<String>

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollTargetVisibilityChange(idType: String.self, threshold: 0.3) { visible in
                let set = Set(visible)
                if set != ids { ids = set }
            }
        } else {
            content
        }
    }
}
