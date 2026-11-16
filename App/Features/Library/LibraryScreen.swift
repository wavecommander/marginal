import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// The Library: the root of every window's navigation stack. Continue-reading card, an
/// adaptive grid of covers, search, sort, import (Files picker, drops, "Open in", progress and
/// cancel), and per-book actions. Layout follows the window's own size and size class.
///
/// Environment it relies on: `AppEnvironment` (store, import service) and `WindowContext`
/// (navigation, other windows, the "Import…" menu command).
struct LibraryScreen: View {
    @Environment(\.accentTheme) private var accentTheme
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
    /// What the one file importer is for (a single `.fileImporter`: SwiftUI may honour only one
    /// document picker per view).
    @State private var importerMode = ImporterMode.importDocuments
    /// A book without its PDF the reader tried to open: offers Locate PDF… and the Notebook.
    @State private var missingPrompt: Book?
    @State private var linker = PDFLinker()

    init() {}

    private enum ImporterMode: Equatable {
        case importDocuments
        case locatePDF(Book)
        case restoreBackup

        var contentTypes: [UTType] {
            switch self {
            case .importDocuments: ImportContentTypes.acceptable
            case .locatePDF(let book): PDFLinker.contentTypes(for: book)
            case .restoreBackup: [.tactileTextsBackup]
            }
        }
    }

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
        .task { await considerWelcome() }
        .sheet(isPresented: welcomeBinding) {
            WelcomeSheet(openGuide: {
                environment.onboarding.dismissWelcome()
                openQuickGuide()
            }, notNow: { environment.onboarding.dismissWelcome() })
        }
        .task(id: query) { await updateNoteMatches() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importerMode.contentTypes,
                      allowsMultipleSelection: importerMode == .importDocuments) { result in
            importerCompleted(result)
        }
        .onChange(of: window.importRequestCount) { presentImporter(.importDocuments) }
        .onDrop(of: ImportContentTypes.acceptable, isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(item: conversionBinding) { request in
            ConversionSheet(request: request,
                            onConvert: { options in convert(request, options: options) },
                            onCancel: { cancel(request) })
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accentTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
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
        .alert(missingPrompt.map { MissingPDFText.promptTitle($0.title) } ?? "",
               isPresented: missingPromptBinding, presenting: missingPrompt) { book in
            Button(MissingPDFText.locateTitle) {
                // After the alert has gone: the picker can't present while it is dismissing.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    presentImporter(.locatePDF(book))
                }
            }
            Button("Open Notebook") { window.openNotebook(bookID: book.id) }
            Button("Cancel", role: .cancel) {}
        } message: { book in
            Text(MissingPDFText.promptMessage(for: book))
        }
        .alert(linker.failure?.title ?? "", isPresented: linkFailureBinding, presenting: linker.failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
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
        let backupJob = environment.backupService.job
        if all.isEmpty && service.jobs.isEmpty && backupJob == nil {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !service.jobs.isEmpty || backupJob != nil {
                        VStack(spacing: 10) {
                            if let backupJob { LibraryBackupProgressRow(job: backupJob) }
                            ForEach(service.jobs) { ImportProgressRow(job: $0) }
                        }
                    }
                    if !isSearching, let book = LibraryLogic.continueReading(all) {
                        ContinueReadingCard(book: book, annotationCount: model.continueAnnotationCount,
                                            isMissingPDF: model.isMissingPDF(book),
                                            onResume: { open(book) },
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
                // On the title, not the whole view: a container's identifier replaces its
                // buttons' own ones.
                .accessibilityIdentifier("library.emptyState")
        } description: {
            Text("Import a book or document to start reading and taking notes. You can also drop files here from Files or another app, or restore your books from a backup.",
                 comment: "Library empty state: description under 'No Books Yet'.")
        } actions: {
            ViewThatFits {
                HStack(spacing: Space.m) { emptyImportButton; emptyGuideButton; emptyRestoreButton }
                VStack(spacing: Space.m) { emptyImportButton; emptyGuideButton; emptyRestoreButton }
            }
        }
    }

    private var emptyGuideButton: some View {
        Button("Open the Quick Guide", systemImage: "book.pages") { openQuickGuide() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.Onboarding.emptyLibraryOpenGuide)
    }

    private var emptyImportButton: some View {
        Button {
            presentImporter(.importDocuments)
        } label: {
            Text("Import", comment: "Library empty state: button that opens the Files picker.")
        }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(accentTheme.onAccent)
            .accessibilityIdentifier("library.emptyImportButton")
    }

    /// A fresh install is exactly when a reader wants this.
    private var emptyRestoreButton: some View {
        Button {
            presentImporter(.restoreBackup)
        } label: {
            Text("Restore from Backup…", comment: "Library empty state: button that opens the Files picker to choose a backup to restore.")
        }
            .buttonStyle(.bordered)
            .disabled(environment.backupService.isBusy)
            .accessibilityIdentifier(AccessibilityID.Library.emptyRestoreButton)
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
        let isMissing = model?.isMissingPDF(book) ?? false
        return Button {
            open(book)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(0.77, contentMode: .fit)
                    .overlay { BookCoverView(book: book, isMissingPDF: isMissing) }
                    .bookCoverStyle()
                    .overlay(alignment: .bottomLeading) {
                        if isMissing {
                            PDFMissingBadge()
                                .padding(Space.s)
                                .accessibilityIdentifier(AccessibilityID.Library.pdfMissing(book.title))
                        }
                    }
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
        .hoverEffect(.lift)
        .accessibilityLabel(MissingPDFText.cellAccessibilityLabel(LibraryLogic.accessibilityLabel(book), isMissing: isMissing))
        .accessibilityIdentifier(AccessibilityID.Library.book(book.title))
        .contextMenu { menu(for: book) }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        if model?.isMissingPDF(book) == true {
            Button(MissingPDFText.locateTitle, systemImage: "doc.badge.plus") { presentImporter(.locatePDF(book)) }
            Divider()
        }
        Button("Open", systemImage: "book") { open(book) }
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
        ConvertedFromMenuSection(book: book, identifier: AccessibilityID.Provenance.libraryMenu)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                window.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.openButton)
        }
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
                presentImporter(.importDocuments)
            } label: {
                toolbarLabel(String(localized: "Import", comment: "Library toolbar: button that opens the Files picker to import books and documents."),
                             systemImage: "plus")
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

    // MARK: Onboarding

    /// The first Library on screen after launch decides whether the welcome sheet shows
    /// (`OnboardingCoordinator.considerWelcome`). Waits for launch work, and a moment longer so
    /// a PDF arriving through "Open in" is seen first.
    private func considerWelcome() async {
        _ = await environment.launchPlan()
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, window.path.isEmpty else { return }
        let books = (try? environment.store.books.allBooks()) ?? []
        environment.onboarding.considerWelcome(in: windowKey, libraryIsEmpty: books.isEmpty && service.jobs.isEmpty)
    }

    private func openQuickGuide() {
        let window = window
        let environment = environment
        Task { await environment.onboarding.openQuickGuide(environment: environment, window: window) }
    }

    private var welcomeBinding: Binding<Bool> {
        Binding(get: { environment.onboarding.welcomeWindow == windowKey },
                set: { if !$0 { environment.onboarding.dismissWelcome() } })
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

    // MARK: Opening and the file importer

    /// Opens the book in place, or, when its PDF is missing, offers Locate PDF… and the Notebook.
    private func open(_ book: Book) {
        if model?.isMissingPDF(book) == true {
            missingPrompt = book
        } else {
            window.openReader(bookID: book.id)
        }
    }

    private func presentImporter(_ mode: ImporterMode) {
        importerMode = mode
        showImporter = true
    }

    private func importerCompleted(_ result: Result<[URL], any Error>) {
        let mode = importerMode
        importerMode = .importDocuments
        switch (mode, result) {
        case (.importDocuments, .success(let urls)):
            startImport(urls, consumeSources: false)
        case (.locatePDF(let book), .success):
            linker.importerCompleted(result, book: book, environment: environment) { linked in
                window.openReader(bookID: linked.id)
            }
        case (.restoreBackup, .success(let urls)):
            if let url = urls.first { window.openRestore(RestoreRequest(source: .file(url, consume: false))) }
        case (_, .failure(let error)):
            if !BackupFailure.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Import

    /// One batch from the Files picker or a drop. Files that need converting show the Convert to
    /// PDF sheet in this window; failures not listed there are alerts.
    private func startImport(_ urls: [URL], consumeSources: Bool) {
        guard !urls.isEmpty else { return }
        let key = windowKey
        let window = window
        let environment = environment
        Task {
            let service = await environment.readyImportService()
            let results = await service.importFiles(urls, consumeSources: consumeSources, requester: key)
            service.present(results.compactMap(\.alertError), in: key)
            // One file that is already in the Library: show that book.
            if results.count == 1, case .success(.existing(let book)) = results[0].result {
                window.openReader(bookID: book.id)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = DropImport.acceptedProviders(providers)
        guard !accepted.isEmpty else { return false }
        let staging = service.stagingRoot
        Task {
            // The whole drop is one batch, so one sheet covers it.
            let adopted = await DropImport.adopt(accepted, into: staging)
            startImport(adopted, consumeSources: true)
        }
        return true
    }

    // MARK: Convert to PDF

    /// The request this window shows. Dismissing the sheet by a swipe sets it to `nil`, which
    /// counts as Cancel.
    private var conversionBinding: Binding<ConversionRequest?> {
        Binding(get: { service.conversionRequest(for: windowKey) },
                set: { newValue in
                    if newValue == nil, let request = service.conversionRequest(for: windowKey) { cancel(request) }
                })
    }

    private func convert(_ request: ConversionRequest, options: ConversionOptions) {
        let key = windowKey
        let window = window
        let service = service
        Task {
            let results = await service.convert(request.id, options: options)
            service.present(results.compactMap(\.alertError), in: key)
            if request.opensBookWhenDone, results.count == 1, let book = results[0].book {
                window.openReader(bookID: book.id)
            }
        }
    }

    private func cancel(_ request: ConversionRequest) {
        let service = service
        Task { await service.discard(request.id) }
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
                ReaderScrollDirectionStore().removeDirection(for: book.id)
                ReaderNotesPanelStore().removeValue(for: book.id)
                ReaderPositionStore().removePosition(for: book.id)
            } catch LibraryStoreError.bookFilesNotRemoved {
                ReaderScrollDirectionStore().removeDirection(for: book.id)
                ReaderNotesPanelStore().removeValue(for: book.id)
                ReaderPositionStore().removePosition(for: book.id)
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
        // Held back while this window shows a Convert to PDF sheet (an alert cannot be presented
        // over it); it appears once the sheet closes.
        Binding(get: { service.failure(for: windowKey) != nil && service.conversionRequest(for: windowKey) == nil },
                set: { if !$0, let failure = service.failure(for: windowKey) { service.dismissFailure(failure.id) } })
    }

    private var missingPromptBinding: Binding<Bool> {
        Binding(get: { missingPrompt != nil }, set: { if !$0 { missingPrompt = nil } })
    }

    private var linkFailureBinding: Binding<Bool> {
        Binding(get: { linker.failure != nil }, set: { if !$0 { linker.failure = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
