import Foundation
import PDFKit
import ReaderBackup
import ReaderCore

/// The file work of linking a PDF to a book that lacks it (`ImportService.restoreMissingDocument`
/// and `linkPDF`), off the main actor.
nonisolated enum DocumentLinking {
    struct Staged: Sendable {
        /// The verified copy inside the staging directory.
        var pdf: URL
        /// Its full-content digest.
        var digest: ContentDigest
        /// Its sampled fingerprint (`BookFingerprint`), checked equal to the book's.
        var fingerprint: String
        /// A rendered cover beside it, if one could be made.
        var cover: URL?
    }

    /// Copies `source` to `directory/fileName`, hashing in the same pass, then checks, in order:
    /// the copy's full SHA-256 against `expected` (when the book has a sidecar), its sampled
    /// fingerprint against `fingerprint`, and that it opens as an unlocked PDF with pages; then
    /// renders a cover beside it. A wrong file throws `ImportError.pdfMismatch(bookTitle:)`.
    /// On any error the caller removes `directory`.
    @concurrent
    static func stage(source: URL, directory: URL, fileName: String, fingerprint: String, expected: ContentDigest?,
                      bookTitle: String, size: Int64, progress: @Sendable (Double) -> Void) async throws -> Staged {
        let manager = FileManager.default
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        let digest: ContentDigest
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            digest = try copyHashing(from: source, to: destination, totalSize: size, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NSError where ImportPipeline.isOutOfSpace(error) {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        } catch {
            throw ImportError.unreadable(fileName: source.lastPathComponent, reason: error.localizedDescription)
        }
        if let expected, expected != digest { throw ImportError.pdfMismatch(bookTitle: bookTitle) }
        let stagedFingerprint: String
        do {
            stagedFingerprint = try BookFingerprint.fingerprint(ofFileAt: destination)
        } catch {
            throw ImportError.unreadable(fileName: source.lastPathComponent, reason: error.localizedDescription)
        }
        guard stagedFingerprint == fingerprint else { throw ImportError.pdfMismatch(bookTitle: bookTitle) }
        try Task.checkCancellation()

        guard let document = PDFDocument(url: destination) else { throw ImportError.notAPDF(fileName: source.lastPathComponent) }
        if document.isLocked { throw ImportError.locked(fileName: source.lastPathComponent) }
        guard document.pageCount > 0 else { throw ImportError.noPages(fileName: source.lastPathComponent) }
        try Task.checkCancellation()

        let cover = directory.appendingPathComponent(ImportPipeline.coverFileName, isDirectory: false)
        let hasCover = ImportPipeline.renderCover(of: destination, to: cover)
        return Staged(pdf: destination, digest: digest, fingerprint: stagedFingerprint, cover: hasCover ? cover : nil)
    }

    /// Chunked copy that hashes what it copies, with progress and cooperative cancellation.
    /// Removes a partial destination before rethrowing.
    static func copyHashing(from source: URL, to destination: URL, totalSize: Int64,
                            progress: @Sendable (Double) -> Void) throws -> ContentDigest {
        let manager = FileManager.default
        guard manager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hasher = ContentHasher()
            var lastReported = -1.0
            while true {
                try Task.checkCancellation()
                let chunk: Data? = try autoreleasepool { try input.read(upToCount: ImportPipeline.copyChunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                hasher.update(chunk)
                if totalSize > 0 {
                    let fraction = min(1, Double(hasher.byteCount) / Double(totalSize))
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
            try output.synchronize()
            progress(1)
            return hasher.finalize()
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    /// The full digest of a file, off the main actor.
    @concurrent
    static func digest(of url: URL) async throws -> ContentDigest {
        try ContentHash.digest(ofFileAt: url)
    }
}
