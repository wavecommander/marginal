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

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let origin = ChangeOrigin(label: "library window")
    @ObservationIgnored private var observation: StoreChangeObservation?
    @ObservationIgnored private var continueBookID: UUID?

    init(store: LibraryStore) {
        self.store = store
        reload()
        observation = store.hub.observe { [weak self] event in self?.handle(event) }
    }

    func reload() {
        books = (try? store.books.allBooks()) ?? []
        continueBookID = LibraryLogic.continueReading(books)?.id
        recountContinueBook()
    }

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .bookSaved, .bookDeleted:
            reload()
        case .noteSaved(let id, _, _), .noteRemoved(let id, _, _), .highlightsChanged(let id, _):
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

    /// IDs of books with a note or a highlight whose text contains `query`. Reads one book at a
    /// time and yields between books, so typing stays responsive; stops early if cancelled.
    func bookIDsWithAnnotations(matching query: String) async -> Set<UUID> {
        var matches: Set<UUID> = []
        for book in books {
            if Task.isCancelled { break }
            let notes = (try? store.notes.notes(bookID: book.id)) ?? []
            if LibraryLogic.anyText(notes.lazy.map(\.text), contains: query) {
                matches.insert(book.id)
            } else {
                let highlights = (try? store.highlights.highlights(bookID: book.id)) ?? []
                if LibraryLogic.anyText(highlights.lazy.map(\.text), contains: query) { matches.insert(book.id) }
            }
            await Task.yield()
        }
        return matches
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
