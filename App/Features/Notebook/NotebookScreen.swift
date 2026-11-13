import ReaderCore
import SwiftUI

/// PLACEHOLDER owned by WP9 (Notebook). Keep the type name and `init(bookID:)`; replace the body.
///
/// Shown in place in any window (pushed on the window's navigation stack, so the system back
/// button returns) and as the first screen of a Notebook window. Read the store from
/// `@Environment(AppEnvironment.self)`; navigate with `@Environment(WindowContext.self)`:
/// `window.openReader(bookID:pageIndex:)` opens the reader in this window at a page,
/// `window.openReaderInNewWindow(bookID:)` in another window.
struct NotebookScreen: View {
    let bookID: UUID
    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window

    init(bookID: UUID) {
        self.bookID = bookID
    }

    var body: some View {
        let book = try? environment.store.books.book(id: bookID)
        ContentUnavailableView {
            Label("Notebook", systemImage: "book.pages")
        } description: {
            Text("Notebook placeholder (WP9) for \(book?.title ?? "a deleted book").")
        } actions: {
            Button("Open Book") { window.openReader(bookID: bookID) }
        }
        .navigationTitle(book.map { "\($0.title) Notebook" } ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(AccessibilityID.Placeholder.notebook)
    }
}
