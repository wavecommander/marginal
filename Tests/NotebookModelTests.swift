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
