import Observation
import ReaderCore
import SwiftUI

/// Runs one marked-up PDF export at a time for one reader window (`ReaderSession.markedUpExport`)
/// and hands the file to the share sheet; removes it when the share sheet is done with it. Before
/// reading, it saves everything pending in every open editor on the store (this window's ink and
/// notes, and any other window's), so the export holds what is on screen.
@Observable
@MainActor
final class MarkedUpExportController {
    enum State: Equatable {
        case idle
        case running(includesNotes: Bool, fraction: Double)
        /// Waiting for the share sheet to finish with the file.
        case sharing(NotebookExportResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }
    var isIdle: Bool { state == .idle }

    var sharedResult: NotebookExportResult? {
        if case .sharing(let result) = state { result } else { nil }
    }

    func start(book: Book, store: LibraryStore, includeNotes: Bool) {
        guard state == .idle else { return }
        state = .running(includesNotes: includeNotes, fraction: 0)
        task = Task { [weak self] in
            await OpenEditorRegistry.shared.flushAll(store: store)
            await NotebookExporter.purgeStale(root: MarkedUpExporter.defaultRoot)
            do {
                try Task.checkCancellation()
                let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: includeNotes,
                                                               progress: { fraction in
                    guard let self, case .running(let notes, _) = self.state else { return }
                    self.state = .running(includesNotes: notes, fraction: fraction)
                })
                guard let self else {
                    NotebookExporter.cleanUp(result)
                    return
                }
                if Task.isCancelled {
                    NotebookExporter.cleanUp(result)
                    self.state = .idle
                } else {
                    self.state = .sharing(result)
                }
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops a running export (its files are removed) or lets go of a file waiting to be shared.
    func cancel() {
        task?.cancel()
        if let result = sharedResult {
            NotebookExporter.cleanUp(result)
            state = .idle
        }
    }

    /// The share sheet was dismissed (shared or not): remove the file.
    func shareDidFinish() {
        if let result = sharedResult { NotebookExporter.cleanUp(result) }
        state = .idle
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }
}

// MARK: - Commands

/// The two ways to export, offered by the reader's More menu and the menu bar's Book menu.
nonisolated enum MarkedUpExportChoice: CaseIterable, Identifiable, Sendable {
    /// The book with its ink and highlights.
    case bookOnly
    /// The same, with the notes appended.
    case withNotes

    var id: Self { self }
    var includesNotes: Bool { self == .withNotes }

    var title: String {
        switch self {
        case .bookOnly: "Book Only"
        case .withNotes: "Book with Notes"
        }
    }

    var subtitle: String {
        switch self {
        case .bookOnly: "Ink and highlights drawn on the pages"
        case .withNotes: "Your notes added at the end"
        }
    }

    var systemImage: String {
        switch self {
        case .bookOnly: "doc.richtext"
        case .withNotes: "doc.on.doc"
        }
    }

    var accessibilityID: String {
        switch self {
        case .bookOnly: AccessibilityID.MarkedUpExport.bookOnly
        case .withNotes: AccessibilityID.MarkedUpExport.withNotes
        }
    }
}

extension ReaderSession {
    /// The command's title (More menu, menu bar).
    static let markedUpExportTitle = "Export Marked-Up PDF"

    /// Whether this window can export now: the book is open and no export of this window is
    /// running or waiting for the share sheet.
    var canExportMarkedUpPDF: Bool {
        loadState == .ready && closeReason == nil && markedUpExport.isIdle
    }

    /// Whether `choice` is offered: "Book with Notes" only when the book has notes (or before the
    /// reader knows).
    func isMarkedUpExportAvailable(_ choice: MarkedUpExportChoice) -> Bool {
        guard canExportMarkedUpPDF else { return false }
        guard choice.includesNotes, let notebook else { return true }
        return notebook.totalCounts.notes > 0
    }

    /// Exports this book as a marked-up PDF and offers it in the share sheet.
    func exportMarkedUpPDF(_ choice: MarkedUpExportChoice) {
        guard isMarkedUpExportAvailable(choice) else { return }
        markedUpExport.start(book: book, store: store, includeNotes: choice.includesNotes)
    }
}

/// The "Export Marked-Up PDF" submenu: one item per choice, each with what it holds.
struct MarkedUpExportMenu: View {
    let session: ReaderSession

    var body: some View {
        Menu {
            ForEach(MarkedUpExportChoice.allCases) { choice in
                Button { session.exportMarkedUpPDF(choice) } label: {
                    Label(choice.title, systemImage: choice.systemImage)
                    Text(choice.subtitle)
                }
                .disabled(!session.isMarkedUpExportAvailable(choice))
                .accessibilityIdentifier(choice.accessibilityID)
            }
        } label: {
            Label(ReaderSession.markedUpExportTitle, systemImage: "square.and.arrow.up")
        }
        .disabled(!session.canExportMarkedUpPDF)
        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.menu)
    }
}

// MARK: - Presentation

extension View {
    /// The marked-up export's progress card (with Cancel), its share sheet (a popover from the
    /// toolbar's trailing end) and its failure alert, for the reader of `session`.
    func markedUpExportPresentation(_ session: ReaderSession) -> some View {
        modifier(MarkedUpExportPresentation(export: session.markedUpExport))
    }
}

private struct MarkedUpExportPresentation: ViewModifier {
    let export: MarkedUpExportController

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                NotebookShareSheetAnchor(item: export.sharedResult?.fileURL, onFinish: export.shareDidFinish)
                    .frame(width: 1, height: 1)
                    .padding(.trailing, 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay { progress }
            .alert("Export Failed", isPresented: failed) {
                Button("OK") { export.dismissError() }
            } message: {
                if case .failed(let message) = export.state { Text(message) }
            }
    }

    @ViewBuilder
    private var progress: some View {
        if case .running(let includesNotes, let fraction) = export.state {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(includesNotes ? "Exporting Book with Notes…" : "Exporting Marked-Up PDF…").font(.headline)
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.progress)
                    Button("Cancel", role: .cancel) { export.cancel() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.cancel)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var failed: Binding<Bool> {
        Binding(get: { if case .failed = export.state { true } else { false } },
                set: { if !$0 { export.dismissError() } })
    }
}
