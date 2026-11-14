import ReaderCore
import SwiftUI

/// The Notebook of one book: every note and highlight laid out along the book's outline, with
/// a heading filter column, a type filter, search, and export (design: "Notebook · all notes by
/// heading").
///
/// Shown in place in any window (pushed on the window's navigation stack, so the system back
/// button returns to the Library) and as the first screen of a Notebook window
/// (`WindowID.notebook`, keyed by book ID). Filter, search and scroll position belong to the
/// window (scene storage keyed by book), so two windows on one Notebook are independent.
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
    @State private var entries: [NotebookScopeEntry] = []
    @State private var feedVersion = 0
    @State private var didRestoreScroll = false
    @State private var isWide = true
    @State private var export = NotebookExportController()

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
        .navigationTitle("Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .notebookSubtitle(model.book?.title ?? "")
        .searchable(text: $query, prompt: "Search Notes and Highlights")
        .toolbar { toolbar }
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
            entries = []
            return
        }
        let computed = await Self.compute(notebook, filter: filter)
        guard !Task.isCancelled else { return }
        if computed.entries.contains(where: { $0.scope == filter.scope }) || filter.scope == .all {
            rows = computed.rows
        } else {
            // The chosen heading has no content any more (deleted from another window).
            scopeKey = NotebookScope.all.storageKey
            return
        }
        entries = computed.entries
        feedVersion += 1
    }

    @concurrent
    private static func compute(_ notebook: Notebook, filter: NotebookFilter) async
        -> (rows: [NotebookFeedRow], entries: [NotebookScopeEntry]) {
        (NotebookFeed.rows(for: notebook, filter: filter), NotebookFeed.scopeEntries(for: notebook))
    }

    @ViewBuilder
    private var feedColumn: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $typeKey) {
                ForEach(NotebookTypeFilter.allCases, id: \.self) { type in
                    Text(type.title).tag(type.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isWide ? 36 : 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 780 + 72)
            .accessibilityIdentifier(NotebookAccessibilityID.typeFilter)

            ZStack {
                feed
                emptyState
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        NotebookRowView(row: row, model: model, actions: rowActions)
                            .id(row.id)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, isWide ? 36 : 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $scrollAnchor, anchor: .top)
            .accessibilityIdentifier(NotebookAccessibilityID.feed)
            .onChange(of: feedVersion) { _, _ in
                if !didRestoreScroll {
                    didRestoreScroll = true
                    if let anchor = scrollAnchor, rows.contains(where: { $0.id == anchor }) {
                        proxy.scrollTo(anchor, anchor: .top)
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
                        Text("Notes and highlights you make in this book appear here, laid out along its contents.")
                    } actions: {
                        Button("Open Book") { window.openReader(bookID: model.bookID) }
                            .buttonStyle(.borderedProminent)
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
            open: { page in window.openReader(bookID: bookID, pageIndex: page) },
            openInNewWindow: { page in
                NotebookNavigation.openInNewWindow(bookID: bookID, pageIndex: page, store: store, window: window)
            })
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
            }
            Button {
                window.openReader(bookID: model.bookID)
            } label: {
                Label("Open Book", systemImage: "book")
            }
            .disabled(model.phase != .ready)
            .accessibilityIdentifier(NotebookAccessibilityID.openBook)
            Menu {
                ForEach(NotebookExportFormat.allCases) { format in
                    Button(format.title, systemImage: format == .markdown ? "doc.plaintext" : "doc.richtext") {
                        startExport(format)
                    }
                    .accessibilityIdentifier(format == .markdown ? NotebookAccessibilityID.exportMarkdown
                                                                 : NotebookAccessibilityID.exportPDF)
                }
            } label: {
                if isWide {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                } else {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(model.notebook == nil || export.state != .idle)
            .accessibilityIdentifier(NotebookAccessibilityID.exportMenu)
        }
    }

    private func startExport(_ format: NotebookExportFormat) {
        guard let notebook = model.notebook, let book = model.book else { return }
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
    /// Opens a new reader window on the book at `pageIndex`.
    ///
    /// The shell's `openReaderInNewWindow(bookID:)` takes no page, and a new reader window starts
    /// at the book's stored last-read page (it has no restored state). So the page is stored as
    /// the last-read page first, then the window is opened. This is the one place to change when
    /// the shell gains `openReaderInNewWindow(bookID:pageIndex:)`.
    static func openInNewWindow(bookID: UUID, pageIndex: Int, store: LibraryStore, window: WindowContext) {
        if var book = try? store.books.book(id: bookID),
           PageNumbering.isValid(pageIndex, pageCount: book.pageCount), book.lastReadPageIndex != pageIndex {
            book.lastReadPageIndex = pageIndex
            try? store.books.save(book)
        }
        window.openReaderInNewWindow(bookID: bookID)
    }
}

private extension View {
    /// The book title under "Notebook". iPadOS 26+: the system subtitle. Earlier: a two-line
    /// principal toolbar item. The only availability check of the Notebook screen.
    @ViewBuilder
    func notebookSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Notebook").font(.headline).lineLimit(1)
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
