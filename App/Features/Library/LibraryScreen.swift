import ReaderCore
import SwiftUI

/// PLACEHOLDER owned by WP3 (Library and import). Keep the type name and `init()`; replace the
/// body. Minimal list of imported books so a book can be opened in place or in a new window.
///
/// Environment it can rely on: `AppEnvironment` (store), `WindowContext` (open a reader or a
/// Notebook in place or in a new window; `importRequestCount` for "Import PDF…").
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @State private var books: [Book] = []
    @State private var hubToken: StoreChangeObservation?

    init() {}

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView {
                    Label("No books yet", systemImage: "books.vertical")
                } description: {
                    Text("Import a PDF to start reading and taking notes.")
                } actions: {
                    Button("Import PDF") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .accessibilityIdentifier(AccessibilityID.Library.importButton)
                }
            } else {
                List(books) { book in
                    Button {
                        window.openReader(bookID: book.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(book.title).font(.headline)
                            Text("\(book.pageCount) pages · \(Int(book.progress * 100))%")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Library.book(book.title))
                    .contextMenu {
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                            window.openReaderInNewWindow(bookID: book.id)
                        }
                        Button("Notebook", systemImage: "book.pages") { window.openNotebook(bookID: book.id) }
                        Button("Open Notebook in New Window", systemImage: "rectangle.stack.badge.plus") {
                            window.openNotebookInNewWindow(bookID: book.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .onAppear {
            reload()
            if hubToken == nil {
                hubToken = environment.store.hub.observe { event in
                    switch event.change {
                    case .bookSaved, .bookDeleted: reload()
                    default: break
                    }
                }
            }
        }
    }

    private func reload() {
        books = ((try? environment.store.books.allBooks()) ?? [])
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }
}
