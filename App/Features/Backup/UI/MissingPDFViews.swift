import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Linking a PDF

/// Links a chosen PDF to a book that lacks it (`ImportService.linkPDF(at:to:)`) and reports a
/// wrong file in an alert ("Wrong PDF", nothing changes). Shared by the Library, the reader's
/// "Cannot Open Book" state and the restore summary.
@Observable
@MainActor
final class PDFLinker {
    struct Failure: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private(set) var linkingBookIDs: Set<UUID> = []
    var failure: Failure?

    /// Links the file at `url` to `book`; `onLinked` runs once the PDF is in place.
    func link(_ url: URL, to book: Book, environment: AppEnvironment, onLinked: @escaping (Book) -> Void) {
        linkingBookIDs.insert(book.id)
        Task {
            defer { linkingBookIDs.remove(book.id) }
            do {
                let service = await environment.readyImportService()
                let linked = try await service.linkPDF(at: url, to: book)
                onLinked(linked)
            } catch {
                guard !BackupFailure.isCancellation(error) else { return }
                let title = (error as? ImportError)?.alertTitle ?? "Couldn’t Link the PDF"
                failure = Failure(title: title, message: error.localizedDescription)
            }
        }
    }

    func importerCompleted(_ result: Result<[URL], any Error>, book: Book, environment: AppEnvironment,
                           onLinked: @escaping (Book) -> Void) {
        switch result {
        case .success(let urls):
            if let url = urls.first { link(url, to: book, environment: environment, onLinked: onLinked) }
        case .failure(let error):
            guard !BackupFailure.isCancellation(error) else { return }
            failure = Failure(title: "Couldn’t Open the File", message: error.localizedDescription)
        }
    }

    /// What the picker offers for `book`: its PDF, and for a converted book also the kinds of
    /// file it can have been made from (`ImportService.linkPDF` converts that file again).
    nonisolated static func contentTypes(for book: Book) -> [UTType] {
        book.isConverted ? [.pdf] + ImportContentTypes.importable.filter { $0 != .pdf } : [.pdf]
    }
}

/// "Locate PDF…" for one view: set `target` to a book to show the PDF picker for it. A view
/// that already has a `.fileImporter` (the Library) uses `PDFLinker` with its own importer instead.
private struct LocatePDFModifier: ViewModifier {
    @Binding var target: Book?
    let onLinked: (Book) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var linker = PDFLinker()
    @State private var pending: Book?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: pending.map(PDFLinker.contentTypes(for:)) ?? [.pdf], allowsMultipleSelection: false) { result in
                guard let book = pending else { return }
                pending = nil
                linker.importerCompleted(result, book: book, environment: environment, onLinked: onLinked)
            }
            .onChange(of: target?.id) { _, id in
                guard id != nil, let book = target else { return }
                pending = book
                target = nil
                isPresented = true
            }
            .alert(linker.failure?.title ?? "", isPresented: failureBinding, presenting: linker.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { linker.failure != nil }, set: { if !$0 { linker.failure = nil } })
    }
}

extension View {
    /// Presents the PDF picker for `target` (then clears it) and links the chosen file.
    func locatePDF(for target: Binding<Book?>, onLinked: @escaping (Book) -> Void = { _ in }) -> some View {
        modifier(LocatePDFModifier(target: target, onLinked: onLinked))
    }
}

// MARK: - Library badge

/// The badge on the cover of a book whose PDF is not on this iPad.
struct PDFMissingBadge: View {
    var body: some View {
        Label(MissingPDFText.badge, systemImage: "exclamationmark.triangle.fill")
            .font(Typeface.meta)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MissingPDFText.badge)
    }
}

// MARK: - Reader

/// The reader's "Cannot Open Book" state. When the book's PDF is missing it says so and offers
/// "Locate PDF…" and the Notebook; once the PDF is linked (here or from any window) the reader
/// reopens the book in place.
struct ReaderUnavailableView: View {
    let book: Book
    let message: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @Environment(\.accentTheme) private var accentTheme
    @State private var isMissing: Bool?
    @State private var locateTarget: Book?
    @State private var observation: StoreChangeObservation?

    var body: some View {
        ContentUnavailableView {
            Label("Cannot Open Book", systemImage: "exclamationmark.triangle")
        } description: {
            Text(isMissing == true ? MissingPDFText.readerMessage(for: book) : message)
        } actions: {
            if isMissing == true {
                Button(MissingPDFText.locateTitle) { locateTarget = book }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(accentTheme.onAccent)
                    .accessibilityIdentifier(AccessibilityID.Reader.locatePDF)
                Button("Open Notebook") { window.openNotebook(bookID: book.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.Reader.missingPDFNotebook)
            }
        }
        .locatePDF(for: $locateTarget) { _ in reopen() }
        .task(id: book.id) {
            isMissing = await !Self.documentExists(book, store: environment.store)
            observation = environment.store.hub.observe { event in
                guard case .bookSaved(let id) = event.change, id == book.id else { return }
                if environment.store.hasDocument(book) { reopen() }
            }
        }
        .onDisappear { observation = nil }
    }

    private func reopen() {
        observation = nil
        window.reloadReader(bookID: book.id)
    }

    @concurrent
    nonisolated private static func documentExists(_ book: Book, store: LibraryStore) async -> Bool {
        store.hasDocument(book)
    }
}
