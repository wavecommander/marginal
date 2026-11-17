import Foundation
import ReaderBackup
import ReaderCore

// A restore that changes a book already in the Library keeps a **safety copy** of that book
// first (its records and ink, no PDF), so the restore can be undone:
//
//     <store root>/RestoreSafety/<id>/books.ttbackup   the changed books, as they were
//     <store root>/RestoreSafety/<id>/record.json      what the restore changed and added
//     <store root>/RestoreSafety/<id>/records-<bookID>.json  a merged book's records at its commit,
//                                                      when they had changed since the copy (see
//                                                      `RestoreSafetyCopy.amend`)
//
// `BackupService.undoLastRestore()` puts the changed books back from the newest copy and removes
// the books that restore had added. The newest `RestoreSafetyStore.keepCount` copies are kept.

// MARK: - Record

/// What one restore did to the Library, kept beside its safety copy.
nonisolated struct RestoreSafetyRecord: Codable, Equatable, Sendable, Identifiable {
    /// A book that was in the Library before the restore and is in the safety copy.
    struct ChangedBook: Codable, Equatable, Sendable {
        /// The book's ID before the restore (its ID in `books.ttbackup`).
        var previousID: UUID
        var title: String
        /// The ID of the book the restore put in its place (the same ID after a merge, or after
        /// a replace by a backup of the same book). `nil`: saved as a precaution, but the restore
        /// did not change it after all; an undo leaves it alone.
        var currentID: UUID?
        /// `false` when the book had neither a PDF nor a recorded hash: the archive then holds a
        /// placeholder hash for it, which an undo must not leave behind as the book's sidecar.
        var hasKnownPDFHash: Bool
    }

    /// A book the restore added to the Library (it was not there before).
    struct AddedBook: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
    }

    static let currentVersion = 1

    var version = RestoreSafetyRecord.currentVersion
    /// Also the name of the safety copy's directory.
    var id: UUID
    /// When the restore ran.
    var createdAt: Date
    /// The backup the restore read, for display ("2026-11-15… iPad.ttbackup", "My Backups: …").
    var sourceName: String
    var changed: [ChangedBook]
    var added: [AddedBook]

    /// The books the restore actually changed.
    var changedBooks: [ChangedBook] { changed.filter { $0.currentID != nil } }
    /// `true` when the restore changed and added nothing: there is nothing to undo.
    var isEmpty: Bool { changedBooks.isEmpty && added.isEmpty }
}

// MARK: - Files

/// The safety copies on disk. File work only; `nonisolated`.
nonisolated enum RestoreSafetyStore {
    static let directoryName = "RestoreSafety"
    static let recordFileName = "record.json"
    static let archiveFileName = "books.\(BackupFormat.fileExtension)"
    /// Safety copies kept (the newest ones).
    static let keepCount = 5

    /// `<storeRoot>/RestoreSafety`
    static func root(storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func directory(id: UUID, storeRoot: URL) -> URL {
        root(storeRoot: storeRoot).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func recordURL(id: UUID, storeRoot: URL) -> URL {
        directory(id: id, storeRoot: storeRoot).appendingPathComponent(recordFileName, isDirectory: false)
    }

    static func archiveURL(id: UUID, storeRoot: URL) -> URL {
        directory(id: id, storeRoot: storeRoot).appendingPathComponent(archiveFileName, isDirectory: false)
    }

    /// `<id>/records-<bookID>.json`: the records an undo puts back for a merged book instead of
    /// the archive's (`RestoreSafetyCopy.amend`).
    static func amendmentURL(id: UUID, bookID: UUID, storeRoot: URL) -> URL {
        directory(id: id, storeRoot: storeRoot).appendingPathComponent("records-\(bookID.uuidString).json", isDirectory: false)
    }

    /// Writes an amendment durably (`BackupCoding`, like `records.json`).
    static func writeAmendment(_ archive: BookArchive, id: UUID, storeRoot: URL) throws {
        try RestoreDurability.writeDurably(try BackupCoding.makeEncoder().encode(archive),
                                           to: amendmentURL(id: id, bookID: archive.book.id, storeRoot: storeRoot))
    }

    /// The amendment for `bookID`, or `nil` when there is none (or it cannot be read; the
    /// archive's records are then used).
    static func amendment(id: UUID, bookID: UUID, storeRoot: URL) -> BookArchive? {
        guard let data = try? Data(contentsOf: amendmentURL(id: id, bookID: bookID, storeRoot: storeRoot)),
              let archive = try? BackupCoding.makeDecoder().decode(BookArchive.self, from: data),
              archive.book.id == bookID, archive.isConsistent else { return nil }
        return archive
    }

    /// Every readable record, newest first. A directory without a readable record (a copy that
    /// was being written when the app stopped) is not listed.
    static func records(storeRoot: URL) -> [RestoreSafetyRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root(storeRoot: storeRoot).path)) ?? []
        var records: [RestoreSafetyRecord] = []
        for name in names {
            guard let id = UUID(uuidString: name), let record = read(id: id, storeRoot: storeRoot) else { continue }
            records.append(record)
        }
        return records.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString > $1.id.uuidString
        }
    }

    /// The newest restore that changed or added something.
    static func latest(storeRoot: URL) -> RestoreSafetyRecord? {
        records(storeRoot: storeRoot).first { !$0.isEmpty }
    }

    static func read(id: UUID, storeRoot: URL) -> RestoreSafetyRecord? {
        guard let data = try? Data(contentsOf: recordURL(id: id, storeRoot: storeRoot)),
              let record = try? BackupCoding.makeDecoder().decode(RestoreSafetyRecord.self, from: data),
              record.version <= RestoreSafetyRecord.currentVersion, record.id == id else { return nil }
        return record
    }

    /// Writes the record durably (the undo depends on it surviving a crash).
    static func write(_ record: RestoreSafetyRecord, storeRoot: URL) throws {
        try RestoreDurability.writeDurably(try BackupCoding.makeEncoder().encode(record),
                                           to: recordURL(id: record.id, storeRoot: storeRoot))
    }

    static func remove(id: UUID, storeRoot: URL) {
        try? FileManager.default.removeItem(at: directory(id: id, storeRoot: storeRoot))
    }

    /// Removes all but the newest `keeping` copies.
    static func prune(storeRoot: URL, keeping: Int = keepCount) {
        for record in records(storeRoot: storeRoot).dropFirst(max(1, keeping)) {
            remove(id: record.id, storeRoot: storeRoot)
        }
    }

    /// Removes what an interrupted restore left: directories with no readable record, and
    /// records of restores that changed nothing. Called at launch, before any job.
    static func removeStale(storeRoot: URL) {
        let base = root(storeRoot: storeRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names {
            let url = base.appendingPathComponent(name, isDirectory: true)
            if let id = UUID(uuidString: name), let record = read(id: id, storeRoot: storeRoot), !record.isEmpty { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - The copy of a restore in progress

/// The safety copy of the restore that is running: made after open editors have saved and the
/// affected books are paused, before the first commit. It then tracks, durably, which books the
/// restore changed and which it added.
@MainActor
final class RestoreSafetyCopy {
    private(set) var record: RestoreSafetyRecord
    private let storeRoot: URL
    /// The protected books' records as they were saved (`comparable`), to refuse a commit over a
    /// book that changed after its safety copy was written. A merged book's entry follows its
    /// amendment (`amend`).
    private var saved: [UUID: BookArchive]

    init(record: RestoreSafetyRecord, storeRoot: URL, saved: [UUID: BookArchive]) {
        self.record = record
        self.storeRoot = storeRoot
        self.saved = saved
    }

    /// The records in a form that compares equal for the same stored state: lists sorted by ID,
    /// and without the reading position, which a reader window saves at any moment (a slightly
    /// stale reading position in the safety copy is harmless; a missed note is not).
    nonisolated static func comparable(_ archive: BookArchive) -> BookArchive {
        var archive = archive
        archive.book.lastReadPageIndex = 0
        archive.book.lastOpenedAt = nil
        archive.notes.sort { $0.id.uuidString < $1.id.uuidString }
        archive.highlights.sort { $0.id.uuidString < $1.id.uuidString }
        archive.bookmarks.sort { $0.id.uuidString < $1.id.uuidString }
        archive.userHeadings.sort { $0.id.uuidString < $1.id.uuidString }
        return archive
    }

    /// Whether the local book still holds exactly the records its safety copy holds (`true` for
    /// a book that is not protected, such as one that did not exist).
    func isUnchanged(_ bookID: UUID, store: LibraryStore) -> Bool {
        guard let saved = saved[bookID] else { return (try? store.books.book(id: bookID)) == nil }
        guard let now = try? store.archive(bookID: bookID) else { return false }
        return Self.comparable(now) == saved
    }

    /// For a book about to be **merged**: whether `now` (its records at commit time) differs from
    /// the saved records only in highlights, bookmarks and reader-made headings, which the
    /// reader saves at once and which a merge's commit takes in (`BookMergeEngine`). Its book
    /// record (reading position aside) and its notes must be as saved; its ink is paused.
    func differsOnlyInMergeableRecords(_ now: BookArchive) -> Bool {
        guard let saved = saved[now.book.id] else { return false }
        let current = Self.comparable(now)
        return current.book == saved.book && current.notes == saved.notes
    }

    /// Records `now` beside the copy as the records an undo puts back for this book instead of
    /// the archive's, durably, and compares the book against them from now on. Only for a merged
    /// book that `differsOnlyInMergeableRecords`: its notes are the archive's, so the archive's
    /// ink still belongs to them. Without this an undo would lose a highlight, bookmark or
    /// heading saved after the copy was made, which the merge itself keeps.
    func amend(_ now: BookArchive) throws {
        try RestoreSafetyStore.writeAmendment(now, id: record.id, storeRoot: storeRoot)
        saved[now.book.id] = Self.comparable(now)
    }

    /// Call just before committing `book` over the local books `previous` (empty: a new book).
    /// Recorded first, so a commit finished by crash recovery is still known to the undo.
    func willCommit(_ book: Book, replacing previous: [UUID]) {
        if previous.isEmpty {
            if !record.added.contains(where: { $0.id == book.id }) {
                record.added.append(.init(id: book.id, title: book.title))
            }
        } else {
            for index in record.changed.indices where previous.contains(record.changed[index].previousID) {
                record.changed[index].currentID = book.id
            }
        }
        persist()
    }

    /// The commit of `book` failed and was rolled back: it changed nothing.
    func commitFailed(_ book: Book, replacing previous: [UUID]) {
        if previous.isEmpty {
            record.added.removeAll { $0.id == book.id }
        } else {
            for index in record.changed.indices where previous.contains(record.changed[index].previousID) {
                record.changed[index].currentID = nil
            }
        }
        persist()
    }

    /// The restore is over: a copy of a restore that changed nothing is removed; otherwise old
    /// copies are pruned.
    func finish() {
        if record.isEmpty {
            RestoreSafetyStore.remove(id: record.id, storeRoot: storeRoot)
        } else {
            persist()
            RestoreSafetyStore.prune(storeRoot: storeRoot)
        }
    }

    private func persist() {
        do {
            try RestoreSafetyStore.write(record, storeRoot: storeRoot)
        } catch {
            backupLog.error("restore safety record not written: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Making the copy

extension BackupService {
    /// Saves the local books `bookIDs` (those that exist) as they are now, before a restore
    /// changes them. Call after `flushEditorsNow()` and the `BookWriteGate` pause, so their ink
    /// is not changing. Records are read in one main-actor pass; the archive is written and read
    /// back off the main actor.
    ///
    /// Any book a restore is about to change can be passed: a replaced book and a merged one are
    /// protected the same way.
    /// - Throws: `BackupServiceError.safetyCopyFailed` (the caller must then change nothing),
    ///   `.notEnoughSpace`, `CancellationError`.
    func makeSafetyCopy(protecting bookIDs: Set<UUID>, sourceName: String) async throws -> RestoreSafetyCopy {
        let id = UUID()
        let storeRoot = store.rootDirectory
        let directory = RestoreSafetyStore.directory(id: id, storeRoot: storeRoot)
        do {
            try beforeSafetyCopy?()
            var items: [LibrarySnapshot.Item] = []
            for bookID in bookIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let archive = try store.archive(bookID: bookID) else { continue }
                items.append(LibrarySnapshot.Item(archive: archive, directory: store.bookDirectoryURL(bookID: bookID),
                                                  documentURL: store.documentURL(for: archive.book),
                                                  sidecarURL: store.contentHashURL(bookID: bookID)))
            }
            var record = RestoreSafetyRecord(id: id, createdAt: Date(), sourceName: sourceName, changed: [], added: [])
            var saved: [UUID: BookArchive] = [:]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !items.isEmpty {
                let snapshot = LibrarySnapshot(items: items)
                try checkSpace(try await BackupWork.prepare(snapshot).estimate.notesAndInk, at: storeRoot)
                let unknownHashes = try await BackupWork.writeSafetyArchive(
                    snapshot, metadata: makeMetadata(), to: RestoreSafetyStore.archiveURL(id: id, storeRoot: storeRoot))
                for item in items {
                    let book = item.archive.book
                    saved[book.id] = RestoreSafetyCopy.comparable(item.archive)
                    record.changed.append(.init(previousID: book.id, title: book.title, currentID: nil,
                                                hasKnownPDFHash: !unknownHashes.contains(book.id)))
                }
            }
            try RestoreSafetyStore.write(record, storeRoot: storeRoot)
            return RestoreSafetyCopy(record: record, storeRoot: storeRoot, saved: saved)
        } catch is CancellationError {
            await BackupWork.remove(directory)
            throw CancellationError()
        } catch let error as BackupServiceError {
            await BackupWork.remove(directory)
            if case .notEnoughSpace = error { throw error }
            throw BackupServiceError.safetyCopyFailed(reason: error.localizedDescription)
        } catch {
            await BackupWork.remove(directory)
            throw BackupServiceError.safetyCopyFailed(reason: error.localizedDescription)
        }
    }
}

nonisolated extension BackupWork {
    /// The hash recorded for a book that has neither a PDF nor a recorded hash (the archive
    /// format needs one per book): the SHA-256 of no bytes.
    static let placeholderDigest = ContentDigest(sha256: ContentHash.sha256(of: Data()), size: 0)

    /// Writes the safety archive (records, ink and covers; never PDFs), syncs it to disk, and
    /// reads it back to check that it holds every book.
    /// - Returns: the books whose PDF hash is the placeholder.
    @concurrent
    static func writeSafetyArchive(_ snapshot: LibrarySnapshot, metadata: BackupMetadata, to url: URL) async throws -> Set<UUID> {
        var sources: [BackupBookSource] = []
        var unknown = Set<UUID>()
        for item in snapshot.items {
            try Task.checkCancellation()
            let digest = try DocumentDigest.digestNow(documentURL: item.documentURL, sidecarURL: item.sidecarURL)
            if digest == nil { unknown.insert(item.archive.book.id) }
            sources.append(BackupBookSource(archive: item.archive, directory: item.directory,
                                            pdfFileName: item.archive.book.fileName,
                                            pdfDigest: .known(digest ?? placeholderDigest)))
        }
        try BackupArchiveWriter.write(books: sources, metadata: metadata, includePDFs: false, to: url, progress: nil)
        try RestoreDurability.syncFile(url)
        RestoreDurability.syncDirectory(url.deletingLastPathComponent())
        let reader = try BackupArchiveReader(url: url)
        for item in snapshot.items {
            _ = try reader.bookArchive(for: item.archive.book.id)
        }
        return unknown
    }
}

// MARK: - Undo

extension BackupService {
    /// The newest restore that can be undone (what it changed and added, when, and from which
    /// backup), or `nil`.
    func latestRestoreSafetyRecord() -> RestoreSafetyRecord? {
        RestoreSafetyStore.latest(storeRoot: store.rootDirectory)
    }

    /// Undoes the newest restore: every book it changed is put back as it was (records and ink
    /// from the safety copy, through the same journalled commit as a restore), and every book it
    /// added is deleted, records and files.
    ///
    /// - A changed book keeps the PDF that is on the iPad when it is the PDF the book had (same
    ///   full hash); otherwise it comes back without one ("PDF missing").
    /// - A changed book the reader has since deleted is put back anyway.
    /// - Work done on those books after the restore is lost (the UI says so before asking).
    /// - No safety copy is made of the undo itself. When every book is done the undone restore's
    ///   safety copy is removed, so the next undo is of the restore before it.
    /// - Returns: the books put back (`restored`), the books removed (`removed`) and failures; a
    ///   safety copy with failures is kept, and undoing again finishes the rest.
    /// - Throws: `BackupServiceError.nothingToUndo`, `.busy`, `.notEnoughSpace`,
    ///   `.backupDamaged` (the safety copy is damaged; nothing changed), `CancellationError`.
    func undoLastRestore() async throws -> RestoreSummary {
        try await run(.undoRestore) { job in
            try await self.performUndo(job: job)
        }
    }

    private func performUndo(job: BackupJob) async throws -> RestoreSummary {
        let storeRoot = store.rootDirectory
        guard let record = RestoreSafetyStore.latest(storeRoot: storeRoot) else { throw BackupServiceError.nothingToUndo }
        var summary = RestoreSummary()
        var everyBookPutBack = true

        let changed = record.changedBooks
        if !changed.isEmpty {
            job.set(phase: .reading)
            let url = RestoreSafetyStore.archiveURL(id: record.id, storeRoot: storeRoot)
            let reader: BackupArchiveReader
            do {
                reader = try await BackupWork.openArchive(url)
            } catch {
                throw BackupServiceError.backupDamaged(bookTitle: changed[0].title, reason: error.localizedDescription)
            }
            let held = Set(reader.manifest.books.map(\.book.id))
            let wanted = Set(changed.map(\.previousID)).intersection(held)
            let plan = RestorePlan(manifest: reader.manifest, localLibrary: await localSummaries(), destinationPDFHashes: [])
            let session = RestoreSession(source: .file(url), reader: reader, plan: plan, destinationPDFHashes: [],
                                         destination: nil, ownedDirectory: nil, scopedURL: nil)
            // A merged book whose highlights, bookmarks or headings changed during the merge
            // comes back with the records it had at the merge's commit.
            var amended: [UUID: BookArchive] = [:]
            for id in wanted {
                amended[id] = RestoreSafetyStore.amendment(id: record.id, bookID: id, storeRoot: storeRoot)
            }
            summary = try await performRestore(Dictionary(uniqueKeysWithValues: wanted.map { ($0, RestoreAction.replace) }),
                                               from: session, restorePDFs: false, job: job, safety: .none,
                                               recordOverrides: amended)

            // A book that had no PDF and no recorded hash must not keep the archive's placeholder
            // hash as its sidecar: that would refuse every PDF linked to it later.
            let putBack = Set(summary.restored.map(\.id))
            everyBookPutBack = putBack == Set(changed.map(\.previousID))
            for book in changed where !book.hasKnownPDFHash && putBack.contains(book.previousID) {
                let sidecar = store.contentHashURL(bookID: book.previousID)
                if DocumentDigest.readSidecar(at: sidecar) == BackupWork.placeholderDigest {
                    try? FileManager.default.removeItem(at: sidecar)
                }
            }
        }

        job.set(phase: .cleaningUp)
        for added in record.added {
            guard let book = try? store.books.book(id: added.id) else { continue }
            do {
                try await store.deleteBook(id: book.id, origin: origin)
                summary.removed.append(.init(id: book.id, title: book.title, hasPDF: false))
            } catch LibraryStoreError.bookFilesNotRemoved {
                // The book is gone; its leftover files are removed by the next launch's sweep.
                summary.removed.append(.init(id: book.id, title: book.title, hasPDF: false))
            } catch {
                summary.failures.append(.init(id: book.id, title: book.title,
                                              message: "“\(book.title)” couldn’t be removed (\(error.localizedDescription))."))
            }
            CoverCache.shared.remove(at: store.url(forRelativePath: ImportService.coverRelativePath(bookID: book.id)))
        }

        // The safety copy goes only when every book is back and every added book is gone: until
        // then it is what a second undo (after a failure, or a crash mid-way) finishes from.
        if summary.failures.isEmpty, everyBookPutBack {
            RestoreSafetyStore.remove(id: record.id, storeRoot: storeRoot)
        }
        return summary
    }
}
