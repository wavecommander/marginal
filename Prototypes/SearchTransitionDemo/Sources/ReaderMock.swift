import SwiftUI

/// The Reader's bars as the app has them: Contents and section history leading, title and
/// place in the middle, and search, bookmark, Markup, notes and More trailing in one group.
struct ReaderMock: View {
    let variant: Variant
    let zoomNamespace: Namespace.ID
    let openNotebook: () -> Void

    @State private var isMarkup = false
    @State private var isNotesShown = false

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground).ignoresSafeArea()
            page
        }
        .navigationTitle("Middlemarch")
        .navigationSubtitle("Chapter 3 · Page 42")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { leading; trailing }
    }

    private var page: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<14, id: \.self) { line in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 9)
                        .frame(maxWidth: line % 5 == 4 ? 220 : .infinity, alignment: .leading)
                }
            }
            .padding(36)
            .frame(maxWidth: 520)
            .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 4))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)

            Button("Open Notebook", systemImage: "book.pages", action: openNotebook)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("or More › Notebook, as in the app")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }

    @ToolbarContentBuilder
    private var leading: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Show Contents", systemImage: "sidebar.leading") {}
            Button("Back in Section History", systemImage: "arrow.backward") {}
            Button("Forward in Section History", systemImage: "arrow.forward") {}.disabled(true)
        }
    }

    @ToolbarContentBuilder
    private var trailing: some ToolbarContent {
        switch variant {
        case .ownCapsule:
            ToolbarItem(placement: .topBarTrailing) { searchButton }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItemGroup(placement: .topBarTrailing) { rest; moreMenu }
        case .plainReaderSearch:
            ToolbarItem(placement: .topBarTrailing) { searchButton }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) { rest; moreMenu }
        case .zoom:
            ToolbarItemGroup(placement: .topBarTrailing) { searchButton; rest }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
                .matchedTransitionSource(id: ZoomSource.more, in: zoomNamespace)
        case .current, .minimize, .drawer, .inContent:
            ToolbarItemGroup(placement: .topBarTrailing) { searchButton; rest; moreMenu }
        }
    }

    private var searchButton: some View {
        Button("Search Book and Notes", systemImage: "magnifyingglass") {}
    }

    @ViewBuilder
    private var rest: some View {
        Button("Add Bookmark", systemImage: "bookmark") {}
        Toggle(isOn: $isMarkup) {
            Label(isMarkup ? "Done with Markup" : "Markup",
                  systemImage: isMarkup ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
        .toggleStyle(.button)
        Button(isNotesShown ? "Hide Notes" : "Show Notes", systemImage: "note.text") {
            isNotesShown.toggle()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Notebook", systemImage: "book.pages", action: openNotebook)
            Button("Notebook in New Window", systemImage: "macwindow.badge.plus") {}
            Divider()
            Button("Export Marked-Up PDF", systemImage: "square.and.arrow.up") {}
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}
