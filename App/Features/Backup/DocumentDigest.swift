import Foundation
import ReaderBackup
import ReaderCore

/// The full-content SHA-256 of a book's PDF and its `Books/<bookID>/document.sha256` sidecar
/// (`BookStorageLayout.contentHashPath`): JSON `{"sha256": <64 lower-case hex digits>, "size": <bytes>}`.
///
/// The sidecar is a cache of the hash of the imported PDF, which never changes, so it is computed
/// at most once per book. For a book restored **without** its PDF it is written from the backup's
/// manifest and is then the hash a PDF must match to be linked to the book (`ImportService`).
///
/// Everything here is `nonisolated`; the hashing entry point is `@concurrent`, so a 600 MB PDF is
/// never hashed on the main actor.
nonisolated enum DocumentDigest {
    /// The sidecar's JSON shape.
    private struct Sidecar: Codable {
        var sha256: String
        var size: Int64
    }

    // MARK: Sidecar

    /// The sidecar at `url`, or `nil` when it is absent or not a well-formed sidecar (a malformed
    /// sidecar is treated as absent).
    static func readSidecar(at url: URL) -> ContentDigest? {
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return nil }
        let hash = sidecar.sha256.lowercased()
        guard ContentHash.isValidSHA256(hash), sidecar.size >= 0 else { return nil }
        return ContentDigest(sha256: hash, size: sidecar.size)
    }

    /// Encodes the sidecar (sorted keys, so the same digest always gives the same bytes).
    static func sidecarData(_ digest: ContentDigest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Sidecar(sha256: digest.sha256.lowercased(), size: digest.size))
    }

    /// Writes the sidecar atomically. The directory must exist already: a sidecar is never the
    /// thing that creates a book's directory (a book deleted meanwhile must not get it back).
    static func writeSidecar(_ digest: ContentDigest, to url: URL) throws {
        try sidecarData(digest).write(to: url, options: .atomic)
    }

    // MARK: Digest

    /// The digest of the book's PDF at `documentURL`, using the sidecar at `sidecarURL`:
    /// - the sidecar's value when it exists and its size matches the PDF on disk;
    /// - the sidecar's value when the PDF is absent (it is then the hash the PDF must match);
    /// - otherwise the PDF's hash, computed now (streamed, off the main actor, cancellable) and
    ///   cached to the sidecar (best effort; only into an existing directory);
    /// - `nil` when there is neither a PDF nor a sidecar.
    /// Throws when the PDF exists but cannot be read, and `CancellationError` when cancelled.
    @concurrent
    static func digest(documentURL: URL, sidecarURL: URL, progress: BackupProgress? = nil) async throws -> ContentDigest? {
        try digestNow(documentURL: documentURL, sidecarURL: sidecarURL, progress: progress)
    }

    /// `digest(documentURL:sidecarURL:progress:)`, blocking. Call it only off the main actor.
    static func digestNow(documentURL: URL, sidecarURL: URL, progress: BackupProgress? = nil) throws -> ContentDigest? {
        let pdfSize = regularFileSize(documentURL)
        let sidecar = readSidecar(at: sidecarURL)
        if let sidecar, pdfSize == nil || pdfSize == sidecar.size {
            progress?(1)
            return sidecar
        }
        guard pdfSize != nil else { return nil }
        let computed = try ContentHash.digest(ofFileAt: documentURL, progress: progress)
        try? writeSidecar(computed, to: sidecarURL)
        return computed
    }

    /// Size of the regular file at `url`, or `nil` when there is none.
    static func regularFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
    }
}

extension LibraryStore {
    /// The full-file digest of `book`'s PDF (see `DocumentDigest.digest`): from the sidecar when it
    /// is current, else computed off the main actor and cached. `nil` when the book has neither
    /// a PDF nor a sidecar.
    func contentDigest(of book: Book, progress: BackupProgress? = nil) async throws -> ContentDigest? {
        try await DocumentDigest.digest(documentURL: documentURL(for: book), sidecarURL: contentHashURL(bookID: book.id),
                                        progress: progress)
    }

    /// The sidecar's digest only (never hashes anything): what the restore preview shows.
    nonisolated func storedContentDigest(bookID: UUID) -> ContentDigest? {
        DocumentDigest.readSidecar(at: contentHashURL(bookID: bookID))
    }
}
