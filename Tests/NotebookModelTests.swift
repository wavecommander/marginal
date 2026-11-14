import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// Helpers for the WP9 Notebook tests.
@MainActor
enum NotebookTestSupport {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var smallPDF: URL { repoRoot.appendingPathComponent("Fixtures/out/small.pdf") }
    static var goldenDirectory: URL { repoRoot.appendingPathComponent("Tests/Fixtures/Notebook", isDirectory: true) }

    /// An ephemeral store with one book. Remove `store.rootDirectory` when done.
    static func makeStore(title: String = "no-outline", pageCount: Int = 40) throws -> (LibraryStore, Book) {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: title, fingerprint: "notebook-test-\(UUID().uuidString)", fileName: "book.pdf",
                        pageCount: pageCount, fileSize: 1)
        try store.books.save(book)
        return (store, book)
    }

    /// A started model with no PDF outline (user headings only) and a short debounce.
    static func startedModel(_ store: LibraryStore, _ book: Book,
                             entries: @escaping @Sendable (URL) async -> [RawOutlineEntry] = { _ in [] }) async -> NotebookModel {
        let model = NotebookModel(store: store, bookID: book.id, rebuildDelay: .milliseconds(20), outlineEntries: entries)
        await model.start()
        return model
    }

    /// The debug seed's book, built.
    static func seeded() async throws -> (LibraryStore, Book, NotebookModel) {
        let (store, book) = try makeStore()
        try await NotebookDebugSeed.seed(store: store, book: book)
        let model = await startedModel(store, book)
        return (store, book, model)
    }

    static func cleanUp(_ store: LibraryStore) {
        try? FileManager.default.removeItem(at: store.rootDirectory)
    }

    static func titles(_ rows: [NotebookFeedRow]) -> [String] {
        rows.compactMap { if case .header(let header) = $0.kind { header.title } else { nil } }
    }
}

/// `NotebookModel`: building from the store and the PDF outline, staying live, anchor repairs,
/// deleted books.
@MainActor
struct NotebookModelTests {
    typealias Support = NotebookTestSupport

    @Test func buildsAlongThePDFOutline() async throws {
        let (store, book) = try Support.makeStore(title: "small", pageCount: 12)
        defer { Support.cleanUp(store) }
        // small.pdf: "1 Linear Systems" p1, "1.1 Foundations" p2, "1.2 Exercises" p4, "2 Vector Spaces" p5, …
        _ = try store.notes.save(Note(bookID: book.id, target: .page(2), text: "Under 1.1"))
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 5, rects: [], color: .green, text: "Under 2.1"))
        let model = await Support.startedModel(store, book) { _ in
            await ReaderDocumentLoader.outlineEntries(at: Support.smallPDF)
        }
        let notebook = try #require(model.notebook)
        #expect(model.phase == .ready)
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        #expect(Support.titles(rows) == ["1 Linear Systems", "1.1 Foundations", "2 Vector Spaces", "2.1 Foundations"])
        let noteIndex = try #require(rows.firstIndex { $0.note?.text == "Under 1.1" })
        let headerIndex = try #require(rows.firstIndex { Support.titles([$0]) == ["1.1 Foundations"] })
        #expect(noteIndex == headerIndex + 1)
    }

    @Test func rebuildsWhenAnotherWindowChangesTheBook() async throws {
        let (store, book, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let before = model.buildCount
        let otherWindow = ChangeOrigin(label: "reader window")
        try store.perform(as: otherWindow) {
            _ = try store.notes.save(Note(bookID: book.id, target: .page(32), text: "Late note"))
        }
        #expect(await NotePageTestSupport.waitUntil { model.buildCount > before })
        let notebook = try #require(model.notebook)
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        #expect(Support.titles(rows).contains("6 Orthogonality"))
        #expect(rows.contains { $0.note?.text == "Late note" })

        // Highlights and user headings too.
        let afterNote = model.buildCount
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 33, rects: [], color: .pink, text: "Pink"))
        #expect(await NotePageTestSupport.waitUntil { model.buildCount > afterNote })
        let afterHighlight = model.buildCount
        try store.headings.save(UserHeading(bookID: book.id, title: "6.1 Projections", pageIndex: 32, parent: nil))
        #expect(await NotePageTestSupport.waitUntil { model.buildCount > afterHighlight })
        #expect(Support.titles(NotebookFeed.rows(for: try #require(model.notebook), filter: NotebookFilter()))
            .contains("6.1 Projections"))
    }

    @Test func ignoresOtherBooksAndTracksNoteInk() async throws {
        let (store, book, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let other = Book(title: "Other", fingerprint: "other-\(UUID())", fileName: "o.pdf", pageCount: 5, fileSize: 1)
        try store.books.save(other)
        let before = model.buildCount
        _ = try store.notes.save(Note(bookID: other.id, target: .page(1), text: "Elsewhere"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.buildCount == before)

        let inked = try #require(model.notebook.flatMap { NotebookFeed.rows(for: $0, filter: NotebookFilter()) }
            .flatMap { $0.compactMap(\.note).first(where: \.hasInk) })
        try await store.saveNoteInk(Data([1, 2, 3]), bookID: book.id, noteID: inked.id, origin: nil)
        #expect(model.inkVersions[inked.id] == 1)
    }

    @Test func bookDeletedFromAnyWindowMakesTheNotebookMissing() async throws {
        let (store, book, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        #expect(model.phase == .ready)
        try await store.deleteBook(id: book.id, origin: ChangeOrigin(label: "library"))
        #expect(model.phase == .missing)
        #expect(model.notebook == nil)

        let missing = NotebookModel(store: store, bookID: UUID(), outlineEntries: { _ in [] })
        await missing.start()
        #expect(missing.phase == .missing)
    }

    @Test func appliesAnchorRepairsOnce() async throws {
        let (store, book) = try Support.makeStore(title: "small", pageCount: 12)
        defer { Support.cleanUp(store) }
        // A heading note stored against a stale anchor (wrong outline path) for "2 Vector Spaces".
        let stale = HeadingAnchor(pdfPath: [7], pageIndex: 4, title: "2 Vector Spaces")
        let note = try #require(try store.notes.save(Note(bookID: book.id, target: .heading(stale), text: "Chapter 2")))
        let model = await Support.startedModel(store, book) { _ in
            await ReaderDocumentLoader.outlineEntries(at: Support.smallPDF)
        }
        let notebook = try #require(model.notebook)
        let section = try #require(notebook.sections.first { $0.title == "2 Vector Spaces" })
        #expect(section.note?.id == note.id)
        let stored = try #require(try store.notes.note(id: note.id))
        #expect(stored.target == .heading(section.anchor))
        #expect(stored.target != .heading(stale))
        // The repair is the model's own change: no rebuild loop.
        let builds = model.buildCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.buildCount == builds)
    }

    @Test func snapshotsLoadInkAndAreCached() async throws {
        let (store, _, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let inked = try #require(model.notebook.flatMap { NotebookFeed.rows(for: $0, filter: NotebookFilter()) }
            .flatMap { $0.compactMap(\.note).first(where: \.hasInk) })
        let snapshot = try #require(await model.snapshot(for: inked))
        #expect(snapshot.hasInk)
        #expect(snapshot.drawing.strokes.count == 6)
        #expect(snapshot.text == NotebookDebugSeed.inkedNoteText)
    }
}

/// `NotebookFeed`: grouping, type filter, search, scopes and filter-column entries.
@MainActor
struct NotebookFeedTests {
    typealias Support = NotebookTestSupport

    @Test func groupsUnderTheRightHeadings() async throws {
        let (store, _, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        #expect(Support.titles(rows) == ["Front matter", "3 Matrices and Linear Maps", "4 Determinants",
                                        "5 Eigenvalues and Eigenvectors", "5.1 Invariant Directions",
                                        "5.2 The Characteristic Equation"])
        // Under 5.2: its own note, then pages in order, each page's note before its highlights.
        let start = try #require(rows.firstIndex { Support.titles([$0]) == ["5.2 The Characteristic Equation"] })
        let kinds = rows[(start + 1)...].map { row -> String in
            switch row.kind {
            case .headingNote: "section"
            case .pageNote(_, let page): "note p\(page + 1)"
            case .highlight(let highlight, _): "\(highlight.color.rawValue) p\(highlight.pageIndex + 1)"
            default: "other"
            }
        }
        #expect(kinds == ["section", "note p23", "note p25", "yellow p25", "green p25", "note p28", "blue p29"])
        #expect(rows.first(where: { $0.note?.hasInk == true })?.targetPage == 24)
        // Bookmarks are not shown.
        #expect(!rows.contains { $0.targetPage == 19 })
    }

    @Test func typeFilterAndSearchNarrowTheFeed() async throws {
        let (store, _, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        let highlights = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .highlights))
        #expect(highlights.filter { !$0.isHeader }.count == 6)
        #expect(highlights.allSatisfy { if case .highlight = $0.kind { true } else { $0.isHeader } })
        #expect(!Support.titles(highlights).contains("Front matter"))

        let sectionNotes = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .sectionNotes))
        #expect(sectionNotes.filter { !$0.isHeader }.count == 3)
        let pageNotes = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .pageNotes))
        #expect(pageNotes.filter { !$0.isHeader }.count == 7)

        // Case- and diacritic-insensitive search over notes and highlights.
        let search = NotebookFeed.rows(for: notebook, filter: NotebookFilter(query: "  DETERMINANT "))
        let matches = search.filter { !$0.isHeader }
        #expect(matches.count == 3)
        #expect(Support.titles(search) == ["4 Determinants", "5 Eigenvalues and Eigenvectors",
                                          "5.2 The Characteristic Equation"])
        #expect(NotebookFeed.rows(for: notebook, filter: NotebookFilter(query: "zzz-nothing")).isEmpty)
        let combined = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .highlights, query: "eigenvalue"))
        #expect(combined.filter { !$0.isHeader }.count == 3)
    }

    @Test func scopesAndFilterEntries() async throws {
        let (store, _, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        let entries = NotebookFeed.scopeEntries(for: notebook)
        #expect(entries.map(\.title) == ["Whole book", "Front matter", "3 Matrices and Linear Maps", "4 Determinants",
                                         "5 Eigenvalues and Eigenvectors", "5.1 Invariant Directions",
                                         "5.2 The Characteristic Equation"])
        #expect(entries.map(\.count) == [16, 1, 2, 2, 11, 3, 7])
        #expect(entries.map(\.level) == [1, 1, 1, 1, 1, 2, 2])

        let s51 = try #require(entries.first { $0.title == "5.1 Invariant Directions" })
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: s51.scope))
        #expect(Support.titles(rows) == ["5.1 Invariant Directions"])
        #expect(rows.count == 4)
        let chapter = try #require(entries.first { $0.title == "5 Eigenvalues and Eigenvectors" })
        #expect(Support.titles(NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: chapter.scope)))
            == ["5 Eigenvalues and Eigenvectors", "5.1 Invariant Directions", "5.2 The Characteristic Equation"])
        let front = NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: .frontMatter))
        #expect(front.count == 2)
        #expect(front.last?.targetPage == 0)

        for entry in entries {
            #expect(NotebookScope(storageKey: entry.scope.storageKey) == entry.scope)
        }
    }

    @Test func unfiledNotesAreKept() throws {
        let bookID = UUID()
        let gone = HeadingAnchor(pdfPath: [3], pageIndex: 9, title: "Removed Heading")
        let notes = [Note(bookID: bookID, target: .heading(gone), text: "Orphan"),
                     Note(bookID: bookID, target: .page(99), text: "Off the end")]
        let notebook = NotebookBuilder.build(outline: Outline(pdfEntries: [], pageCount: 10), notes: notes, highlights: [])
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        #expect(Support.titles(rows) == ["Unfiled notes"])
        #expect(rows.count == 3)
        #expect(NotebookFeed.scopeEntries(for: notebook).last?.count == 2)
        if case .unfiledHeadingNote(_, let title) = rows[1].kind {
            #expect(title == "Removed Heading")
        } else {
            Issue.record("expected an unfiled heading note")
        }
    }
}
