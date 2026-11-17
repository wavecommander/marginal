import SwiftUI

/// The Notebook's bars as the app has them: "Notebook" and the book's title in the middle,
/// Open Book, Select and Export trailing, and search placed as the variant says. The content
/// is a heading column and a feed of notes, like the wide layout.
struct NotebookMock: View {
    let variant: Variant
    let openBook: () -> Void

    @State private var query = ""
    @State private var scope: Int? = 0

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $scope) {
                ForEach(Sample.headings.indices, id: \.self) { index in
                    Text(Sample.headings[index]).tag(index)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 280)
            Divider().ignoresSafeArea(edges: .bottom)
            feed
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Notebook")
        .navigationSubtitle("Middlemarch")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SearchPlacement(variant: variant, query: $query))
        .toolbar { toolbar }
    }

    private var feed: some View {
        List {
            ForEach(Sample.notes.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) },
                    id: \.self) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Page \(abs(note.hashValue % 300) + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(note)
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            if variant == .inContent {
                ContentSearchField(text: $query)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .systemBackground))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if variant == .ownCapsule {
            DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Open Book", systemImage: "book", action: openBook)
            Button("Select") {}
            Menu {
                Button("Markdown") {}
                Button("PDF") {}
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
        }
    }
}

/// Where the Notebook's search goes, per variant.
private struct SearchPlacement: ViewModifier {
    let variant: Variant
    @Binding var query: String

    func body(content: Content) -> some View {
        let prompt = Text("Search Notes and Highlights")
        switch variant {
        case .current, .plainReaderSearch, .zoom:
            content.searchable(text: $query, prompt: prompt)
        case .minimize, .ownCapsule:
            content.searchable(text: $query, prompt: prompt).searchToolbarBehavior(.minimize)
        case .drawer:
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        case .inContent:
            content
        }
    }
}

/// A plain search field that lives in the view, not the bar, so it moves with the push.
private struct ContentSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Notes and Highlights", text: $text)
                .focused($isFocused)
                .submitLabel(.search)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
    }
}

private enum Sample {
    static let headings = [
        "Whole book", "Prelude", "Book I: Miss Brooke", "Chapter 1", "Chapter 2", "Chapter 3",
        "Book II: Old and Young", "Chapter 12", "Chapter 15", "Book III: Waiting for Death",
    ]

    static let notes = [
        "Dorothea's longing for a life of consequence: compare to the Prelude's Saint Theresa.",
        "Highlight: \"the growing good of the world is partly dependent on unhistoric acts\"",
        "Casaubon's Key to All Mythologies, the first hint that it will never be finished.",
        "Celia and the jewels: quick, funny, and it sets up the sisters' difference.",
        "Lydgate arrives. Note the narrator's long aside on his ambitions.",
        "Fred Vincy's debt, and how it pulls in the Garths.",
        "Rosamond at the piano: performance as character.",
        "Mr Brooke's politics: comic, but the Reform Bill is the backdrop.",
        "Will Ladislaw in Rome, sketching. The first meeting with Dorothea since the wedding.",
        "Bulstrode's piety and what it hides; reread after Book VII.",
        "Mary Garth refuses to take the will money: the moral centre of the Featherstone plot.",
        "The web metaphor again: \"how human lots are woven and interwoven\"",
    ]
}
