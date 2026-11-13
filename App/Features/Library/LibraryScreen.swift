import SwiftUI

/// Placeholder Library screen: an empty state only. WP3 replaces it.
struct LibraryScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No books yet", systemImage: "books.vertical")
            } description: {
                Text("Import a PDF to start reading and taking notes.")
            } actions: {
                Button("Import PDF") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityIdentifier("library.importButton")
            }
            .navigationTitle("Library")
        }
    }
}

#Preview {
    LibraryScreen()
}
