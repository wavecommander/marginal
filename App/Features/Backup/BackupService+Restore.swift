import Foundation
import ReaderBackup
import ReaderCore

/// An opened backup, ready for the restore preview: its manifest and the `RestorePlan` built
/// against the local Library (and, for a destination, the PDFs it holds). Keep it while the
/// preview is shown, pass it to `BackupService.restore`, and `close()` it when done (a
/// downloaded snapshot is deleted then; stale ones are removed at the next launch).
@MainActor
final class RestoreSession: Identifiable {
    enum Source: Equatable, Sendable {
        /// A `.ttbackup` file the reader picked.
        case file(URL)
        /// A snapshot at a destination (downloaded to a temporary file).
        case destination(id: String, name: String, snapshot: BackupSnapshotInfo)
    }

    nonisolated let id = UUID()
    let source: Source
    /// The backup's manifest (books, counts, dates, PDF hashes).
    var manifest: BackupManifest { reader.manifest }
    /// The preview: each book New or Already in Library, ticked by default or not, and where its
    /// PDF would come from. Rebuilt by `BackupService.refreshPlan(of:)`.
    private(set) var plan: RestorePlan
    /// For a destination: the manifest's PDF hashes the destination holds (empty for a file).
    let destinationPDFHashes: Set<String>
    private(set) var isClosed = false

    let reader: BackupArchiveReader
    let destination: (any BackupDestination)?
    /// A folder this session owns (a downloaded snapshot), removed on close.
    private let ownedDirectory: URL?
    /// A security-scoped URL to stop accessing on close.
    private let scopedURL: URL?

    init(source: Source, reader: BackupArchiveReader, plan: RestorePlan, destinationPDFHashes: Set<String>,
         destination: (any BackupDestination)?, ownedDirectory: URL?, scopedURL: URL?) {
        self.source = source
        self.reader = reader
        self.plan = plan
        self.destinationPDFHashes = destinationPDFHashes
        self.destination = destination
        self.ownedDirectory = ownedDirectory
        self.scopedURL = scopedURL
    }

    func update(plan: RestorePlan) { self.plan = plan }

    /// Releases the backup (deletes a downloaded copy). Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        scopedURL?.stopAccessingSecurityScopedResource()
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
    }
}

extension BackupService {
    // MARK: Opening a backup

    /// Opens a `.ttbackup` file (from the file importer or "Open in") for restore: validates it
    /// and builds the preview. The file is read in place for as long as the session is open.
    func openBackup(at url: URL) async throws -> RestoreSession {
        try await run(.openBackup) { job in
            job.set(phase: .reading)
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let reader = try await BackupWork.openArchive(url)
                job.set(fraction: 0.5)
                let plan = RestorePlan(manifest: reader.manifest, localLibrary: await self.localSummaries(),
                                       destinationPDFHashes: [])
                return RestoreSession(source: .file(url), reader: reader, plan: plan, destinationPDFHashes: [],
                                      destination: nil, ownedDirectory: nil, scopedURL: scoped ? url : nil)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        }
    }

    /// Downloads a destination's snapshot to a temporary file, validates it and builds the
    /// preview, including which of its PDFs the destination holds.
    func openBackup(_ snapshot: BackupSnapshotInfo, from destination: any BackupDestination) async throws -> RestoreSession {
        try await run(.openBackup) { job in
            job.set(phase: .downloading)
            try FileManager.default.createDirectory(at: self.temporaryRoot, withIntermediateDirectories: true)
            try self.checkSpace(snapshot.byteSize, at: self.temporaryRoot)
            let directory = try self.makeTemporaryDirectory()
            do {
                let file = directory.appendingPathComponent("snapshot.\(BackupFormat.fileExtension)", isDirectory: false)
                try await destination.downloadSnapshot(snapshot, to: file, progress: job.reporter(from: 0, to: 0.8))
                job.set(phase: .reading)
                let reader = try await BackupWork.openArchive(file)
                var held = Set<String>()
                var checked = Set<String>()
                for entry in reader.manifest.books where checked.insert(entry.pdf.sha256).inserted {
                    if try await destination.hasPDF(sha256: entry.pdf.sha256, size: entry.pdf.size) {
                        held.insert(entry.pdf.sha256)
                    }
                }
                let plan = RestorePlan(manifest: reader.manifest, localLibrary: await self.localSummaries(),
                                       destinationPDFHashes: held)
                return RestoreSession(source: .destination(id: destination.id, name: destination.displayName, snapshot: snapshot),
                                      reader: reader, plan: plan, destinationPDFHashes: held, destination: destination,
                                      ownedDirectory: directory, scopedURL: nil)
            } catch {
                await BackupWork.remove(directory)
                throw error
            }
        }
    }

    /// Rebuilds the session's preview against the Library as it is now.
    func refreshPlan(of session: RestoreSession) async {
        let local = await localSummaries()
        session.update(plan: RestorePlan(manifest: session.manifest, localLibrary: local,
                                         destinationPDFHashes: session.destinationPDFHashes))
    }

    /// Every local book as the restore preview needs it: counts, last change, whether its PDF is
    /// on disk, and the sidecar's hash (never computed here).
    func localSummaries() async -> [LocalBookSummary] {
        let books = (try? store.books.allBooks()) ?? []
        var archives: [BookArchive] = []
        for book in books {
            if let archive = try? store.archive(bookID: book.id) { archives.append(archive) }
        }
        let probes = archives.map { ($0.book.id, store.documentURL(for: $0.book), store.contentHashURL(bookID: $0.book.id)) }
        let files = await BackupWork.localFileInfo(probes)
        var summaries: [LocalBookSummary] = []
        for archive in archives {
            let id = archive.book.id
            let inked = (try? await store.inkedPages.pages(bookID: id).count) ?? 0
            let counts = BackupManifest.RecordCounts(notes: archive.notes.count, highlights: archive.highlights.count,
                                                     bookmarks: archive.bookmarks.count,
                                                     userHeadings: archive.userHeadings.count, inkedPages: inked)
            summaries.append(LocalBookSummary(book: archive.book, hasPDF: files[id]?.hasPDF ?? false,
                                              sha256: files[id]?.sha256, counts: counts,
                                              lastModifiedAt: archive.lastModifiedAt))
        }
        return summaries
    }

    // MARK: Restoring

    /// Restores the books `bookIDs` of the session's backup (normally the preview's ticked
    /// items). Each book replaces every local book with the same ID or the same fingerprint
    /// (`RestorePlan.Item.replacedBookIDs`); unselected books, in the backup or the Library, are
    /// untouched.
    ///
    /// Per book: its files and records are extracted into `Restores/<session>/` and verified; its
    /// PDF comes, in order, from the archive (when embedded and `restorePDFs`), from the
    /// destination (when it holds it and `restorePDFs`), from the local book being replaced (when
    /// it has the PDF and the hash matches; whatever `restorePDFs` says, so the PDF on this iPad
    /// is never lost), else the book is restored without it; `document.sha256` is written from
    /// the manifest; notes' `hasInk` follow the ink files present (empty notes dropped); a missing
    /// cover is rendered from the PDF. Then open editors save, and each book is committed
    /// (`RestoreCommit`). One book failing does not undo the others and never leaves that book
    /// half-applied.
    /// - Throws: `BackupServiceError.backupDamaged` when any chosen book's data in the backup is
    ///   damaged (nothing is restored then), `.busy`, `.sessionClosed`, `.notEnoughSpace`,
    ///   `CancellationError` before anything was committed.
    func restore(_ bookIDs: Set<UUID>, from session: RestoreSession, restorePDFs: Bool) async throws -> RestoreSummary {
        try await run(.restore) { job in
            try await self.performRestore(bookIDs, from: session, restorePDFs: restorePDFs, job: job)
        }
    }

    private struct StagedBook {
        var item: RestorePlan.Item
        var output: RestoreStaging.Output
    }

    private func performRestore(_ bookIDs: Set<UUID>, from session: RestoreSession, restorePDFs: Bool,
                                job: BackupJob) async throws -> RestoreSummary {
        guard !session.isClosed else { throw BackupServiceError.sessionClosed }
        if let unknown = bookIDs.first(where: { session.manifest.entry(for: $0) == nil }) {
            throw BackupError.bookNotInBackup(unknown)
        }
        let items = session.plan.items.filter { bookIDs.contains($0.id) }
        var summary = RestoreSummary()
        guard !items.isEmpty else { return summary }

        // Where each PDF comes from (hashing local candidates when their hash is not cached).
        job.set(phase: .hashingPDFs)
        var inputs: [(item: RestorePlan.Item, source: RestoreStaging.PDFSource)] = []
        for item in items {
            inputs.append((item, try await pdfSource(for: item, session: session, restorePDFs: restorePDFs)))
        }

        let sessionDirectory = RestoreLayout.root(storeRoot: store.rootDirectory)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingInputs = inputs.map {
            RestoreStaging.Input(sessionDirectory: sessionDirectory, entry: $0.item.entry, pdfSource: $0.source)
        }
        job.set(phase: .checkingSpace)
        try checkSpace(stagingInputs.reduce(0) { $0 + RestoreStaging.weight(of: $1) }, at: store.rootDirectory)

        var keepSessionFiles = false
        do {
            // Stage every book, verifying everything, before anything changes.
            job.set(phase: .extracting)
            let weights = stagingInputs.map { Double(max(1, RestoreStaging.weight(of: $0))) }
            let totalWeight = weights.reduce(0, +)
            var position = 0.0
            var staged: [StagedBook] = []
            for (index, input) in stagingInputs.enumerated() {
                let start = 0.95 * position / totalWeight
                position += weights[index]
                let end = 0.95 * position / totalWeight
                let item = inputs[index].item
                do {
                    let output = try await RestoreStaging.stage(input, reader: session.reader, destination: session.destination,
                                                                progress: job.reporter(from: start, to: end))
                    staged.append(StagedBook(item: item, output: output))
                } catch RestoreStagingError.damaged(let error) {
                    throw BackupServiceError.backupDamaged(bookTitle: item.entry.book.title, reason: error.localizedDescription)
                } catch RestoreStagingError.pdf(let error) {
                    summary.failures.append(.init(id: item.id, title: item.entry.book.title, message: error.localizedDescription))
                }
            }
            try Task.checkCancellation()

            // Open editors save what is on screen; then the affected books' in-flight saves
            // finish and new ones wait, so no stale write can straddle a commit.
            job.set(phase: .savingOpenBooks)
            await flushEditorsNow()
            try Task.checkCancellation()
            job.set(phase: .committing)
            var affected = Set<UUID>()
            for book in staged {
                affected.insert(book.item.id)
                affected.formUnion(currentMatches(for: book.item.entry.book))
                affected.formUnion(book.item.replacedBookIDs)
            }
            let pause = await BookWriteGate.shared.pause(affected)
            defer { BookWriteGate.shared.resume(pause) }

            // From here to the end of the loop: no suspension point.
            commits: for book in staged {
                let entryBook = book.item.entry.book
                let current = currentMatches(for: entryBook)
                guard Set(current).isSubset(of: Set(book.item.replacedBookIDs)) else {
                    summary.failures.append(.init(id: entryBook.id, title: entryBook.title,
                                                  message: BackupServiceError.libraryChanged(bookTitle: entryBook.title).localizedDescription))
                    continue
                }
                var localPDF: RestoreJournal.LocalPDF?
                if case .replacedLocalBook(let planned, _) = book.output.pdfSource, current.contains(planned.bookID),
                   let local = try? store.books.book(id: planned.bookID) {
                    localPDF = RestoreJournal.LocalPDF(bookID: local.id, fileName: local.fileName)
                }
                let plan = RestoreCommit.Plan(sessionDirectory: sessionDirectory, archive: book.output.archive,
                                              replacedBookIDs: Set(current), localPDF: localPDF)
                do {
                    let outcome = try RestoreCommit.perform(plan, store: store, origin: origin, stopAfter: stopCommitAfter)
                    if case .stopped = outcome {
                        keepSessionFiles = true
                        break commits
                    }
                    for id in Set(current).union([entryBook.id]) {
                        CoverCache.shared.remove(at: store.url(forRelativePath: ImportService.coverRelativePath(bookID: id)))
                    }
                    summary.restored.append(.init(id: entryBook.id, title: entryBook.title,
                                                  hasPDF: store.hasDocument(entryBook)))
                    summary.droppedEmptyNotes += book.output.droppedEmptyNotes
                } catch {
                    summary.failures.append(.init(id: entryBook.id, title: entryBook.title,
                                                  message: "“\(entryBook.title)” couldn’t be restored (\(error.localizedDescription)). It is unchanged."))
                }
            }
        } catch {
            await BackupWork.remove(sessionDirectory)
            throw error
        }
        job.set(phase: .cleaningUp)
        if !keepSessionFiles { await BackupWork.remove(sessionDirectory) }
        return summary
    }

    /// Local books a restore of `book` replaces now: the one with its ID and the one with its
    /// fingerprint (the Library holds one book per fingerprint).
    func currentMatches(for book: Book) -> [UUID] {
        var ids: [UUID] = []
        if let byID = try? store.books.book(id: book.id) { ids.append(byID.id) }
        if let byPrint = try? store.books.book(fingerprint: book.fingerprint), !ids.contains(byPrint.id) {
            ids.append(byPrint.id)
        }
        return ids
    }

    /// The first available PDF source in the plan's order (see `restore`).
    private func pdfSource(for item: RestorePlan.Item, session: RestoreSession, restorePDFs: Bool) async throws
        -> RestoreStaging.PDFSource {
        let entry = item.entry
        let expected = entry.pdf.digest
        if restorePDFs, entry.pdf.embedded, session.reader.embeddedPDFHashes.contains(expected.sha256) { return .embedded }
        if restorePDFs, session.destination != nil, session.destinationPDFHashes.contains(expected.sha256) { return .destination }
        let replaced = currentMatches(for: entry.book)
        for id in replaced {
            guard let local = try store.books.book(id: id), store.hasDocument(local) else { continue }
            if try await store.contentDigest(of: local) == expected {
                return .replacedLocalBook(RestoreJournal.LocalPDF(bookID: local.id, fileName: local.fileName),
                                          documentURL: store.documentURL(for: local))
            }
        }
        if case .localBook(let id) = item.pdfSource, !replaced.contains(id),
           let local = try store.books.book(id: id), store.hasDocument(local),
           try await store.contentDigest(of: local) == expected {
            return .copy(from: store.documentURL(for: local))
        }
        return .none
    }
}

extension BackupWork {
    /// Whether each book's PDF is on disk, and its sidecar hash.
    @concurrent
    static func localFileInfo(_ probes: [(UUID, URL, URL)]) async -> [UUID: (hasPDF: Bool, sha256: String?)] {
        var result: [UUID: (hasPDF: Bool, sha256: String?)] = [:]
        for (id, document, sidecar) in probes {
            result[id] = (FileManager.default.fileExists(atPath: document.path), DocumentDigest.readSidecar(at: sidecar)?.sha256)
        }
        return result
    }
}
