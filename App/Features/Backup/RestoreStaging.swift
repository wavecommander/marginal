import Foundation
import ReaderBackup
import ReaderCore

/// Why staging a book failed. `damaged` means the backup itself is bad (a file's hash, a missing
/// or unexpected file, unreadable records): the restore then stops before committing anything.
/// `pdf` means the PDF could not be fetched from where it was planned to come from (a
/// destination's copy, another local book's file): only that book fails.
nonisolated enum RestoreStagingError: Error {
    case damaged(any Error)
    case pdf(any Error)
}

/// The file work of restoring one book, off the main actor: everything up to, but not including,
/// the commit. Nothing here touches `Books/` or the database.
///
/// Into `Restores/<session>/staged/<bookID>/`: every file of the book, verified against the
/// manifest's size and SHA-256 as it streams (`BackupArchiveReader.extractFiles`), except
/// recognised text and recognition state (`BackupDerivedFiles`), which are dropped; the PDF when it
/// comes from the archive, the destination or a local book that is not being replaced (each
/// verified against the manifest's SHA-256); `document.sha256` from the manifest; `cover.jpg`
/// rendered from the PDF when the backup has none. Into `commit-<bookID>/archive.json`: the
/// records, with each note's `hasInk` reconciled to the note-ink files actually present and
/// notes left empty by that dropped. Everything is synced to disk before this returns.
nonisolated enum RestoreStaging {
    /// Where the book's PDF comes from (resolved on the main actor before staging, in the plan's
    /// order: embedded → destination → a local book → none).
    enum PDFSource: Sendable, Equatable {
        /// `pdfs/<sha256>.pdf` in the archive.
        case embedded
        /// `PDFs/<sha256>.pdf` at the session's destination.
        case destination
        /// A copy of a local book's PDF (a book that is not replaced), hash already checked.
        case copy(from: URL)
        /// The PDF of a replaced local book, moved across during the commit. `documentURL` is
        /// where it is now (for rendering a missing cover).
        case replacedLocalBook(RestoreJournal.LocalPDF, documentURL: URL)
        /// Restored without a PDF ("PDF missing").
        case none

        /// Bytes this source makes staging read and write.
        func stagedBytes(size: Int64) -> Int64 {
            switch self {
            case .embedded, .destination, .copy: size
            case .replacedLocalBook, .none: 0
            }
        }
    }

    struct Input: Sendable {
        var sessionDirectory: URL
        var entry: BackupManifest.BookEntry
        var pdfSource: PDFSource
        /// Records to stage instead of the backup's `records.json` (an undo of a merge whose
        /// safety copy was amended at commit time); `nil`: the backup's.
        var records: BookArchive? = nil
    }

    struct Output: Sendable {
        /// The records to commit (reconciled).
        var archive: BookArchive
        /// The PDF source used.
        var pdfSource: PDFSource
        /// Notes whose `hasInk` was corrected to the files present.
        var reconciledNotes: Int
        /// Notes dropped because they were empty after the correction.
        var droppedEmptyNotes: Int
    }

    /// Bytes `stage` reads for `input` (progress weight).
    static func weight(of input: Input) -> Int64 {
        input.entry.files.reduce(0) { $0 + $1.size } + input.pdfSource.stagedBytes(size: input.entry.pdf.size)
    }

    @concurrent
    static func stage(_ input: Input, reader: BackupArchiveReader, destination: (any BackupDestination)?,
                      progress: BackupProgress?) async throws -> Output {
        let entry = input.entry
        let bookID = entry.book.id
        let manager = FileManager.default
        let staged = RestoreLayout.stagedDirectory(session: input.sessionDirectory, bookID: bookID)
        let pdfURL = staged.appendingPathComponent(entry.book.fileName, isDirectory: false)
        let filesBytes = entry.files.reduce(0) { $0 + $1.size }
        let pdfBytes = input.pdfSource.stagedBytes(size: entry.pdf.size)
        let total = Double(max(1, filesBytes + pdfBytes))
        let filesProgress: BackupProgress = { progress?(Double(filesBytes) * $0 / total) }
        let pdfProgress: BackupProgress = { progress?((Double(filesBytes) + Double(pdfBytes) * $0) / total) }

        do {
            guard RestoreNames.isSafeFileName(entry.book.fileName) else {
                throw RestoreStagingError.damaged(BackupError.unsafeEntryName(name: entry.book.fileName))
            }
            // The book's files and records, verified.
            var archive: BookArchive
            do {
                try manager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try reader.extractFiles(ofBook: bookID, into: staged, progress: filesProgress)
                // Recognised text is derived from the PDF and never restored from a backup (an
                // archive written before it was left out may hold it): a book restored fresh
                // starts with no recognition state; a replaced local book's is carried across
                // at commit time (`RestoreCommit.keptRecognition`).
                for name in BackupDerivedFiles.topLevelNames {
                    let url = staged.appendingPathComponent(name)
                    if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                }
                archive = try input.records ?? reader.bookArchive(for: bookID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RestoreStagingError.damaged(error)
            }

            // The PDF, verified against the manifest.
            let expected = entry.pdf.digest
            switch input.pdfSource {
            case .embedded:
                do {
                    try reader.extractPDF(sha256: expected.sha256, to: pdfURL, progress: pdfProgress)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RestoreStagingError.damaged(error)
                }
            case .destination:
                guard let destination else { throw RestoreStagingError.pdf(BackupError.pdfNotAtDestination(sha256: expected.sha256)) }
                do {
                    try await destination.downloadPDF(sha256: expected.sha256, to: pdfURL, progress: pdfProgress)
                    // The destination verifies too; check again here, whatever the implementation.
                    let digest = try ContentHash.digest(ofFileAt: pdfURL)
                    guard digest == expected else { throw BackupError.contentMismatch(name: entry.book.fileName) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? manager.removeItem(at: pdfURL)
                    throw RestoreStagingError.pdf(error)
                }
            case .copy(let source):
                do {
                    try manager.copyItem(at: source, to: pdfURL)
                    let digest = try ContentHash.digest(ofFileAt: pdfURL, progress: pdfProgress)
                    guard digest == expected else { throw BackupError.contentMismatch(name: entry.book.fileName) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? manager.removeItem(at: pdfURL)
                    throw RestoreStagingError.pdf(error)
                }
            case .replacedLocalBook, .none:
                break
            }
            try Task.checkCancellation()

            // The sidecar, from the manifest: the hash the PDF has, or must have to be linked.
            try DocumentDigest.writeSidecar(expected, to: staged.appendingPathComponent(BookStorageLayout.contentHashFileName))

            // Notes: `hasInk` follows the files present; a note left empty is dropped.
            let inkFiles = noteInkIDs(in: staged.appendingPathComponent("notes", isDirectory: true))
            var reconciled = 0
            var dropped = 0
            var notes: [Note] = []
            for var note in archive.notes {
                let hasFile = inkFiles.contains(note.id)
                if note.hasInk != hasFile {
                    reconciled += 1
                    note.hasInk = hasFile
                    if !hasFile { note.bandLayout = nil }
                }
                if note.isEmpty {
                    dropped += 1
                } else {
                    notes.append(note)
                }
            }
            archive.notes = notes
            do {
                try archive.validateForReplacement()
            } catch {
                throw RestoreStagingError.damaged(BackupError.recordsInvalid(bookTitle: entry.book.title))
            }

            // The cover, when the backup has none and a PDF is at hand.
            let cover = staged.appendingPathComponent(ImportPipeline.coverFileName, isDirectory: false)
            if !manager.fileExists(atPath: cover.path) {
                var source: URL?
                if manager.fileExists(atPath: pdfURL.path) {
                    source = pdfURL
                } else if case .replacedLocalBook(_, let documentURL) = input.pdfSource {
                    source = documentURL
                }
                if let source, let data = ImportPipeline.coverJPEG(of: source) {
                    try data.write(to: cover, options: .atomic)
                }
            }

            // The records beside the journal-to-be, then everything to disk.
            let archiveURL = RestoreLayout.archiveFile(session: input.sessionDirectory, bookID: bookID)
            try RestoreDurability.writeDurably(try BackupCoding.makeEncoder().encode(archive), to: archiveURL)
            try RestoreDurability.syncTree(staged)
            progress?(1)
            return Output(archive: archive, pdfSource: input.pdfSource, reconciledNotes: reconciled, droppedEmptyNotes: dropped)
        } catch {
            try? manager.removeItem(at: staged)
            try? manager.removeItem(at: RestoreLayout.commitDirectory(session: input.sessionDirectory, bookID: bookID))
            throw error
        }
    }

    /// IDs of the note-ink files (`notes/<noteID>.drawing`) in `directory`.
    static func noteInkIDs(in directory: URL) -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name -> UUID? in
            guard name.hasSuffix(".drawing") else { return nil }
            return UUID(uuidString: String(name.dropLast(".drawing".count)))
        })
    }
}
