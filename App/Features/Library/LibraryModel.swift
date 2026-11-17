import Foundation
import Observation
import ReaderCore

/// The live book list of one Library window. Reads through `LibraryStore` and refreshes when the
/// hub reports a book saved or deleted (no polling), so every Library window shows the same
/// list, including books imported or renamed from another window.
@Observable
@MainActor
final class LibraryModel {
    private(set) var books: [Book] = []
    /// Notes plus highlights of the "Continue reading" book.
    private(set) var continueAnnotationCount = 0
    /// Books whose PDF is not on disk (restored without it, or the file went missing): their
    /// covers carry "PDF missing" and opening them offers Locate PDF…. Checked off the main
    /// thread whenever the list reloads (a book saved, linked or deleted).
    private(set) var booksMissingPDF: Set<UUID> = []
    /// Increases whenever a note or highlight of any book is saved or removed, from any window,
    /// so an open search recounts its matches.
    private(set) var annotationsVersion = 0

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let origin = ChangeOrigin(label: "library window")
    @ObservationIgnored private var observation: StoreChangeObservation?
    @ObservationIgnored private var continueBookID: UUID?
    @ObservationIgnored private var documentCheck: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
        reload()
        observation = store.hub.observe { [weak self] event in self?.handle(event) }
    }

    func reload() {
        books = (try? store.books.allBooks()) ?? []
        continueBookID = LibraryLogic.continueReading(books)?.id
        recountContinueBook()
        refreshMissingDocuments()
    }

    /// Whether `book` lacks its PDF (as of the last check).
    func isMissingPDF(_ book: Book) -> Bool { booksMissingPDF.contains(book.id) }

    private func refreshMissingDocuments() {
        documentCheck?.cancel()
        let books = books
        let store = store
        documentCheck = Task { [weak self] in
            let missing = await Self.booksWithoutDocument(books, store: store)
            guard !Task.isCancelled, let self, self.booksMissingPDF != missing else { return }
            self.booksMissingPDF = missing
        }
    }

    @concurrent
    nonisolated private static func booksWithoutDocument(_ books: [Book], store: LibraryStore) async -> Set<UUID> {
        Set(books.filter { !store.hasDocument($0) }.map(\.id))
    }

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .bookSaved, .bookDeleted:
            reload()
        case .noteSaved(let id, _, _), .noteRemoved(let id, _, _), .highlightsChanged(let id, _):
            annotationsVersion += 1
            if id == continueBookID { recountContinueBook() }
        default:
            break
        }
    }

    private func recountContinueBook() {
        guard let id = continueBookID else { continueAnnotationCount = 0; return }
        let notes = (try? store.notes.noteCount(bookID: id)) ?? 0
        let highlights = (try? store.highlights.highlightCount(bookID: id)) ?? 0
        continueAnnotationCount = notes + highlights
    }

    /// For each book with a note or highlight whose text contains `query`, how many do
    /// (`LibraryLogic.matchCount`, which matches as the Notebook's search does). Reads one book
    /// at a time and yields between books, so typing stays responsive; stops early if cancelled.
    func annotationMatchCounts(matching query: String) async -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for book in books {
            if Task.isCancelled { break }
            let notes = (try? store.notes.notes(bookID: book.id)) ?? []
            let highlights = (try? store.highlights.highlights(bookID: book.id)) ?? []
            let count = LibraryLogic.matchCount(notes.lazy.map(\.text), query: query)
                + LibraryLogic.matchCount(highlights.lazy.map(\.text), query: query)
            if count > 0 { counts[book.id] = count }
            await Task.yield()
        }
        return counts
    }

    /// Renames the book (the title only; the file keeps its name). Blank titles are ignored.
    func rename(_ book: Book, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != book.title,
              var stored = try store.books.book(id: book.id) else { return }
        stored.title = trimmed
        try store.perform(as: origin) { try store.books.save(stored) }
    }
}
