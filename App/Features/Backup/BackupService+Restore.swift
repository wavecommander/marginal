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

    /// The backup's name for display (a safety copy records which backup a restore read).
    var sourceName: String {
        switch source {
        case .file(let url): url.lastPathComponent
        case .destination(_, let name, let snapshot): "\(name): \(snapshot.name)"
        }
    }

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
    /// on disk, and the sidecar's hash. The hash is not computed here, except for a converted
    /// book that has none yet: the preview must know whether its PDF is the backup's
    /// (`RestorePlan.Item.hasDifferentConversion`), and only the full hash says so.
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
            var sha256 = files[id]?.sha256
            if sha256 == nil, archive.book.isConverted, files[id]?.hasPDF == true {
                sha256 = (try? await store.contentDigest(of: archive.book))?.sha256
            }
            summaries.append(LocalBookSummary(book: archive.book, hasPDF: files[id]?.hasPDF ?? false,
                                              sha256: sha256, counts: counts,
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
        try await restore(Dictionary(uniqueKeysWithValues: bookIDs.map { ($0, RestoreAction.replace) }),
                          from: session, restorePDFs: restorePDFs)
    }

    /// Restores the books of `actions` (the backed-up book's ID → what to do with it; books not
    /// listed are untouched), as `restore(_:from:restorePDFs:)` describes, except:
    /// - `.merge` on a book already in the Library merges the backup's copy into the local book
    ///   (`BookMergeEngine`): the local book keeps its ID, PDF, cover, hash sidecar and reading
    ///   position and every record and stroke it has, and gains what the backup has. It is in the
    ///   restore's safety copy like a replaced book, and committed through the same journalled
    ///   commit. The local PDF stays; when the local book has none, the backup's is taken (from
    ///   the archive or the destination, with `restorePDFs`) unless the local book records
    ///   another PDF hash. `RestoreSummary.merged` says what each merge added and combined, and
    ///   which ink could not be read and was kept as it was. A book whose notes change while
    ///   its merge is prepared fails with `libraryChanged` and is left as it was.
    /// - `.merge` on a book that is not in the Library restores it as a new book.
    /// - `.restore` and `.replace` do what `restore(_:from:restorePDFs:)` does: a new book is
    ///   added, a book in the Library is replaced.
    func restore(_ actions: [UUID: RestoreAction], from session: RestoreSession, restorePDFs: Bool) async throws -> RestoreSummary {
        try await run(.restore) { job in
            try await self.performRestore(actions, from: session, restorePDFs: restorePDFs, job: job)
        }
    }

    private struct StagedBook {
        var item: RestorePlan.Item
        var output: RestoreStaging.Output
        /// The local book the backup's copy is merged into; `nil` for a restore or replace.
        var mergeTarget: UUID?
    }

    /// Whether a restore first keeps a safety copy of the local books it changes
    /// (`RestoreSafetyCopy`). An undo, which restores *from* a safety copy, makes none.
    enum RestoreSafetyMode: Sendable {
        case protect
        case none
    }

    /// - Parameter recordOverrides: records to restore instead of the backup's, by book ID (an
    ///   undo passes the records a merge amended its safety copy with).
    func performRestore(_ actions: [UUID: RestoreAction], from session: RestoreSession, restorePDFs: Bool,
                        job: BackupJob, safety: RestoreSafetyMode = .protect,
                        recordOverrides: [UUID: BookArchive] = [:]) async throws -> RestoreSummary {
        guard !session.isClosed else { throw BackupServiceError.sessionClosed }
        if let unknown = actions.keys.sorted(by: { $0.uuidString < $1.uuidString })
            .first(where: { session.manifest.entry(for: $0) == nil }) {
            throw BackupError.bookNotInBackup(unknown)
        }
        let items = session.plan.items.filter { actions[$0.id] != nil }
        var summary = RestoreSummary()
        guard !items.isEmpty else { return summary }

        // Where each PDF comes from (hashing local candidates when their hash is not cached),
        // and which local book each merge goes into.
        job.set(phase: .hashingPDFs)
        var inputs: [(item: RestorePlan.Item, source: RestoreStaging.PDFSource, mergeTarget: UUID?)] = []
        var mergeBytes: Int64 = 0
        for item in items {
            if actions[item.id] == .merge, let target = Self.mergeTargetID(for: item) {
                inputs.append((item, try mergePDFSource(for: item, target: target, session: session, restorePDFs: restorePDFs),
                               target))
                if let local = try store.books.book(id: target) {
                    mergeBytes += await MergeFiles.bookFilesSize(store.bookDirectoryURL(bookID: target), pdfFileName: local.fileName)
                }
            } else {
                inputs.append((item, try await pdfSource(for: item, session: session, restorePDFs: restorePDFs), nil))
            }
        }

        let sessionDirectory = RestoreLayout.root(storeRoot: store.rootDirectory)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingInputs = inputs.map {
            RestoreStaging.Input(sessionDirectory: sessionDirectory, entry: $0.item.entry, pdfSource: $0.source,
                                 records: recordOverrides[$0.item.id])
        }
        job.set(phase: .checkingSpace)
        try checkSpace(stagingInputs.reduce(mergeBytes) { $0 + RestoreStaging.weight(of: $1) }, at: store.rootDirectory)

        var keepSessionFiles = false
        var safetyCopy: RestoreSafetyCopy?
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
                let mergeTarget = inputs[index].mergeTarget
                do {
                    let output = try await RestoreStaging.stage(input, reader: session.reader, destination: session.destination,
                                                                progress: job.reporter(from: start, to: end))
                    if mergeTarget != nil {
                        // The merged directory is built at `staged/<localID>` later; the backup's
                        // copy waits beside it.
                        do {
                            _ = try await MergeFiles.setIncomingAside(session: sessionDirectory, bookID: item.id)
                        } catch {
                            summary.failures.append(.init(id: item.id, title: item.entry.book.title,
                                                          message: "“\(item.entry.book.title)” couldn’t be merged (\(error.localizedDescription)). It is unchanged."))
                            continue
                        }
                    }
                    staged.append(StagedBook(item: item, output: output, mergeTarget: mergeTarget))
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

            // The local books about to be changed are saved first, so the restore can be undone.
            // Their ink is paused, so the copy is exactly what the commit replaces; if this
            // fails, the restore stops here with nothing changed.
            if safety == .protect, !staged.isEmpty {
                job.set(phase: .savingSafetyCopy)
                var protected = Set<UUID>()
                for book in staged { protected.formUnion(currentMatches(for: book.item.entry.book)) }
                safetyCopy = try await makeSafetyCopy(protecting: protected, sourceName: session.sourceName)
                try Task.checkCancellation()
                job.set(phase: .committing)
            }

            // Merged books are built now, from the local books as the safety copy holds them
            // (their notes and ink are paused; what else changes meanwhile is taken in at commit).
            var prepared: [UUID: PreparedMerge] = [:]
            if staged.contains(where: { $0.mergeTarget != nil }) {
                job.set(phase: .merging)
                for book in staged {
                    guard let target = book.mergeTarget else { continue }
                    do {
                        prepared[book.item.id] = try await prepareMerge(of: book.item, staged: book.output, into: target,
                                                                        sessionDirectory: sessionDirectory)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as BackupServiceError {
                        summary.failures.append(.init(id: book.item.id, title: book.item.entry.book.title,
                                                      message: error.localizedDescription))
                    } catch {
                        summary.failures.append(.init(id: book.item.id, title: book.item.entry.book.title,
                                                      message: "“\(book.item.entry.book.title)” couldn’t be merged (\(error.localizedDescription)). It is unchanged."))
                    }
                }
                try Task.checkCancellation()
                beforeMergeCommit?()
                job.set(phase: .committing)
            }

            // From here to the end of the loop: no suspension point.
            commits: for book in staged {
                if book.mergeTarget != nil {
                    guard let merge = prepared[book.item.id] else { continue }
                    switch commitMerge(merge, sessionDirectory: sessionDirectory, safetyCopy: safetyCopy, summary: &summary) {
                    case .committed, .failed:
                        continue
                    case .stopped:
                        keepSessionFiles = true
                        break commits
                    }
                }
                let entryBook = book.item.entry.book
                let current = currentMatches(for: entryBook)
                guard Set(current).isSubset(of: Set(book.item.replacedBookIDs)) else {
                    summary.failures.append(.init(id: entryBook.id, title: entryBook.title,
                                                  message: BackupServiceError.libraryChanged(bookTitle: entryBook.title).localizedDescription))
                    continue
                }
                // A book whose records changed after its safety copy was written is left alone:
                // only what the copy holds may be replaced.
                if let safetyCopy, !current.allSatisfy({ safetyCopy.isUnchanged($0, store: store) }) {
                    summary.failures.append(.init(id: entryBook.id, title: entryBook.title,
                                                  message: BackupServiceError.libraryChanged(bookTitle: entryBook.title).localizedDescription))
                    continue
                }
                var localPDF: RestoreJournal.LocalPDF?
                if case .replacedLocalBook(let planned, _) = book.output.pdfSource, current.contains(planned.bookID),
                   let local = try? store.books.book(id: planned.bookID) {
                    localPDF = RestoreJournal.LocalPDF(bookID: local.id, fileName: local.fileName)
                }
                let localOriginal = RestoreCommit.keptOriginal(for: book.output.archive.book, sessionDirectory: sessionDirectory,
                                                               replacing: current, store: store)
                let plan = RestoreCommit.Plan(sessionDirectory: sessionDirectory, archive: book.output.archive,
                                              replacedBookIDs: Set(current), localPDF: localPDF, localOriginal: localOriginal)
                safetyCopy?.willCommit(entryBook, replacing: current)
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
                    safetyCopy?.commitFailed(entryBook, replacing: current)
                    summary.failures.append(.init(id: entryBook.id, title: entryBook.title,
                                                  message: "“\(entryBook.title)” couldn’t be restored (\(error.localizedDescription)). It is unchanged."))
                }
            }
        } catch {
            // Nothing was committed (the loop above does not throw): no safety copy is kept.
            safetyCopy?.finish()
            await BackupWork.remove(sessionDirectory)
            throw error
        }
        safetyCopy?.finish()
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
