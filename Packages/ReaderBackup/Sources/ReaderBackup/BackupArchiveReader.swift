import Foundation
import ReaderCore

/// Reads a `.ttbackup` snapshot archive written by `BackupArchiveWriter`.
///
/// `init` opens the archive (see `ZipArchiveReader` for the structural checks) and reads and
/// validates only the manifest, which is all the restore preview needs. Books are then read one
/// at a time: their records with `bookArchive(for:)`, their files with
/// `extractFiles(ofBook:into:progress:)`, and an embedded PDF with `extractPDF(sha256:to:progress:)`.
/// Every file is checked against the manifest's size and SHA-256 while it streams; any mismatch
/// throws a `BackupError` naming the file and leaves nothing partial behind.
///
/// `Sendable` (immutable, positioned reads). Blocking: call it off the main actor.
public final class BackupArchiveReader: Sendable {
    /// The archive file.
    public let url: URL
    /// The validated manifest.
    public let manifest: BackupManifest

    private let zip: ZipArchiveReader

    /// Opens `url` and reads its manifest. Throws `notABackup` when there is no manifest or it
    /// names another format, `newerFormatVersion` for a backup from a newer app, and the
    /// archive errors of `ZipArchiveReader`.
    public init(url: URL) throws {
        let zip = try ZipArchiveReader(url: url)
        guard let entry = zip.entry(named: BackupArchiveLayout.manifestPath) else { throw BackupError.notABackup }
        let data = try zip.data(of: entry, maximumSize: 256 * 1024 * 1024)
        self.manifest = try BackupManifest.decode(data)
        self.url = url
        self.zip = zip
    }

    /// Hashes of the PDFs this archive holds.
    public var embeddedPDFHashes: Set<String> {
        Set(manifest.books.filter(\.pdf.embedded).map(\.pdf.sha256))
    }

    /// The book's records: the manifest's `Book` plus its `records.json`. Throws
    /// `bookNotInBackup`, `missingFile` when the records are absent, and `recordsInvalid` when
    /// they do not decode or a record's `bookID` is not the book's (`BookArchive.isConsistent`).
    public func bookArchive(for bookID: UUID) throws -> BookArchive {
        let entry = try bookEntry(bookID)
        let path = BackupArchiveLayout.recordsPath(bookID: bookID)
        guard let recordsEntry = zip.entry(named: path) else { throw BackupError.missingFile(name: path) }
        let data = try zip.data(of: recordsEntry, maximumSize: 512 * 1024 * 1024)
        let records: BookRecordsFile
        do {
            records = try BackupCoding.makeDecoder().decode(BookRecordsFile.self, from: data)
        } catch {
            throw BackupError.recordsInvalid(bookTitle: entry.book.title)
        }
        let archive = records.archive(for: entry.book)
        guard archive.isConsistent else { throw BackupError.recordsInvalid(bookTitle: entry.book.title) }
        return archive
    }

    /// Extracts every file the manifest lists for the book into `directory`, at its relative
    /// path (creating subdirectories), verifying each file's size and SHA-256 as it streams.
    ///
    /// `directory` must not exist yet or be empty; it is created (even when the book has no
    /// files). The archive must hold exactly the listed files under the book's folder (besides
    /// `records.json`): an extra one throws `unexpectedFile`, an absent one `missingFile`, a
    /// changed one `contentMismatch`, all naming the file's path in the book. On any failure or
    /// cancellation everything this call created is removed again.
    public func extractFiles(ofBook bookID: UUID, into directory: URL, progress: BackupProgress? = nil) throws {
        let entry = try bookEntry(bookID)
        let prefix = BackupArchiveLayout.bookDirectory(bookID: bookID) + "/"
        let recordsPath = BackupArchiveLayout.recordsPath(bookID: bookID)
        var present: [String: ZipEntry] = [:]
        for item in zip.entries where item.name.hasPrefix(prefix) && !item.isDirectory && item.name != recordsPath {
            present[String(item.name.dropFirst(prefix.count))] = item
        }
        let listed = Set(entry.files.map(\.path))
        if let extra = present.keys.filter({ !listed.contains($0) }).sorted().first {
            throw BackupError.unexpectedFile(name: extra)
        }
        if let absent = entry.files.first(where: { present[$0.path] == nil }) {
            throw BackupError.missingFile(name: absent.path)
        }
        for file in entry.files where present[file.path]?.size != file.size {
            throw BackupError.contentMismatch(name: file.path)
        }

        let manager = FileManager.default
        let existed = manager.fileExists(atPath: directory.path)
        if existed {
            let contents = try mappingFileErrors(directory) { try manager.contentsOfDirectory(atPath: directory.path) }
            guard contents.isEmpty else {
                throw BackupError.fileAccessFailed(name: directory.lastPathComponent, code: Int(ENOTEMPTY))
            }
        }
        let tracker = ProgressTracker(total: entry.files.reduce(0) { $0 + $1.size }, report: progress)
        do {
            try FileOps.createDirectory(directory)
            tracker.report()
            for file in entry.files {
                guard let item = present[file.path] else { throw BackupError.missingFile(name: file.path) }
                let destination = directory.appendingPathComponent(file.path, isDirectory: false)
                try FileOps.createDirectory(destination.deletingLastPathComponent())
                let base = tracker.done
                do {
                    try zip.extract(item, to: destination, expected: file.digest, onBytes: { tracker.set(base + $0) })
                } catch BackupError.contentMismatch, BackupError.entryChecksumMismatch {
                    throw BackupError.contentMismatch(name: file.path)
                }
            }
            progress?(1)
        } catch {
            if existed {
                for child in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    FileOps.removeQuietly(child)
                }
            } else {
                FileOps.removeQuietly(directory)
            }
            throw error
        }
    }

    /// Extracts the embedded PDF with this SHA-256 to the file `destination` (replacing any
    /// file there), verifying its size and SHA-256 while streaming. Throws `pdfNotInBackup`
    /// when no book's PDF is embedded with that hash, `contentMismatch` naming the PDF's file
    /// name when the bytes differ. Nothing is left at `destination` on failure.
    public func extractPDF(sha256: String, to destination: URL, progress: BackupProgress? = nil) throws {
        let hash = sha256.lowercased()
        guard let entry = manifest.books.first(where: { $0.pdf.embedded && $0.pdf.sha256 == hash }) else {
            throw BackupError.pdfNotInBackup(sha256: hash)
        }
        let path = BackupArchiveLayout.embeddedPDFPath(sha256: hash)
        guard let item = zip.entry(named: path) else { throw BackupError.missingFile(name: entry.book.fileName) }
        progress?(0)
        do {
            try zip.extract(item, to: destination, expected: entry.pdf.digest, progress: progress)
        } catch BackupError.contentMismatch, BackupError.entryChecksumMismatch {
            throw BackupError.contentMismatch(name: entry.book.fileName)
        }
        progress?(1)
    }

    private func bookEntry(_ bookID: UUID) throws -> BackupManifest.BookEntry {
        guard let entry = manifest.entry(for: bookID) else { throw BackupError.bookNotInBackup(bookID) }
        return entry
    }
}
