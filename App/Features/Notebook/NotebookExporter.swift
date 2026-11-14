import Foundation
import ReaderCore
import UIKit

/// The Notebook's export formats.
nonisolated enum NotebookExportFormat: String, Sendable, CaseIterable, Identifiable {
    case markdown
    case pdf

    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .pdf: "PDF"
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
/// `MarkdownExporter.export` output (the core's pinned format), plus one PNG per note with ink
/// (the whole note, text and ink together, `NotePageRenderer.pngData` at 3x), referenced through
/// the exporter's `imagePath` hook with relative paths `images/note-001.png`,
/// `images/note-002.png`, … numbered in output order. Layout:
///
///     <Title> Notebook/
///         <Title> Notebook.md
///         images/note-001.png …
///
/// **Shared as:** the `.md` file alone when no note has ink; otherwise a `.zip` of that folder
/// (`<Title> Notebook.zip`, made with `NSFileCoordinator`'s `.forUploading` zip). A zip rather
/// than the folder because a folder URL is not reliably accepted by every share destination
/// (Mail, AirDrop to older systems, third-party apps); "Save to Files" saves the zip, which Files
/// expands with a tap.
///
/// ## PDF
/// See `NotebookPDFWriter`: the faithful format, every note drawn with `NotePageRenderer.draw`.
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

    static func export(_ format: NotebookExportFormat, notebook: Notebook, book: Book, store: LibraryStore,
                       root: URL = defaultRoot, progress: @escaping @MainActor (Double) -> Void = { _ in })
        async throws -> NotebookExportResult {
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try await createDirectory(work)
            let file: URL
            switch format {
            case .markdown:
                file = try await exportMarkdown(notebook: notebook, book: book, store: store, into: work, progress: progress)
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

    /// The Markdown text and the inked notes to render, in output order with their relative paths.
    nonisolated static func markdown(for notebook: Notebook, bookTitle: String)
        -> (text: String, images: [(note: Note, path: String)]) {
        var images: [(note: Note, path: String)] = []
        let text = MarkdownExporter.export(notebook, bookTitle: bookTitle) { note in
            guard note.hasInk else { return nil }
            let path = "images/" + imageName(ordinal: images.count + 1)
            images.append((note, path))
            return path
        }
        return (text, images)
    }

    @concurrent
    private nonisolated static func buildMarkdown(_ notebook: Notebook, bookTitle: String) async
        -> (text: String, images: [(note: Note, path: String)]) {
        markdown(for: notebook, bookTitle: bookTitle)
    }

    private static func exportMarkdown(notebook: Notebook, book: Book, store: LibraryStore, into work: URL,
                                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let base = baseName(forBookTitle: book.title)
        let folder = work.appendingPathComponent(base, isDirectory: true)
        let markdownURL = folder.appendingPathComponent(base + ".md")
        let (text, images) = await buildMarkdown(notebook, bookTitle: book.title)
        try Task.checkCancellation()
        try await createDirectory(folder)
        try await write(Data(text.utf8), to: markdownURL)
        let steps = Double(images.count + 2)
        progress(1 / steps)
        if images.isEmpty { return markdownURL }

        try await createDirectory(folder.appendingPathComponent("images", isDirectory: true))
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            let ink = try? await store.noteInk(bookID: book.id, noteID: image.note.id)
            try Task.checkCancellation()
            let png = autoreleasepool { NotePageRenderer.pngData(note: image.note, inkData: ink) }
            guard let png else { throw CocoaError(.fileWriteUnknown) }
            try await write(png, to: folder.appendingPathComponent(image.path))
            progress(Double(index + 2) / steps)
            await Task.yield()
        }
        try Task.checkCancellation()
        let zip = work.appendingPathComponent(base + ".zip")
        try await zipDirectory(folder, to: zip)
        return zip
    }

    // MARK: PDF

    private static func exportPDF(notebook: Notebook, book: Book, store: LibraryStore, into work: URL,
                                  progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let url = work.appendingPathComponent(baseName(forBookTitle: book.title) + ".pdf")
        let writer = try NotebookPDFWriter(url: url, bookTitle: book.title)
        do {
            try await writer.write(notebook, loadInk: { note in
                try? await store.noteInk(bookID: book.id, noteID: note.id)
            }, progress: progress)
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
