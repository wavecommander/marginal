import Foundation
import PDFKit
import ReaderCore

/// A small internal importer used by `-importFixture` (and, until WP3 lands, by the incoming-PDF
/// hook). It is **not** the user-facing import pipeline: WP3 owns that (Files picker, progress,
/// cancellation, drag and drop, "Open in", cover thumbnails, the real content fingerprint) and
/// may replace this type entirely.
///
/// Order of work, chosen so a crash never leaves a visible book without its file and the
/// launch-time orphan sweep (`LibraryStore.sweepOrphanedBookDirectories`, run before any import)
/// can never remove a directory whose record is about to be saved:
/// 1. off the main thread: read the size, compute the placeholder fingerprint;
/// 2. main: return the existing book with that fingerprint (re-copying its PDF if missing);
/// 3. off the main thread: copy into `Books/<id>/<fileName>` and read the page count;
/// 4. main: save the `Book` (posts `.bookSaved`).
///
/// **Fingerprint placeholder:** `"placeholder-v1:<file name>:<byte size>"`. Deterministic and
/// cheap, but not a content hash; WP3 replaces it with a real digest.
@MainActor
struct FixtureImporter {
    let store: LibraryStore
    let origin = ChangeOrigin(label: "fixture importer")

    enum ImportError: Error, Equatable {
        case unreadable(String)
        case notAPDF(String)
    }

    /// Imports (or finds) the PDF at `source`. The source is copied, never moved or modified.
    func importPDF(at source: URL) async throws -> Book {
        let info = try await Self.inspectSource(source)
        if let existing = try store.books.book(fingerprint: info.fingerprint) {
            let destination = store.documentURL(for: existing)
            if !FileManager.default.fileExists(atPath: destination.path) {
                _ = try await Self.copy(source, to: destination)
            }
            return existing
        }
        let id = UUID()
        let fileName = source.lastPathComponent
        let destination = store.url(forRelativePath: BookStorageLayout.documentPath(bookID: id, fileName: fileName))
        let pageCount = try await Self.copy(source, to: destination)
        let title = source.deletingPathExtension().lastPathComponent
        let book = Book(id: id, title: title, fingerprint: info.fingerprint, fileName: fileName,
                        pageCount: pageCount, fileSize: info.size)
        try store.perform(as: origin) { try store.books.save(book) }
        return book
    }

    nonisolated struct SourceInfo: Sendable {
        var size: Int64
        var fingerprint: String
    }

    @concurrent
    nonisolated static func inspectSource(_ source: URL) async throws -> SourceInfo {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw ImportError.unreadable(source.path) }
        return SourceInfo(size: Int64(size), fingerprint: "placeholder-v1:\(source.lastPathComponent):\(size)")
    }

    /// Copies `source` to `destination` (replacing it) and returns the page count.
    @concurrent
    nonisolated static func copy(_ source: URL, to destination: URL) async throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
        guard let document = PDFDocument(url: destination) else {
            try? manager.removeItem(at: destination)
            throw ImportError.notAPDF(source.lastPathComponent)
        }
        return document.pageCount
    }
}
