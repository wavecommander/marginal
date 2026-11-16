import Foundation
import PDFKit
import ReaderCore
import UIKit

/// The Notebook's export formats.
nonisolated enum NotebookExportFormat: String, Sendable, CaseIterable, Identifiable {
    /// One `.md` file: text only.
    case markdown
    /// The Markdown in a folder with its images (handwritten notes, pages with handwriting) in
    /// subfolders, linked from the Markdown; shared as one `.zip`.
    case markdownZip
    case pdf

    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .markdownZip: "Markdown (ZIP)"
        case .pdf: "PDF"
        }
    }

    var accessibilityID: String {
        switch self {
        case .markdown: NotebookAccessibilityID.exportMarkdown
        case .markdownZip: NotebookAccessibilityID.exportMarkdownZip
        case .pdf: NotebookAccessibilityID.exportPDF
        }
    }

    /// What the format carries, under its title in the Export menu.
    var subtitle: String {
        switch self {
        case .markdown: "Text only"
        case .markdownZip: "With images and handwriting"
        case .pdf: "Every note as it looks"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "doc.plaintext"
        case .markdownZip: "doc.zipper"
        case .pdf: "doc.richtext"
        }
    }
}

/// A finished export: the file to share and the private working directory holding it, which
/// `NotebookExporter.cleanUp(_:)` removes once the share sheet is done.
nonisolated struct NotebookExportResult: Sendable, Equatable {
    /// The `.md`, `.zip` or `.pdf` to hand to the share sheet.
    let fileURL: URL
    /// `<exports root>/<UUID>/`: everything this export wrote.
    let workDirectory: URL
}

/// Exports a `Notebook` to files for the share sheet.
///
/// ## Markdown
/// `MarkdownExporter.export` output (the core's pinned format).
///
/// **`.markdown`** is one `.md` file, text only: a handwritten note keeps its typed text (or
/// reads `_Handwritten note_`), and a page with handwriting is named (`_Handwriting on page N_`).
/// The Notebook screen tells the reader to use the ZIP when an export has images
/// (`hasImages(_:)`).
///
/// **`.markdownZip`** adds the images, linked from the Markdown with relative paths:
/// - one PNG per note with ink (the whole note, text and ink together,
///   `NotePageRenderer.pngData` at 3x), numbered in output order;
/// - one PNG per page with handwriting (the page of the book with its ink,
///   `NotebookPageRenderer`, `handwritingWidth` points wide at 2x), named by page number. A page
///   that cannot be drawn (its ink is gone, or it is outside the book) keeps the text line;
/// - one PNG per scanned-page highlight (S4): the crop of the page under it
///   (`HighlightCropRenderer`, the page at its own size at 3x, on white), numbered in output
///   order and linked above its caption. A crop that cannot be drawn (the PDF is missing) leaves
///   the caption alone.
///
///     <Title> Notebook/
///         <Title> Notebook.md
///         images/note-001.png …
///         handwriting/page-024.png …
///         highlights/highlight-001.png …
///
/// The text-only `.markdown` shows a scanned-page highlight as its caption (or "Highlight on a
/// scanned page") with its page; `hasImages` counts it, so the reader is offered the ZIP.
///
/// It is shared as a `.zip` of that folder (`<Title> Notebook.zip`, made with
/// `NSFileCoordinator`'s `.forUploading` zip), which Files expands with a tap. A zip rather than
/// the folder or separate files because share destinations lay separate files side by side
/// (losing the folders the links point into), and a folder URL is not reliably accepted by every
/// destination (Mail, AirDrop to older systems, third-party apps).
///
/// ## PDF
/// See `NotebookPDFWriter`: the faithful format, every note drawn with `NotePageRenderer.draw`,
/// and every page with page ink drawn from the book with its ink (`PageInkRenderer`). The
/// Markdown names those pages ("_Handwriting on page N_") without an image. A scanned-page
/// highlight is drawn as its crop, with its caption.
///
/// ## Threading, progress, cancellation, cleanup
/// The Markdown text, file writes and the zip run off the main thread; ink files are read through
/// the ink store (an actor). Note layout and drawing run on the main actor because
/// `NotePageRenderer` is main-actor (TextKit 2 and PencilKit rendering): one note at a time, with a
/// `Task.yield()` after each, so the UI stays responsive. `progress` gets fractions in `0...1`.
/// Cancelling the calling task stops after the current note and removes everything written
/// (`CancellationError` is thrown). Every export writes into its own `workDirectory` under
/// `root`; `cleanUp` removes it, and `purgeStale` removes leftovers older than an hour.
@MainActor
enum NotebookExporter {
    /// `<tmp>/NotebookExports`.
    nonisolated static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotebookExports", isDirectory: true)
    }

    /// `"<Title> Notebook"`, with characters that are unsafe in file names replaced; `"Notebook"`
    /// for a blank title.
    nonisolated static func baseName(forBookTitle title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map { unsafe.contains($0) ? " " : $0 }))
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Notebook" : "\(cleaned) Notebook"
    }

    /// Image file name for the `ordinal`-th (1-based) inked note.
    nonisolated static func imageName(ordinal: Int) -> String {
        String(format: "note-%03d.png", ordinal)
    }

    /// Image file name for a page with handwriting (zero-based index; named by page number).
    nonisolated static func handwritingName(pageIndex: Int) -> String {
        String(format: "page-%03d.png", PageNumbering.displayNumber(forPageIndex: pageIndex))
    }

    /// Width in points (rendered at 2x) of a page-with-handwriting image in the ZIP.
    nonisolated static let handwritingWidth: CGFloat = 768

    /// Image file name for the `ordinal`-th (1-based, output order) scanned-page highlight.
    nonisolated static func highlightImageName(ordinal: Int) -> String {
        String(format: "highlight-%03d.png", ordinal)
    }

    /// Zoom (pixels per page point, before `highlightImageScale`) of a highlight crop in the ZIP:
    /// the page at its own size.
    nonisolated static let highlightImageZoom: CGFloat = 1
    /// Pixels per point of a highlight crop in the ZIP and the PDF (about 216 dpi of the page).
    nonisolated static let highlightImageScale: CGFloat = 3

    /// Whether `notebook` has anything a text-only Markdown export leaves out: a note with ink,
    /// a page with handwriting, or a scanned-page highlight (shown as a crop of the page).
    nonisolated static func hasImages(_ notebook: Notebook) -> Bool {
        if notebook.totalCounts.inkedPages > 0 { return true }
        let rendered = markdown(for: notebook, bookTitle: "", images: true)
        return !rendered.images.isEmpty || !rendered.highlightImages.isEmpty
    }

    static func export(_ format: NotebookExportFormat, notebook: Notebook, book: Book, store: LibraryStore,
                       root: URL = defaultRoot, progress: @escaping @MainActor (Double) -> Void = { _ in })
        async throws -> NotebookExportResult {
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try await createDirectory(work)
            let file: URL
            switch format {
            case .markdown:
                file = try await exportMarkdownText(notebook: notebook, book: book, into: work, progress: progress)
            case .markdownZip:
                file = try await exportMarkdownZip(notebook: notebook, book: book, store: store, into: work,
                                                   progress: progress)
            case .pdf:
                file = try await exportPDF(notebook: notebook, book: book, store: store, into: work, progress: progress)
            }
            try Task.checkCancellation()
            progress(1)
            return NotebookExportResult(fileURL: file, workDirectory: work)
        } catch {
            await removeItem(work)
            throw error
        }
    }

    /// Removes an export's working directory (after the share sheet finished with it).
    static func cleanUp(_ result: NotebookExportResult) {
        let directory = result.workDirectory
        Task.detached(priority: .utility) { try? FileManager().removeItem(at: directory) }
    }

    /// Removes working directories under `root` older than `age` (left by a crash or a kill).
    nonisolated static func purgeStale(root: URL = defaultRoot, olderThan age: TimeInterval = 3600) async {
        await Task.detached(priority: .utility) {
            let manager = FileManager()
            guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
            let limit = Date().addingTimeInterval(-age)
            for item in items {
                let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if created < limit { try? manager.removeItem(at: item) }
            }
        }.value
    }

    // MARK: Markdown

    /// The Markdown text. With `images`, also the inked notes to render, in output order with
    /// their paths relative to the Markdown file (`images/note-001.png` …), an image link
    /// (`handwriting/page-024.png`) for each page in `handwritingPages`, and the scanned-page
    /// highlights in output order with their crop's path (`highlights/highlight-001.png` …),
    /// linked only when `drawnHighlights` (when given) contains the highlight; without, text
    /// only (a scanned-page highlight then reads as its caption, S1's form).
    nonisolated static func markdown(for notebook: Notebook, bookTitle: String, images withImages: Bool,
                                     handwritingPages: Set<Int> = [], drawnHighlights: Set<UUID>? = nil)
        -> (text: String, images: [(note: Note, path: String)], highlightImages: [(highlight: Highlight, path: String)]) {
        var images: [(note: Note, path: String)] = []
        var highlightImages: [(highlight: Highlight, path: String)] = []
        var highlightOrdinal = 0
        let text = MarkdownExporter.export(notebook, bookTitle: bookTitle, imagePath: { note in
            guard withImages, note.hasInk else { return nil }
            let path = "images/" + imageName(ordinal: images.count + 1)
            images.append((note, path))
            return path
        }, handwritingPath: { page in
            withImages && handwritingPages.contains(page) ? "handwriting/" + handwritingName(pageIndex: page) : nil
        }, highlightImagePath: { highlight in
            guard withImages else { return nil }
            highlightOrdinal += 1
            let path = "highlights/" + highlightImageName(ordinal: highlightOrdinal)
            highlightImages.append((highlight, path))
            return drawnHighlights.map { $0.contains(highlight.id) } ?? true ? path : nil
        })
        return (text, images, highlightImages)
    }

    @concurrent
    private nonisolated static func buildMarkdown(_ notebook: Notebook, bookTitle: String, images: Bool,
                                                  handwritingPages: Set<Int> = [], drawnHighlights: Set<UUID>? = nil) async
        -> (text: String, images: [(note: Note, path: String)], highlightImages: [(highlight: Highlight, path: String)]) {
        markdown(for: notebook, bookTitle: bookTitle, images: images, handwritingPages: handwritingPages,
                 drawnHighlights: drawnHighlights)
    }

    /// `.markdown`: the text alone, as `<Title> Notebook.md`.
    private static func exportMarkdownText(notebook: Notebook, book: Book, into work: URL,
                                           progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let url = work.appendingPathComponent(baseName(forBookTitle: book.title) + ".md")
        let text = await buildMarkdown(notebook, bookTitle: book.title, images: false).text
        try Task.checkCancellation()
        try await write(Data(text.utf8), to: url)
        progress(0.5)
        return url
    }

    /// `.markdownZip`: the folder (see the type's comment), zipped.
    private static func exportMarkdownZip(notebook: Notebook, book: Book, store: LibraryStore, into work: URL,
                                          progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let base = baseName(forBookTitle: book.title)
        let folder = work.appendingPathComponent(base, isDirectory: true)
        try await createDirectory(folder)
        let inkedPages = notebook.inkedPageIndices
        // The notes and scanned-page highlights to render do not depend on which pages can be
        // drawn: known up front.
        let planned = await buildMarkdown(notebook, bookTitle: book.title, images: true)
        let images = planned.images
        let highlightImages = planned.highlightImages
        try Task.checkCancellation()
        let steps = Double(inkedPages.count + images.count + highlightImages.count + 2)
        var done = 0.0
        func step() async {
            done += 1
            progress(done / steps)
            await Task.yield()
        }

        // Pages with handwriting first: the Markdown links only the ones that were drawn.
        var drawnPages = Set<Int>()
        if !inkedPages.isEmpty {
            try await createDirectory(folder.appendingPathComponent("handwriting", isDirectory: true))
            let renderer = NotebookPageRenderer(url: store.documentURL(for: book))
            for page in inkedPages {
                try Task.checkCancellation()
                if let ink = try? await store.pageInk(bookID: book.id, pageIndex: page),
                   let png = await pagePNG(renderer, pageIndex: page, inkData: ink) {
                    try Task.checkCancellation()
                    try await write(png, to: folder.appendingPathComponent("handwriting/" + handwritingName(pageIndex: page)))
                    drawnPages.insert(page)
                }
                await step()
            }
        }

        // Crops of scanned-page highlights: the Markdown links only the ones that were drawn (a
        // book whose PDF is missing keeps the caption alone).
        var drawnHighlights = Set<UUID>()
        if !highlightImages.isEmpty {
            try await createDirectory(folder.appendingPathComponent("highlights", isDirectory: true))
            let renderer = HighlightCropRenderer(url: store.documentURL(for: book))
            for image in highlightImages {
                try Task.checkCancellation()
                if let png = await cropPNG(renderer, highlight: image.highlight) {
                    try Task.checkCancellation()
                    try await write(png, to: folder.appendingPathComponent(image.path))
                    drawnHighlights.insert(image.highlight.id)
                }
                await step()
            }
        }

        try Task.checkCancellation()
        let text = await buildMarkdown(notebook, bookTitle: book.title, images: true, handwritingPages: drawnPages,
                                       drawnHighlights: drawnHighlights).text
        try await write(Data(text.utf8), to: folder.appendingPathComponent(base + ".md"))
        await step()

        if !images.isEmpty {
            try await createDirectory(folder.appendingPathComponent("images", isDirectory: true))
        }
        for image in images {
            try Task.checkCancellation()
            let ink = try? await store.noteInk(bookID: book.id, noteID: image.note.id)
            try Task.checkCancellation()
            let png = autoreleasepool { NotePageRenderer.pngData(note: image.note, inkData: ink) }
            guard let png else { throw CocoaError(.fileWriteUnknown) }
            try await write(png, to: folder.appendingPathComponent(image.path))
            await step()
        }
        try Task.checkCancellation()
        let zip = work.appendingPathComponent(base + ".zip")
        try await zipDirectory(folder, to: zip)
        return zip
    }

    /// The page of the book with its ink, as PNG data (`nil`: no such page, or unreadable ink).
    @concurrent
    private nonisolated static func pagePNG(_ renderer: NotebookPageRenderer, pageIndex: Int, inkData: Data) async -> Data? {
        await renderer.preview(pageIndex: pageIndex, inkData: inkData, width: handwritingWidth, scale: 2)?.image.pngData()
    }

    /// A scanned-page highlight's crop as PNG data (`nil`: the page cannot be drawn).
    @concurrent
    private nonisolated static func cropPNG(_ renderer: HighlightCropRenderer, highlight: Highlight) async -> Data? {
        await renderer.crop(pageIndex: highlight.pageIndex, rects: highlight.rects, zoom: highlightImageZoom,
                            scale: highlightImageScale)?.image.pngData()
    }

    // MARK: PDF

    private static func exportPDF(notebook: Notebook, book: Book, store: LibraryStore, into work: URL,
                                  progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let url = work.appendingPathComponent(baseName(forBookTitle: book.title) + ".pdf")
        let writer = try NotebookPDFWriter(url: url, bookTitle: book.title)
        // Pages with handwriting: drawn from a private instance of the book. Crops of scanned-page
        // highlights: rendered off the main thread from another.
        let cropRenderer = HighlightCropRenderer(url: store.documentURL(for: book))
        let bookPages = NotebookPDFWriter.BookPages(
            document: notebook.totalCounts.inkedPages > 0 ? PDFDocument(url: store.documentURL(for: book)) : nil,
            loadInk: { page in try? await store.pageInk(bookID: book.id, pageIndex: page) },
            loadCrop: { highlight in
                await cropRenderer.crop(pageIndex: highlight.pageIndex, rects: highlight.rects, zoom: 1,
                                        scale: highlightImageScale)?.image
            })
        do {
            try await writer.write(notebook, loadInk: { note in
                try? await store.noteInk(bookID: book.id, noteID: note.id)
            }, bookPages: bookPages, progress: progress)
        } catch {
            writer.close()
            throw error
        }
        return url
    }

    // MARK: Files (off the main thread)

    @concurrent
    private nonisolated static func createDirectory(_ url: URL) async throws {
        try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
    }

    @concurrent
    private nonisolated static func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .atomic)
    }

    @concurrent
    private nonisolated static func removeItem(_ url: URL) async {
        try? FileManager().removeItem(at: url)
    }

    /// Zips `folder` (the folder itself is the archive's top level) with the system's
    /// `NSFileCoordinator` `.forUploading` reading option, and moves the archive to `destination`.
    @concurrent
    nonisolated static func zipDirectory(_ folder: URL, to destination: URL) async throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipURL in
            do {
                try FileManager().moveItem(at: zipURL, to: destination)
            } catch {
                do {
                    try FileManager().copyItem(at: zipURL, to: destination)
                } catch {
                    moveError = error
                }
            }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }
}
