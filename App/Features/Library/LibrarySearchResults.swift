import ReaderCore
import SwiftUI

/// The Notebooks Library search reads its results from: one live `NotebookModel` per book that
/// has matched since the search began, so typing more letters re-filters trees already built
/// instead of loading each book's outline again. `stopAll()` when the search ends lets them go.
@Observable
@MainActor
final class LibrarySearchNotebooks {
    private(set) var models: [UUID: NotebookModel] = [:]
    @ObservationIgnored private let store: LibraryStore

    init(store: LibraryStore) { self.store = store }

    /// Starts a Notebook model for each book that has none yet.
    func prepare(_ bookIDs: [UUID]) {
        for id in bookIDs where models[id] == nil {
            let model = NotebookModel(store: store, bookID: id)
            models[id] = model
            Task { await model.start() }
        }
    }

    func stopAll() {
        for model in models.values { model.stop() }
        models = [:]
    }
}

/// One line of the results column: a book's header, a Notebook row of that book (a heading or a
/// matching note or highlight), or a book whose Notebook is still loading.
nonisolated enum LibrarySearchRow: Identifiable, Hashable, Sendable {
    case book(UUID)
    case loading(UUID)
    case item(UUID, NotebookFeedRow)

    var id: String {
        switch self {
        case .book(let id): "book:" + id.uuidString
        case .loading(let id): "loading:" + id.uuidString
        case .item(let id, let row): id.uuidString + "/" + row.id
        }
    }

    /// The rows for `books` in order: each book's header, then its Notebook filtered by `query`
    /// (`NotebookFeed.rows`, the Notebook's own search), or `.loading` until its tree is built.
    static func rows(books: [(id: UUID, notebook: Notebook?)], query: String) -> [LibrarySearchRow] {
        let filter = NotebookFilter(query: query)
        return books.flatMap { book -> [LibrarySearchRow] in
            guard let notebook = book.notebook else { return [.book(book.id), .loading(book.id)] }
            return [.book(book.id)] + NotebookFeed.rows(for: notebook, filter: filter).map { .item(book.id, $0) }
        }
    }
}

/// Library search when notes or highlights match (design: "Library search"). Wide windows: a
/// column of the books with matches (with "All Books" first, and the books whose title matches
/// below) beside the matches themselves, laid out as in each book's Notebook. Narrow windows:
/// the matches alone, with the title matches above them.
struct LibrarySearchResultsView: View {
    struct BookCount: Identifiable, Equatable {
        let book: Book
        let count: Int
        var id: UUID { book.id }
    }

    let notebooks: LibrarySearchNotebooks
    /// Books with matching notes or highlights, in the order shown (`LibraryLogic.searchResultOrder`).
    let books: [BookCount]
    /// Books whose title matches.
    let titleMatches: [Book]
    let query: String
    let isMissingPDF: (Book) -> Bool
    let openBook: (Book) -> Void
    let openAt: (Book, Int, ReaderSession.NotesTab?, HeadingAnchor?) -> Void
    let openInNewWindow: (Book, Int, ReaderSession.NotesTab?, HeadingAnchor?) -> Void
    let openNotebook: (Book) -> Void
    var onDeleteNote: ((DeletedNoteSnapshot) -> Void)? = nil

    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The book chosen in the column (`nil`: all books).
    @State private var selectedBookID: UUID?
    @State private var rows: [LibrarySearchRow] = []
    @State private var isWide = true
    @State private var deleteCandidate: (bookID: UUID, note: Note)?

    /// Below this width (or in a compact size class) the book column is left out, as the
    /// Notebook's heading column is.
    static let wideThreshold: CGFloat = 760

    private struct FeedInput: Equatable {
        let query: String
        let bookIDs: [UUID]
        let builds: [Int]
    }

    /// The books the results column shows: the chosen one, or all.
    private var shownBooks: [BookCount] {
        guard isWide, let selectedBookID, let chosen = books.first(where: { $0.id == selectedBookID }) else { return books }
        return [chosen]
    }

    private var totalCount: Int { books.reduce(0) { $0 + $1.count } }

    var body: some View {
        let shown = shownBooks
        let input = FeedInput(query: query, bookIDs: shown.map(\.id),
                              builds: shown.map { notebooks.models[$0.id]?.buildCount ?? -1 })
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if isWide {
                    bookColumn.frame(width: 300)
                }
                resultsColumn
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                let wide = sizeClass != .compact && width >= Self.wideThreshold
                if wide != isWide { isWide = wide }
            }
        }
        .onChange(of: books.map(\.id), initial: true) { _, ids in
            notebooks.prepare(ids)
            if let selectedBookID, !ids.contains(selectedBookID) { self.selectedBookID = nil }
        }
        .task(id: input) { await recompute(shown) }
        .alert("Delete This Note?", isPresented: Binding(get: { deleteCandidate != nil },
                                                         set: { if !$0 { deleteCandidate = nil } }),
               presenting: deleteCandidate) { candidate in
            Button("Delete", role: .destructive) {
                if let model = notebooks.models[candidate.bookID] {
                    Task {
                        let result = await model.deleteNoteResult(candidate.note)
                        if result.deleted, let snapshot = result.snapshot {
                            onDeleteNote?(snapshot)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text(NotesPanel.deleteMessage(hasInk: candidate.note.hasInk))
        }
        .accessibilityIdentifier(AccessibilityID.Library.searchResults)
    }

    private func recompute(_ shown: [BookCount]) async {
        let input = shown.map { (id: $0.id, notebook: notebooks.models[$0.id]?.notebook) }
        let query = query
        let computed = await Self.compute(input, query: query)
        guard !Task.isCancelled else { return }
        rows = computed
    }

    @concurrent
    private static func compute(_ books: [(id: UUID, notebook: Notebook?)], query: String) async -> [LibrarySearchRow] {
        LibrarySearchRow.rows(books: books, query: query)
    }

    // MARK: Book column

    private var columnSelection: Binding<String?> {
        Binding(get: { selectedBookID?.uuidString ?? Self.allBooksTag },
                set: { selectedBookID = $0.flatMap(UUID.init(uuidString:)) })
    }

    private static let allBooksTag = "all"

    private var bookColumn: some View {
        List(selection: columnSelection) {
            Section(LibraryLogic.matchesText(totalCount) + " in " + LibraryLogic.booksText(books.count)) {
                HStack(spacing: 10) {
                    Label("All Books", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    countText(totalCount)
                }
                .tag(Self.allBooksTag)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("All Books")
                .accessibilityValue(LibraryLogic.matchesText(totalCount))
                .accessibilityIdentifier(AccessibilityID.Library.searchAllBooks)
                ForEach(books) { entry in
                    HStack(spacing: 10) {
                        smallCover(entry.book, width: 22, height: 30)
                        Text(entry.book.title)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        countText(entry.count)
                    }
                    .tag(entry.id.uuidString)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(entry.book.title)
                    .accessibilityValue(LibraryLogic.matchesText(entry.count))
                    .accessibilityIdentifier(AccessibilityID.Library.searchBook(entry.book.title))
                }
            }
            if !titleMatches.isEmpty {
                Section("Title Matches") {
                    ForEach(titleMatches) { book in titleRow(book) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .clipped()
        .accessibilityIdentifier(AccessibilityID.Library.searchBookColumn)
    }

    private func countText(_ count: Int) -> some View {
        Text(count.formatted(.number))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func smallCover(_ book: Book, width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay { BookCoverView(book: book, isMissingPDF: isMissingPDF(book)) }
            .bookCoverStyle(cornerRadius: 3)
            .accessibilityHidden(true)
    }

    /// A book whose title matches: tapping opens it, as its cover does.
    private func titleRow(_ book: Book) -> some View {
        Button { openBook(book) } label: {
            HStack(spacing: 10) {
                smallCover(book, width: 22, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title).lineLimit(2).foregroundStyle(.primary)
                    Text(LibraryLogic.detailLine(book)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the book")
        .accessibilityIdentifier(AccessibilityID.Library.searchTitle(book.title))
    }

    // MARK: Results column

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: isWide ? 20 : 0)
    }

    private var panelColor: Color { Color(.secondarySystemGroupedBackground) }

    /// The results scroll inside their panel (nothing passes under the toolbar), and each
    /// book's header stays pinned at the panel's top while that book's rows pass beneath it.
    private var resultsColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if !isWide, !titleMatches.isEmpty { narrowTitleMatches }
                ForEach(groups, id: \.bookID) { group in
                    Section {
                        ForEach(group.rows) { row in rowView(row) }
                        Color.clear.frame(height: 20)
                    } header: {
                        if let entry = books.first(where: { $0.id == group.bookID }) {
                            bookHeader(entry)
                                .background(panelColor)
                                .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, isWide ? 36 : 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.Library.searchFeed)
        .background(panelColor)
        .clipShape(panelShape)
        .ignoresSafeArea(edges: .bottom)
    }

    /// `rows` split per book (for pinned headers): each book's rows after its `.book` marker.
    private var groups: [(bookID: UUID, rows: [LibrarySearchRow])] {
        var result: [(bookID: UUID, rows: [LibrarySearchRow])] = []
        for row in rows {
            if case .book(let id) = row {
                result.append((id, []))
            } else if !result.isEmpty {
                result[result.count - 1].rows.append(row)
            }
        }
        return result
    }

    @ViewBuilder
    private func rowView(_ row: LibrarySearchRow) -> some View {
        switch row {
        case .book:
            EmptyView()  // Drawn as its section's pinned header (`resultsColumn`).
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
        case .item(let id, let feedRow):
            if let model = notebooks.models[id], let entry = books.first(where: { $0.id == id }) {
                NotebookRowView(row: feedRow, model: model, actions: actions(for: entry.book))
            }
        }
    }

    private func bookHeader(_ entry: BookCount) -> some View {
        HStack(spacing: 12) {
            smallCover(entry.book, width: 30, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.book.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(LibraryLogic.matchesText(entry.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AccessibilityID.Library.searchHeader(entry.book.title))
            Button("Open Notebook") { openNotebook(entry.book) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentTheme.accent)
                .buttonStyle(.borderless)
                .accessibilityLabel("Open Notebook for \(entry.book.title)")
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Narrow windows have no book column, so the books whose title matches lead the results.
    private var narrowTitleMatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title Matches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(titleMatches) { book in titleRow(book) }
        }
        .padding(.top, 12)
    }

    private func actions(for book: Book) -> NotebookRowActions {
        NotebookRowActions(
            open: { page, notesTab, heading in openAt(book, page, notesTab, heading) },
            openInNewWindow: { page, notesTab, heading in openInNewWindow(book, page, notesTab, heading) },
            deleteNote: { note in deleteCandidate = (book.id, note) })
    }
}

