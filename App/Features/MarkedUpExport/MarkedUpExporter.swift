import Foundation
import PencilKit
import ReaderCore
import UIKit

/// Why a marked-up export could not be made (shown in the "Export Failed" alert).
nonisolated enum MarkedUpExportError: LocalizedError, Equatable {
    case missingPDF
    case unreadablePDF
    case lockedPDF
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .missingPDF: "This book’s PDF is missing. Locate it from the Library, then export again."
        case .unreadablePDF: "This book’s PDF could not be read."
        case .lockedPDF: "This book’s PDF is protected with a password, so it cannot be exported."
        case .writeFailed: "The PDF could not be written. There may not be enough free space on this iPad."
        }
    }
}

/// Exports a book as a new PDF with the reader's markup drawn in (design: "Export" ▸ Marked-up
/// PDF): every page of the book (`MarkedUpPDFFile`), its highlights and page ink in place, and
/// optionally the book's notes as an appendix after the last page, drawn by the Notebook's PDF
/// writer (`NotebookPDFWriter`) so they look as they do there. The imported PDF is only read.
///
/// **What it reads**, once, when the export starts (the caller saves pending edits first):
/// the PDF's outline and the reader's headings (the merged outline, as Contents shows it), the
/// highlights, the list of pages with ink, and with the appendix the notes. Each page's ink is
/// read when its page is written and let go after it, so memory does not grow with the book.
///
/// **Outline.** The book's outline (PDF and reader headings, `MarkedUpExport.bookOutline`), then,
/// with the appendix, a "Notes" entry holding the headings that have notes, each opening the
/// appendix page its notes start on (`MarkedUpExport.appendixOutline`).
///
/// **Threading, progress, cancellation, cleanup** as the Notebook's exports: book pages are
/// copied off the main thread, ink and notes are drawn on the main actor, one page or note at a
/// time with a yield after each. `progress` gets fractions in `0...1`. Cancelling the calling
/// task stops after the current page and removes everything written (`CancellationError`).
/// Every export writes into its own directory under `root`; `NotebookExporter.cleanUp` removes
/// it, and `NotebookExporter.purgeStale(root:)` removes leftovers.
@MainActor
enum MarkedUpExporter {
    /// `<tmp>/MarkedUpExports`.
    nonisolated static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MarkedUpExports", isDirectory: true)
    }

    /// Writes the export.
    /// - Parameters:
    ///   - includeNotes: add the book's notes as an appendix (none is added when it has no notes).
    ///   - outlineEntries: how to flatten the PDF's outline (default: the reader's loader).
    static func export(book: Book, store: LibraryStore, includeNotes: Bool, root: URL = defaultRoot,
                       outlineEntries: (@Sendable (URL) async -> [RawOutlineEntry])? = nil,
                       progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> NotebookExportResult {
        guard store.hasDocument(book) else { throw MarkedUpExportError.missingPDF }
        let source = store.documentURL(for: book)
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = work.appendingPathComponent(MarkedUpExport.fileName(forBookTitle: book.title, includesNotes: includeNotes))
        var file: MarkedUpPDFFile?
        do {
            try await createDirectory(work)
            let created: MarkedUpPDFFile
            do {
                created = try await MarkedUpPDFFile.create(source: source, destination: fileURL, title: book.title,
                                                           defaultPageSize: NotebookPDFWriter.defaultPageSize)
            } catch MarkedUpPDFFile.Failure.locked {
                throw MarkedUpExportError.lockedPDF
            } catch MarkedUpPDFFile.Failure.unreadable {
                throw MarkedUpExportError.unreadablePDF
            } catch {
                throw MarkedUpExportError.writeFailed
            }
            file = created
            let pageCount = created.pageCount

            // What the export shows, read once.
            let entries = await (outlineEntries ?? { url in await ReaderDocumentLoader.outlineEntries(at: url) })(source)
            let userHeadings = (try? store.headings.userHeadings(bookID: book.id)) ?? []
            let outline = await ReaderDocumentLoader.buildOutline(entries: entries, userHeadings: userHeadings,
                                                                  pageCount: pageCount)
            let highlights = Dictionary(grouping: try store.highlights.highlights(bookID: book.id), by: \.pageIndex)
            let inkedPages = Set(try await store.inkedPageIndices(bookID: book.id))
            var appendix: Notebook?
            if includeNotes {
                let notes = try store.notes.notes(bookID: book.id)
                if !notes.isEmpty {
                    appendix = await ReaderDocumentLoader.buildNotebook(outline: outline, notes: notes, highlights: [],
                                                                        bookmarks: [])
                }
            }
            try Task.checkCancellation()

            let total = Double(pageCount + (appendix?.totalCounts.items ?? 0) + 1)
            let memoryWarnings = MemoryWarningFlag()
            for pageIndex in 0..<pageCount {
                if memoryWarnings.take() { created.reopenBeforeNextPage() }
                let geometry = await created.beginBookPage(pageIndex, highlights: highlights[pageIndex] ?? [])
                if let geometry, inkedPages.contains(pageIndex),
                   let data = try? await store.pageInk(bookID: book.id, pageIndex: pageIndex) {
                    autoreleasepool {
                        guard let drawing = try? PKDrawing(data: data) else { return }
                        PageInkRenderer.draw(drawing, geometry: geometry, in: created.context, target: geometry.bounds)
                    }
                }
                created.endPage()
                progress(min(0.99, Double(pageIndex + 1) / total))
                try Task.checkCancellation()
                await Task.yield()
            }

            var appendixOutline: ExportOutlineItem?
            if let appendix {
                appendixOutline = try await writeAppendix(appendix, book: book, store: store, into: created.context,
                                                          firstPageNumber: MarkedUpExport.appendixFirstPageNumber(bookPageCount: pageCount)) { fraction in
                    progress(min(0.99, (Double(pageCount) + fraction * Double(appendix.totalCounts.items)) / total))
                }
            }
            created.close(outline: MarkedUpExport.outline(book: MarkedUpExport.bookOutline(outline), appendix: appendixOutline))
            try Task.checkCancellation()
            let expectedPages = pageCount + (appendixOutline == nil ? 0 : 1)
            guard await pagesInFile(fileURL) >= expectedPages else { throw MarkedUpExportError.writeFailed }
            progress(1)
            return NotebookExportResult(fileURL: fileURL, workDirectory: work)
        } catch {
            file?.close()
            await removeItem(work)
            throw error
        }
    }

    /// Draws the notes appendix after the book's pages and returns its outline entry.
    private static func writeAppendix(_ notebook: Notebook, book: Book, store: LibraryStore, into context: CGContext,
                                      firstPageNumber: Int,
                                      progress: @escaping @MainActor (Double) -> Void) async throws -> ExportOutlineItem? {
        let title = OutlineText.normalizedTitle(book.title)
        let writer = NotebookPDFWriter(context: context, bookTitle: title, footerTitle: "\(title) · Notes",
                                       firstPageNumber: firstPageNumber, destinationName: MarkedUpPDFFile.destinationName)
        let notes = notebook.totalCounts.notes
        let heading = NotebookPDFWriter.Heading(title: MarkedUpExport.appendixTitle,
                                                subtitle: "\(title) · \(notes) \(notes == 1 ? "note" : "notes")")
        do {
            try await writer.write(notebook, heading: heading, loadInk: { note in
                try? await store.noteInk(bookID: book.id, noteID: note.id)
            }, progress: progress)
        } catch {
            writer.close()
            throw error
        }
        return MarkedUpExport.appendixOutline(notebook, starts: writer.partStarts)
    }

    /// Raised by a memory warning while an export runs; `take()` reads and lowers it.
    private final class MemoryWarningFlag {
        private var raised = false
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.raised = true }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func take() -> Bool {
            defer { raised = false }
            return raised
        }
    }

    // MARK: Files (off the main thread)

    @concurrent
    private nonisolated static func pagesInFile(_ url: URL) async -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    @concurrent
    private nonisolated static func createDirectory(_ url: URL) async throws {
        try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
    }

    @concurrent
    private nonisolated static func removeItem(_ url: URL) async {
        try? FileManager().removeItem(at: url)
    }
}
