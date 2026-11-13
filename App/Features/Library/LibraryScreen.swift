import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// The Library (WP3): the root of every window's navigation stack. Continue-reading card, an
/// adaptive grid of covers, search, sort, import (Files picker, drops, "Open in", progress and
/// cancel), and per-book actions. Layout follows the window's own size and size class.
///
/// Environment it relies on: `AppEnvironment` (store, import service) and `WindowContext`
/// (navigation, other windows, the "Import PDF…" menu command).
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @Environment(\.horizontalSizeClass) private var sizeClass

    @AppStorage(LibrarySort.storageKey) private var sortRaw = LibrarySort.recentlyOpened.rawValue
    @State private var model: LibraryModel?
    @State private var query = ""
    @State private var noteMatches: Set<UUID> = []
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var renameTarget: Book?
    @State private var renameText = ""
    @State private var deletePrompt: DeletePrompt?
    @State private var errorMessage: String?

    init() {}

    private struct DeletePrompt: Identifiable {
        let book: Book
        let message: String
        var id: UUID { book.id }
    }

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recentlyOpened }
    private var service: ImportService { environment.importService }
    private var windowKey: ObjectIdentifier { ObjectIdentifier(window) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            if let model {
                content(model)
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search titles and notes")
        .toolbar { toolbar }
        .onAppear { if model == nil { model = LibraryModel(store: environment.store) } }
        .task(id: query) { await updateNoteMatches() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): startImport(urls, consumeSources: false)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onChange(of: window.importRequestCount) { showImporter = true }
        .onDrop(of: [.pdf], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onContinueUserActivity(LibraryActivity.openBookType) { activity in
            if let id = LibraryActivity.bookID(from: activity) { window.openReader(bookID: id) }
        }
        .alert("Rename Book", isPresented: renameBinding, presenting: renameTarget) { book in
            TextField("Title", text: $renameText)
                .accessibilityIdentifier("library.rename.field")
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename(book) }
        }
        .alert(deletePrompt.map { "Delete “\($0.book.title)”?" } ?? "Delete Book?",
               isPresented: deleteBinding, presenting: deletePrompt) { prompt in
            Button("Delete", role: .destructive) { delete(prompt.book) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(service.failure(for: windowKey)?.error.alertTitle ?? "Couldn't Import",
               isPresented: failureBinding, presenting: service.failure(for: windowKey)) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.error.errorDescription ?? "")
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ model: LibraryModel) -> some View {
        let all = model.books
        let visible = LibraryLogic.sorted(LibraryLogic.filtered(all, query: query, noteMatches: noteMatches), by: sort)
        if all.isEmpty && service.jobs.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !service.jobs.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(service.jobs) { ImportProgressRow(job: $0) }
                        }
                    }
                    if !isSearching, let book = LibraryLogic.continueReading(all) {
                        ContinueReadingCard(book: book, annotationCount: model.continueAnnotationCount,
                                            onResume: { window.openReader(bookID: book.id) },
                                            onNotebook: { window.openNotebook(bookID: book.id) })
                    }
                    if visible.isEmpty && isSearching {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                    } else if !visible.isEmpty {
                        Text(isSearching ? "Results" : "All books")
                            .font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 4)
                        grid(visible)
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 32 : 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Books Yet", systemImage: "books.vertical")
        } description: {
            Text("Import a PDF to start reading and taking notes. You can also drop PDFs here from Files or another app.")
        } actions: {
            Button("Import PDF") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library.emptyImportButton")
        }
        .accessibilityIdentifier("library.emptyState")
    }

    private func grid(_ books: [Book]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 24, alignment: .top)],
                  alignment: .leading, spacing: 24) {
            ForEach(books) { book in
                cell(for: book)
            }
        }
    }

    private func cell(for book: Book) -> some View {
        Button {
            window.openReader(bookID: book.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(0.77, contentMode: .fit)
                    .overlay { BookCoverView(book: book) }
                    .bookCoverStyle()
                    .onDrag { LibraryActivity.itemProvider(bookID: book.id, title: book.title) }
                    .padding(.bottom, 4)
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(LibraryLogic.detailLine(book))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: LibraryLogic.progressFraction(book))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LibraryLogic.accessibilityLabel(book))
        .accessibilityIdentifier(AccessibilityID.Library.book(book.title))
        .contextMenu { menu(for: book) }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button("Open", systemImage: "book") { window.openReader(bookID: book.id) }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
            window.openReaderInNewWindow(bookID: book.id)
        }
        Divider()
        Button("Open Notebook", systemImage: "book.pages") { window.openNotebook(bookID: book.id) }
        Button("Open Notebook in New Window", systemImage: "rectangle.stack.badge.plus") {
            window.openNotebookInNewWindow(bookID: book.id)
        }
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renameText = book.title
            renameTarget = book
        }
        Button("Delete…", systemImage: "trash", role: .destructive) { prepareDelete(book) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option.rawValue)
                    }
                }
            } label: {
                toolbarLabel(sort.label, systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort by \(sort.label)")
            .accessibilityIdentifier("library.sortMenu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showImporter = true
            } label: {
                toolbarLabel("Import PDF", systemImage: "plus")
            }
            .fontWeight(.semibold)
            .accessibilityIdentifier(AccessibilityID.Library.importButton)
        }
    }

    /// Title and icon in wide windows, icon only in compact ones.
    @ViewBuilder
    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        if sizeClass == .regular {
            Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
        } else {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
    }

    // MARK: Search

    private func updateNoteMatches() async {
        guard isSearching, let model else {
            noteMatches = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))  // debounce; cancelled by the next keystroke
        guard !Task.isCancelled else { return }
        let matches = await model.bookIDsWithAnnotations(matching: query)
        if !Task.isCancelled { noteMatches = matches }
    }

    // MARK: Import

    private func startImport(_ urls: [URL], consumeSources: Bool) {
        guard !urls.isEmpty else { return }
        let key = windowKey
        let window = window
        let environment = environment
        Task {
            let service = await environment.readyImportService()
            let results = await service.importFiles(urls, consumeSources: consumeSources)
            service.present(results.compactMap(\.error), in: key)
            // One file that is already in the Library: show that book.
            if results.count == 1, case .success(.existing(let book)) = results[0].result {
                window.openReader(bookID: book.id)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let pdfProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        guard !pdfProviders.isEmpty else { return false }
        let staging = service.stagingRoot
        for provider in pdfProviders {
            let name = provider.suggestedName
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                // The system deletes `url` when this returns: take it now.
                guard let url, let adopted = try? ImportPipeline.adoptDroppedFile(url, suggestedName: name, into: staging)
                else { return }
                Task { @MainActor in startImport([adopted], consumeSources: true) }
            }
        }
        return true
    }

    // MARK: Rename and delete

    private func commitRename(_ book: Book) {
        do { try model?.rename(book, to: renameText) } catch { errorMessage = "Couldn't rename the book: \(error)" }
        renameTarget = nil
    }

    private func prepareDelete(_ book: Book) {
        Task {
            do {
                let summary = try await environment.store.deletionSummary(bookID: book.id)
                deletePrompt = DeletePrompt(book: book, message: LibraryLogic.deletionMessage(title: book.title, summary: summary))
            } catch {
                errorMessage = "Couldn't look up what deleting “\(book.title)” removes: \(error)"
            }
        }
    }

    private func delete(_ book: Book) {
        let store = environment.store
        let origin = model?.origin
        Task {
            do {
                try await store.deleteBook(id: book.id, origin: origin)
            } catch LibraryStoreError.bookFilesNotRemoved {
                // The book is gone; its leftover files are removed by the next launch's sweep.
            } catch {
                errorMessage = "Couldn't delete “\(book.title)”: \(error)"
            }
        }
    }

    // MARK: Alert bindings

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deletePrompt != nil }, set: { if !$0 { deletePrompt = nil } })
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { service.failure(for: windowKey) != nil },
                set: { if !$0, let failure = service.failure(for: windowKey) { service.dismissFailure(failure.id) } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
