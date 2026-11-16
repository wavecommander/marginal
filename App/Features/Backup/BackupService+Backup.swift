import Foundation
import ReaderBackup
import ReaderCore

/// A consistent snapshot of the library's records, with where each book's files are.
nonisolated struct LibrarySnapshot: Sendable {
    struct Item: Sendable {
        var archive: BookArchive
        /// `Books/<bookID>`
        var directory: URL
        /// The PDF (may be absent).
        var documentURL: URL
        /// `document.sha256`
        var sidecarURL: URL
    }

    var items: [Item]
}

extension BackupService {
    // MARK: Snapshot

    /// Every book's records, read in one main-actor pass with no suspension point between books
    /// (so no edit can land between two books' reads). Call after `flushEditors`. Books in the
    /// order they were added.
    func takeSnapshot() throws -> LibrarySnapshot {
        let books = try store.books.allBooks().sorted {
            $0.addedAt != $1.addedAt ? $0.addedAt < $1.addedAt : $0.id.uuidString < $1.id.uuidString
        }
        var items: [LibrarySnapshot.Item] = []
        items.reserveCapacity(books.count)
        for book in books {
            guard let archive = try store.archive(bookID: book.id) else { continue }
            items.append(LibrarySnapshot.Item(archive: archive, directory: store.bookDirectoryURL(bookID: book.id),
                                              documentURL: store.documentURL(for: archive.book),
                                              sidecarURL: store.contentHashURL(bookID: book.id)))
        }
        return LibrarySnapshot(items: items)
    }

    // MARK: Size estimate

    /// The size of a backup of the library now, without and with PDFs. Cheap: directory
    /// listings and the records' encoded size, no file is read.
    func estimateSizes() async throws -> BackupSizeEstimate {
        try await BackupWork.prepare(takeSnapshot()).estimate
    }

    // MARK: Back up to a file

    /// Makes a single-file backup (`.ttbackup`, PDFs embedded with `includePDFs`) in the
    /// temporary directory and returns it. The UI moves the file where the reader chooses, then
    /// calls `discardTemporaryFile(_:)`.
    /// - Throws: `BackupServiceError.busy`, `.notEnoughSpace` (checked before starting against the
    ///   estimate), `BackupError`, `CancellationError` (no temporary file is left).
    func backUpToFile(includePDFs: Bool) async throws -> BackupFileResult {
        try await run(.backUpToFile) { job in
            try await self.performFileBackup(includePDFs: includePDFs, job: job)
        }
    }

    private func performFileBackup(includePDFs: Bool, job: BackupJob) async throws -> BackupFileResult {
        job.set(phase: .savingOpenBooks)
        await flushEditorsNow()
        let snapshot = try takeSnapshot()

        job.set(phase: .checkingSpace)
        let prepared = try await BackupWork.prepare(snapshot)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let archiveBytes = includePDFs ? prepared.estimate.withPDFs : prepared.estimate.notesAndInk
        try checkSpace(archiveBytes, at: temporaryRoot)

        let directory = try makeTemporaryDirectory()
        do {
            let total = Double(max(1, prepared.bytesToHash + archiveBytes))
            let hashShare = Double(prepared.bytesToHash) / total
            job.set(phase: .hashingPDFs)
            let hashed = try await BackupWork.digests(snapshot, progress: job.reporter(from: 0, to: hashShare))

            job.set(phase: .writingBackup)
            let metadata = makeMetadata()
            let name = SnapshotName.make(createdAt: metadata.createdAt, deviceName: metadata.deviceName)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let manifest = try await BackupWork.writeArchive(hashed.sources, metadata: metadata, includePDFs: includePDFs,
                                                             to: url, progress: job.reporter(from: hashShare, to: 1))
            return BackupFileResult(url: url, byteSize: DocumentDigest.regularFileSize(url) ?? 0,
                                    bookCount: manifest.books.count, skippedBookTitles: hashed.skippedTitles)
        } catch {
            await BackupWork.remove(directory)
            throw error
        }
    }

    // MARK: Back up to a destination

    /// Backs up to a folder-like destination: a snapshot without embedded PDFs, plus, with
    /// `includePDFs`, each PDF the destination does not hold yet; then keeps the newest
    /// `SnapshotRetention.defaultKeepCount` snapshots. Progress is weighted by bytes.
    ///
    /// Order, so a cancelled or failed run always leaves the destination consistent: the snapshot
    /// is written locally first (hashing every PDF), then the missing PDFs are uploaded, then the
    /// snapshot. A PDF uploaded without its snapshot is harmless (the next run skips it); a
    /// snapshot never appears before the PDFs it was made with. Records the time of the last
    /// success per destination (`lastSuccessfulBackup(destinationID:)`).
    func backUp(to destination: any BackupDestination, includePDFs: Bool) async throws -> DestinationBackupResult {
        try await run(.backUpToDestination(destination.displayName)) { job in
            try await self.performDestinationBackup(destination, includePDFs: includePDFs, job: job)
        }
    }

    private func performDestinationBackup(_ destination: any BackupDestination, includePDFs: Bool,
                                          job: BackupJob) async throws -> DestinationBackupResult {
        job.set(phase: .preparing)
        if case .unavailable(let reason) = await destination.availability() {
            throw BackupServiceError.destinationUnavailable(reason: reason)
        }
        job.set(phase: .savingOpenBooks)
        await flushEditorsNow()
        let snapshot = try takeSnapshot()

        job.set(phase: .checkingSpace)
        let prepared = try await BackupWork.prepare(snapshot)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try checkSpace(prepared.estimate.notesAndInk, at: temporaryRoot)

        let directory = try makeTemporaryDirectory()
        do {
            job.set(phase: .hashingPDFs)
            let preliminaryTotal = Double(max(1, prepared.bytesToHash + 2 * prepared.estimate.notesAndInk))
            let hashEnd = Double(prepared.bytesToHash) / preliminaryTotal
            let hashed = try await BackupWork.digests(snapshot, progress: job.reporter(from: 0, to: hashEnd))

            // Which PDFs the destination still needs (one per distinct hash).
            var uploads: [(digest: ContentDigest, url: URL)] = []
            var alreadyPresent = 0
            if includePDFs {
                var seen = Set<String>()
                for pdf in hashed.presentPDFs {
                    guard seen.insert(pdf.digest.sha256).inserted else { continue }
                    if try await destination.hasPDF(sha256: pdf.digest.sha256, size: pdf.digest.size) {
                        alreadyPresent += 1
                    } else {
                        uploads.append(pdf)
                    }
                }
            }

            // Byte weights of the remaining steps: write the snapshot, upload PDFs, upload it.
            let archiveBytes = Double(max(1, prepared.estimate.notesAndInk))
            let uploadBytes = Double(uploads.reduce(0) { $0 + $1.digest.size })
            let remaining = archiveBytes + uploadBytes + archiveBytes
            let span = 1 - hashEnd
            let writeEnd = hashEnd + span * archiveBytes / remaining

            job.set(phase: .writingBackup)
            let metadata = makeMetadata()
            let name = SnapshotName.make(createdAt: metadata.createdAt, deviceName: metadata.deviceName)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let manifest = try await BackupWork.writeArchive(hashed.sources, metadata: metadata, includePDFs: false,
                                                             to: url, progress: job.reporter(from: hashEnd, to: writeEnd))

            job.set(phase: .uploadingPDFs)
            var position = writeEnd
            for upload in uploads {
                let end = position + span * Double(upload.digest.size) / remaining
                try await destination.uploadPDF(from: upload.url, sha256: upload.digest.sha256, size: upload.digest.size,
                                                progress: job.reporter(from: position, to: end))
                position = end
            }

            job.set(phase: .uploadingBackup)
            let stored = try await destination.uploadSnapshot(from: url, name: name, progress: job.reporter(from: position, to: 1))
            recordSuccess(destinationID: destination.id, at: Date())

            job.set(phase: .removingOldBackups)
            var deleted = 0
            do {
                let snapshots = try await destination.listSnapshots()
                for old in SnapshotRetention.snapshotsToDelete(snapshots) where old.id != stored.id {
                    try await destination.deleteSnapshot(old)
                    deleted += 1
                }
            } catch is CancellationError {
                // The backup itself succeeded; retention runs again next time.
            } catch {
                backupLog.error("old backups at \(destination.id, privacy: .public) not removed: \(String(describing: error), privacy: .public)")
            }

            job.set(phase: .cleaningUp)
            await BackupWork.remove(directory)
            return DestinationBackupResult(snapshot: stored, bookCount: manifest.books.count, uploadedPDFs: uploads.count,
                                           alreadyPresentPDFs: alreadyPresent, deletedSnapshots: deleted,
                                           skippedBookTitles: hashed.skippedTitles)
        } catch {
            await BackupWork.remove(directory)
            throw error
        }
    }

    /// Saves every open editor's pending text and ink and waits for it.
    func flushEditorsNow() async {
        await flushEditors()
    }
}

// MARK: - File work (off the main actor)

/// The backup's file work. `nonisolated`, entry points `@concurrent`: never on the main actor.
nonisolated enum BackupWork {
    struct Prepared: Sendable {
        var estimate: BackupSizeEstimate
        /// Bytes of PDFs whose hash is not cached yet (read once by `digests`).
        var bytesToHash: Int64
    }

    struct Hashed: Sendable {
        /// What the archive writer gets, in snapshot order.
        var sources: [BackupBookSource]
        /// PDFs on disk with their digests (books whose PDF is present).
        var presentPDFs: [(digest: ContentDigest, url: URL)]
        /// Books with neither a PDF nor a sidecar: left out.
        var skippedTitles: [String]
    }

    /// Per-entry archive overhead (local header, central directory entry, ZIP64 extras, the name)
    /// and per-book manifest bytes, rounded up.
    static let entryOverhead: Int64 = 320
    static let bookManifestOverhead: Int64 = 1024
    static let archiveOverhead: Int64 = 16 * 1024

    /// Size estimate and hashing work, from directory listings and the records' encoded size.
    @concurrent
    static func prepare(_ snapshot: LibrarySnapshot) async throws -> Prepared {
        var notesAndInk = archiveOverhead
        var pdfs: [String: Int64] = [:]
        var bytesToHash: Int64 = 0
        let encoder = BackupCoding.makeEncoder()
        for item in snapshot.items {
            try Task.checkCancellation()
            let book = item.archive.book
            // As the archive writer collects them: recognised text is derived and never backed up.
            let files = bookFiles(in: item.directory,
                                  excluding: BackupDerivedFiles.topLevelNames.union([book.fileName,
                                                                                     BookStorageLayout.contentHashFileName]),
                                  excludingOriginal: book.isConverted)
            notesAndInk += files.reduce(0) { $0 + $1.size + entryOverhead + Int64($1.path.utf8.count) }
            notesAndInk += Int64((try? encoder.encode(item.archive).count) ?? 0) + entryOverhead + bookManifestOverhead
            notesAndInk += Int64(files.count) * 256  // manifest lines
            if let size = DocumentDigest.regularFileSize(item.documentURL) {
                pdfs[book.fingerprint] = size
                if DocumentDigest.readSidecar(at: item.sidecarURL)?.size != size { bytesToHash += size }
            }
        }
        let pdfBytes = pdfs.values.reduce(0) { $0 + $1 + entryOverhead }
        return Prepared(estimate: BackupSizeEstimate(notesAndInk: notesAndInk, withPDFs: notesAndInk + pdfBytes),
                        bytesToHash: bytesToHash)
    }

    /// Every book's PDF digest (sidecar, or computed and cached), as archive sources.
    @concurrent
    static func digests(_ snapshot: LibrarySnapshot, progress: BackupProgress?) async throws -> Hashed {
        var toHash: Int64 = 0
        for item in snapshot.items {
            if let size = DocumentDigest.regularFileSize(item.documentURL),
               DocumentDigest.readSidecar(at: item.sidecarURL)?.size != size { toHash += size }
        }
        var done: Int64 = 0
        var result = Hashed(sources: [], presentPDFs: [], skippedTitles: [])
        progress?(0)
        for item in snapshot.items {
            try Task.checkCancellation()
            let pdfSize = DocumentDigest.regularFileSize(item.documentURL)
            let needsHash = pdfSize != nil && DocumentDigest.readSidecar(at: item.sidecarURL)?.size != pdfSize
            let base = Double(done)
            let size = Double(pdfSize ?? 0)
            let total = Double(toHash)
            var reporter: BackupProgress?
            if needsHash, toHash > 0 {
                reporter = { @Sendable fraction in progress?((base + size * fraction) / total) }
            }
            let digest = try DocumentDigest.digestNow(documentURL: item.documentURL, sidecarURL: item.sidecarURL,
                                                      progress: reporter)
            if needsHash { done += pdfSize ?? 0 }
            guard let digest else {
                result.skippedTitles.append(item.archive.book.title)
                continue
            }
            result.sources.append(BackupBookSource(archive: item.archive, directory: item.directory,
                                                   pdfFileName: item.archive.book.fileName, pdfDigest: .known(digest)))
            if pdfSize != nil { result.presentPDFs.append((digest, item.documentURL)) }
        }
        progress?(1)
        return result
    }

    @concurrent
    static func writeArchive(_ sources: [BackupBookSource], metadata: BackupMetadata, includePDFs: Bool, to url: URL,
                             progress: BackupProgress?) async throws -> BackupManifest {
        try BackupArchiveWriter.write(books: sources, metadata: metadata, includePDFs: includePDFs, to: url, progress: progress)
    }

    @concurrent
    static func openArchive(_ url: URL) async throws -> BackupArchiveReader {
        try BackupArchiveReader(url: url)
    }

    @concurrent
    static func remove(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    /// Regular files under a book's directory, as the archive writer collects them (hidden and
    /// temporary names skipped, symbolic links not followed), excluding top-level `excluding`
    /// and, with `excludingOriginal` (a converted book), its kept original.
    static func bookFiles(in directory: URL, excluding: Set<String>, excludingOriginal: Bool = false) -> [(path: String, size: Int64)] {
        var files: [(String, Int64)] = []
        func walk(_ url: URL, prefix: String) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return }
            for child in children {
                let name = child.lastPathComponent
                let lower = name.lowercased()
                if name.hasPrefix(".") || name.hasSuffix("~") || lower.hasSuffix(".tmp") || lower.hasSuffix(".temp")
                    || lower.hasSuffix(".partial") { continue }
                if prefix.isEmpty, excluding.contains(name) { continue }
                if prefix.isEmpty, excludingOriginal, BookStorageLayout.isOriginalFileName(name) { continue }
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if values.isDirectory == true {
                    walk(child, prefix: path)
                } else if values.isRegularFile == true {
                    files.append((path, Int64(values.fileSize ?? 0)))
                }
            }
        }
        walk(directory, prefix: "")
        return files
    }
}
