import Darwin
import Foundation
import OSLog
import ReaderBackup
import ReaderCore

let backupLog = Logger(subsystem: "software.tactile.marginal", category: "Backup")

// MARK: - Layout

/// Where a restore keeps its work, under the store's root (outside `Books/`, so the launch-time
/// orphan sweep never sees it):
///
///     Restores/<session>/staged/<bookID>/               the book's directory, extracted and verified
///     Restores/<session>/commit-<bookID>/archive.json   the book's records (`BookArchive`), as restored
///     Restores/<session>/commit-<bookID>/journal.json   present while the book's commit is in progress
///     Restores/<session>/commit-<bookID>/aside/<oldID>/ replaced `Books/<oldID>` directories, set aside
nonisolated enum RestoreLayout {
    static let directoryName = "Restores"
    static let stagedDirectoryName = "staged"
    static let journalFileName = "journal.json"
    static let archiveFileName = "archive.json"
    static let asideDirectoryName = "aside"

    /// `<storeRoot>/Restores`
    static func root(storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `staged/<bookID>`, relative to the session directory.
    static func stagedRelativePath(bookID: UUID) -> String {
        "\(stagedDirectoryName)/\(bookID.uuidString)"
    }

    /// `commit-<bookID>`
    static func commitDirectoryName(bookID: UUID) -> String {
        "commit-\(bookID.uuidString)"
    }

    /// `commit-<bookID>/archive.json`, relative to the session directory.
    static func archiveRelativePath(bookID: UUID) -> String {
        "\(commitDirectoryName(bookID: bookID))/\(archiveFileName)"
    }

    static func stagedDirectory(session: URL, bookID: UUID) -> URL {
        session.appendingPathComponent(stagedRelativePath(bookID: bookID), isDirectory: true)
    }

    static func commitDirectory(session: URL, bookID: UUID) -> URL {
        session.appendingPathComponent(commitDirectoryName(bookID: bookID), isDirectory: true)
    }

    static func archiveFile(session: URL, bookID: UUID) -> URL {
        session.appendingPathComponent(archiveRelativePath(bookID: bookID), isDirectory: false)
    }

    static func journalFile(session: URL, bookID: UUID) -> URL {
        commitDirectory(session: session, bookID: bookID).appendingPathComponent(journalFileName, isDirectory: false)
    }

    static func asideRoot(session: URL, bookID: UUID) -> URL {
        commitDirectory(session: session, bookID: bookID).appendingPathComponent(asideDirectoryName, isDirectory: true)
    }

    static func asideDirectory(session: URL, bookID: UUID, replacedID: UUID) -> URL {
        asideRoot(session: session, bookID: bookID).appendingPathComponent(replacedID.uuidString, isDirectory: true)
    }
}

// MARK: - Journal

/// The commit journal of one book (`commit-<bookID>/journal.json`). Written and synced to disk
/// before anything in `Books/` moves, and removed once the records are committed; its presence
/// at launch means the commit must be finished (`RestoreRecovery`). Paths are relative to the
/// session directory, because the app container's absolute path can change between launches.
nonisolated struct RestoreJournal: Codable, Equatable, Sendable {
    /// A PDF taken from a replaced local book: moved from its set-aside directory into the
    /// staged directory during the commit.
    struct LocalPDF: Codable, Equatable, Sendable {
        /// The replaced local book whose PDF is reused.
        var bookID: UUID
        /// Its PDF's file name inside its directory.
        var fileName: String
    }

    static let currentVersion = 1

    var version = RestoreJournal.currentVersion
    /// The restored book.
    var bookID: UUID
    /// The local books the restore replaces (passed to `replaceBook(_:removing:)`), ascending by
    /// `uuidString`. May include `bookID`.
    var replacedBookIDs: [UUID]
    /// The staged directory (`staged/<bookID>`).
    var stagedPath: String
    /// The records to commit (`commit-<bookID>/archive.json`).
    var archivePath: String
    /// The restored book's PDF file name (`Book.fileName`).
    var pdfFileName: String
    /// Set when the PDF comes from a replaced local book.
    var localPDF: LocalPDF?
    /// Set when the restored book is a converted one whose backup came without its kept original
    /// (backups never hold it) and a replaced local book made from the same file still has it:
    /// that entry (`original.<ext>`, a file or a package directory) moves across like the PDF.
    var localOriginal: LocalPDF?

    /// Every `Books/<id>` the commit moves aside: the replaced books and the restored ID itself
    /// (a local book with that ID is replaced too), ascending by `uuidString`.
    var setAsideIDs: [UUID] {
        Set(replacedBookIDs + [bookID]).sorted { $0.uuidString < $1.uuidString }
    }

    /// `true` when the paths are exactly the ones this version derives from `bookID`, and the
    /// file names are plain names (so a journal can never make recovery touch anything outside
    /// its session and the book directories it names).
    var isWellFormed: Bool {
        version == Self.currentVersion
            && stagedPath == RestoreLayout.stagedRelativePath(bookID: bookID)
            && archivePath == RestoreLayout.archiveRelativePath(bookID: bookID)
            && RestoreNames.isSafeFileName(pdfFileName)
            && (localPDF.map { RestoreNames.isSafeFileName($0.fileName) && replacedBookIDs.contains($0.bookID) } ?? true)
            && (localOriginal.map {
                BookStorageLayout.isOriginalFileName($0.fileName) && $0.fileName != pdfFileName
                    && replacedBookIDs.contains($0.bookID)
            } ?? true)
    }
}

nonisolated enum RestoreNames {
    /// A single, plain path component: not empty, not `.`/`..`, no `/`, no NUL, not hidden.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }
}

// MARK: - Durable writes

/// `fsync` helpers: the journal and everything it points at must be on disk before the commit
/// moves anything, or a power loss could leave a journal pointing at files that never landed.
nonisolated enum RestoreDurability {
    /// Writes `data` to `url` atomically and durably: a hidden temporary sibling, written and
    /// synced, renamed into place, then the directory synced.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try data.write(to: temporary)
            try syncFile(temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Syncs one regular file to the device.
    static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Syncs a directory's entries (best effort).
    static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    /// Syncs every regular file and directory under `root`, and `root` itself.
    static func syncTree(_ root: URL) throws {
        let manager = FileManager.default
        if let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values.isRegularFile == true {
                    try syncFile(url)
                } else if values.isDirectory == true {
                    syncDirectory(url)
                }
            }
        }
        syncDirectory(root)
        syncDirectory(root.deletingLastPathComponent())
    }
}

// MARK: - Commit

/// The commit of one restored book: the only step of a restore that changes the library.
///
/// Runs on the main actor with **no suspension point**, so no other main-actor code (an import's
/// commit, a delete, an editor's synchronous save) can interleave; asynchronous ink saves of the
/// affected books are held at `BookWriteGate` by the caller.
///
/// Steps, each recorded by the state of the file system so recovery can tell how far it got:
/// 1. Write `journal.json` (synced) naming the book, the replaced IDs and the staged directory.
/// 2. Move each existing `Books/<id>` of `journal.setAsideIDs` to `aside/<id>`.
/// 3. With a reused local PDF: move `aside/<localID>/<fileName>` into the staged directory under
///    the restored book's file name.
/// 4. Move the staged directory to `Books/<bookID>`.
/// 5. `replaceBook(archive, removing: replacedIDs)` (one SwiftData transaction; posts
///    `.bookDeleted` for each replaced book that existed, then `.bookSaved`).
/// 6. Remove the journal (the commit is complete), then the commit directory with the set-aside
///    directories.
///
/// ## Crash points and recovery (`RestoreRecovery`, run at launch before the orphan sweep)
/// - **Before 1** (the journal never landed): nothing in `Books/` or the database changed. The
///   session directory is removed; the book was not restored.
/// - **After 1**, **after the first move of 2**, **after all of 2**, **after 3**: the staged
///   directory still exists, so every `Books/<id>` still present is an old one. Recovery moves
///   the remaining ones aside, does step 3 if its source is still aside and its target absent,
///   then 4, 5 and 6.
/// - **After 4**: the staged directory is gone, so `Books/<bookID>` is the restored one. Recovery
///   does 5 and 6.
/// - **After 5**: the records are committed; `replaceBook` is idempotent, so recovery runs it
///   again and does 6.
/// - **After 6's journal removal**: the book is fully restored; recovery only removes the
///   leftover session directory (set-aside copies of the replaced books).
/// If step 5 fails (the store refuses the archive), the commit rolls the moves back (4, 3, 2 in
/// reverse) and removes the journal: the library is exactly as before. A failure while rolling
/// back leaves the journal, and the next launch rolls forward again.
@MainActor
enum RestoreCommit {
    /// The points a commit can be stopped after (a simulated crash, for tests).
    enum Step: Int, CaseIterable, Sendable, Comparable {
        case journalWritten = 1, firstSetAside, allSetAside, pdfMoved, stagedMovedIn, recordsReplaced, journalRemoved

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What one book's commit needs. `archive.json` and the staged directory must exist.
    struct Plan: Sendable {
        /// `Restores/<session>`
        var sessionDirectory: URL
        /// The records to commit (as written to `archive.json`).
        var archive: BookArchive
        /// Local books the restore replaces (same ID or same fingerprint).
        var replacedBookIDs: Set<UUID>
        /// A replaced local book whose PDF is reused.
        var localPDF: RestoreJournal.LocalPDF?
        /// A replaced local book whose kept original is carried over (`keptOriginal`).
        var localOriginal: RestoreJournal.LocalPDF?

        var bookID: UUID { archive.book.id }

        var journal: RestoreJournal {
            RestoreJournal(bookID: bookID, replacedBookIDs: replacedBookIDs.sorted { $0.uuidString < $1.uuidString },
                           stagedPath: RestoreLayout.stagedRelativePath(bookID: bookID),
                           archivePath: RestoreLayout.archiveRelativePath(bookID: bookID),
                           pdfFileName: archive.book.fileName, localPDF: localPDF, localOriginal: localOriginal)
        }
    }

    /// The kept original to carry into a restored converted book: the `original.<ext>` of a
    /// replaced local book made from the same file (same fingerprint, which for a converted book
    /// is its original's), when the staged directory has none. `nil` otherwise.
    static func keptOriginal(for restored: Book, sessionDirectory: URL, replacing replaced: [UUID],
                             store: LibraryStore) -> RestoreJournal.LocalPDF? {
        guard restored.isConverted else { return nil }
        let manager = FileManager.default
        func original(in directory: URL, besides pdf: String) -> String? {
            (try? manager.contentsOfDirectory(atPath: directory.path))?
                .first { BookStorageLayout.isOriginalFileName($0) && $0 != pdf }
        }
        let staged = RestoreLayout.stagedDirectory(session: sessionDirectory, bookID: restored.id)
        guard original(in: staged, besides: restored.fileName) == nil else { return nil }
        for id in replaced {
            guard let local = try? store.books.book(id: id), local.isConverted, local.fingerprint == restored.fingerprint,
                  let name = original(in: store.bookDirectoryURL(bookID: id), besides: local.fileName),
                  name != restored.fileName else { continue }
            return RestoreJournal.LocalPDF(bookID: id, fileName: name)
        }
        return nil
    }

    enum Outcome: Equatable, Sendable {
        case committed
        /// Stopped after this step on request (tests): everything is left as a crash would.
        case stopped(after: Step)
    }

    /// Commits one book (see the type). Throws, with the library unchanged, when a step fails
    /// before the records are committed (after a successful rollback); a failure after step 5
    /// is not an error (the book is restored; leftovers are removed at the next launch).
    static func perform(_ plan: Plan, store: LibraryStore, origin: ChangeOrigin?, stopAfter: Step? = nil) throws -> Outcome {
        let journal = plan.journal
        let session = plan.sessionDirectory
        let manager = FileManager.default
        let staged = RestoreLayout.stagedDirectory(session: session, bookID: plan.bookID)
        guard manager.fileExists(atPath: staged.path),
              manager.fileExists(atPath: RestoreLayout.archiveFile(session: session, bookID: plan.bookID).path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        // 1. The journal, durably.
        let journalURL = RestoreLayout.journalFile(session: session, bookID: plan.bookID)
        try RestoreDurability.writeDurably(try BackupCoding.makeEncoder().encode(journal), to: journalURL)
        if stopAfter == .journalWritten { return .stopped(after: .journalWritten) }

        do {
            // 2. Set the replaced directories aside.
            let asideRoot = RestoreLayout.asideRoot(session: session, bookID: plan.bookID)
            try manager.createDirectory(at: asideRoot, withIntermediateDirectories: true)
            var moved = 0
            for id in journal.setAsideIDs {
                let live = store.bookDirectoryURL(bookID: id)
                guard manager.fileExists(atPath: live.path) else { continue }
                try manager.moveItem(at: live, to: RestoreLayout.asideDirectory(session: session, bookID: plan.bookID, replacedID: id))
                moved += 1
                if moved == 1, stopAfter == .firstSetAside { return .stopped(after: .firstSetAside) }
            }
            if stopAfter == .firstSetAside { return .stopped(after: .firstSetAside) }
            if stopAfter == .allSetAside { return .stopped(after: .allSetAside) }

            // 3. A reused local PDF joins the staged directory.
            try RestoreRecovery.moveLocalPDFIfNeeded(journal, session: session)
            try RestoreRecovery.moveLocalOriginalIfNeeded(journal, session: session)
            if stopAfter == .pdfMoved { return .stopped(after: .pdfMoved) }

            // 4. The staged directory becomes the book's directory.
            try moveStagedIn(journal, session: session, store: store)
            if stopAfter == .stagedMovedIn { return .stopped(after: .stagedMovedIn) }

            // 5. The records, in one transaction.
            try store.perform(as: origin) { try store.books.replaceBook(plan.archive, removing: plan.replacedBookIDs) }
        } catch {
            do {
                try RestoreRecovery.rollBack(journal, session: session, store: store)
                try? manager.removeItem(at: journalURL)
            } catch let rollbackError {
                backupLog.error("restore of \(plan.bookID) failed and could not be rolled back (\(String(describing: rollbackError))); the next launch finishes it")
            }
            throw error
        }
        if stopAfter == .recordsReplaced { return .stopped(after: .recordsReplaced) }

        // 6. Done: drop the journal, then the set-aside copies.
        do {
            try manager.removeItem(at: journalURL)
            RestoreDurability.syncDirectory(journalURL.deletingLastPathComponent())
        } catch {
            backupLog.error("restore journal of \(plan.bookID) not removed: \(String(describing: error))")
            return .committed
        }
        if stopAfter == .journalRemoved { return .stopped(after: .journalRemoved) }
        try? manager.removeItem(at: RestoreLayout.commitDirectory(session: session, bookID: plan.bookID))
        return .committed
    }

    /// Step 4: `staged/<bookID>` → `Books/<bookID>`. A `Books/<bookID>` that reappeared after
    /// step 2 (it cannot while saves are gated; defensive) is set aside as stale first.
    static func moveStagedIn(_ journal: RestoreJournal, session: URL, store: LibraryStore) throws {
        let manager = FileManager.default
        let staged = RestoreLayout.stagedDirectory(session: session, bookID: journal.bookID)
        let target = store.bookDirectoryURL(bookID: journal.bookID)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: target.path) {
            let stale = RestoreLayout.commitDirectory(session: session, bookID: journal.bookID)
                .appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: target, to: stale)
        }
        try manager.moveItem(at: staged, to: target)
    }
}

// MARK: - Recovery

/// What launch-time recovery did.
nonisolated struct RestoreRecoveryReport: Equatable, Sendable {
    /// Books whose interrupted commit was finished.
    var rolledForward: [UUID] = []
    /// Books whose commit could not be finished (the store refused the records) and was undone.
    var rolledBack: [UUID] = []
    /// Session directories kept because a journal in them could not be read (never deleted: a
    /// set-aside directory in them may be the only copy of a book's files).
    var keptSessions: [String] = []
    /// Session directories removed.
    var removedSessions = 0
}

/// Launch-time recovery of interrupted restores: rolls every journal forward (see
/// `RestoreCommit` for the crash points), then removes the `Restores/` sessions. Must run before
/// `sweepOrphanedBookDirectories`, which would otherwise delete a swapped-in `Books/<id>` whose
/// record is not committed yet, and before any restore can start.
@MainActor
enum RestoreRecovery {
    static func recover(store: LibraryStore, origin: ChangeOrigin? = nil) async -> RestoreRecoveryReport {
        var report = RestoreRecoveryReport()
        let root = RestoreLayout.root(storeRoot: store.rootDirectory)
        let manager = FileManager.default
        guard let sessions = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return report }
        var removable: [URL] = []
        for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var keep = false
            let entries = (try? manager.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            for commit in entries where commit.lastPathComponent.hasPrefix("commit-") {
                let journalURL = commit.appendingPathComponent(RestoreLayout.journalFileName, isDirectory: false)
                guard manager.fileExists(atPath: journalURL.path) else { continue }
                guard let data = try? Data(contentsOf: journalURL),
                      let journal = try? BackupCoding.makeDecoder().decode(RestoreJournal.self, from: data),
                      journal.isWellFormed,
                      commit.lastPathComponent == RestoreLayout.commitDirectoryName(bookID: journal.bookID) else {
                    backupLog.error("restore journal \(journalURL.path) is unreadable; its session is kept")
                    keep = true
                    continue
                }
                if rollForward(journal, session: session, store: store, origin: origin) {
                    report.rolledForward.append(journal.bookID)
                } else {
                    report.rolledBack.append(journal.bookID)
                }
            }
            if keep {
                report.keptSessions.append(session.lastPathComponent)
            } else {
                removable.append(session)
            }
        }
        if !removable.isEmpty {
            await removeDirectories(removable)
            report.removedSessions = removable.count
        }
        if (try? manager.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? manager.removeItem(at: root)
        }
        return report
    }

    @concurrent
    private nonisolated static func removeDirectories(_ urls: [URL]) async {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Finishes one interrupted commit. Returns `true` when the book is restored, `false` when it
    /// had to be rolled back (the library is then as before the restore).
    static func rollForward(_ journal: RestoreJournal, session: URL, store: LibraryStore, origin: ChangeOrigin?) -> Bool {
        let manager = FileManager.default
        let journalURL = RestoreLayout.journalFile(session: session, bookID: journal.bookID)
        let staged = RestoreLayout.stagedDirectory(session: session, bookID: journal.bookID)
        do {
            if manager.fileExists(atPath: staged.path) {
                // Steps 2–4 are not all done: every `Books/<id>` still present is an old one.
                let asideRoot = RestoreLayout.asideRoot(session: session, bookID: journal.bookID)
                try manager.createDirectory(at: asideRoot, withIntermediateDirectories: true)
                for id in journal.setAsideIDs {
                    let live = store.bookDirectoryURL(bookID: id)
                    guard manager.fileExists(atPath: live.path) else { continue }
                    let aside = RestoreLayout.asideDirectory(session: session, bookID: journal.bookID, replacedID: id)
                    if manager.fileExists(atPath: aside.path) {
                        // Already set aside once; this one reappeared later and is stale.
                        try manager.moveItem(at: live, to: asideRoot.deletingLastPathComponent()
                            .appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true))
                    } else {
                        try manager.moveItem(at: live, to: aside)
                    }
                }
                try moveLocalPDFIfNeeded(journal, session: session)
                try moveLocalOriginalIfNeeded(journal, session: session)
                try RestoreCommit.moveStagedIn(journal, session: session, store: store)
            } else if !manager.fileExists(atPath: store.bookDirectoryURL(bookID: journal.bookID).path) {
                // Neither staged nor swapped in: nothing to commit the records to.
                throw CocoaError(.fileNoSuchFile)
            }
            let archiveData = try Data(contentsOf: session.appendingPathComponent(journal.archivePath, isDirectory: false))
            let archive = try BackupCoding.makeDecoder().decode(BookArchive.self, from: archiveData)
            guard archive.book.id == journal.bookID else { throw CocoaError(.fileReadCorruptFile) }
            try store.perform(as: origin) { try store.books.replaceBook(archive, removing: Set(journal.replacedBookIDs)) }
            try? manager.removeItem(at: journalURL)
            return true
        } catch {
            backupLog.error("restore of \(journal.bookID) could not be finished (\(String(describing: error))); rolling back")
            do {
                try rollBack(journal, session: session, store: store)
                try? manager.removeItem(at: journalURL)
            } catch {
                backupLog.error("restore of \(journal.bookID) could not be rolled back: \(String(describing: error))")
            }
            return false
        }
    }

    /// Step 3 (idempotent): moves the reused local PDF from its set-aside directory into the
    /// staged directory, when it is still aside and the target is absent.
    static func moveLocalPDFIfNeeded(_ journal: RestoreJournal, session: URL) throws {
        guard let local = journal.localPDF else { return }
        let manager = FileManager.default
        let source = RestoreLayout.asideDirectory(session: session, bookID: journal.bookID, replacedID: local.bookID)
            .appendingPathComponent(local.fileName, isDirectory: false)
        let target = RestoreLayout.stagedDirectory(session: session, bookID: journal.bookID)
            .appendingPathComponent(journal.pdfFileName, isDirectory: false)
        guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) else { return }
        try manager.moveItem(at: source, to: target)
    }

    /// Step 3, second part (idempotent): moves a carried-over kept original from its set-aside
    /// directory into the staged directory, when it is still aside and the target is absent.
    static func moveLocalOriginalIfNeeded(_ journal: RestoreJournal, session: URL) throws {
        guard let local = journal.localOriginal else { return }
        let manager = FileManager.default
        let source = RestoreLayout.asideDirectory(session: session, bookID: journal.bookID, replacedID: local.bookID)
            .appendingPathComponent(local.fileName)
        let target = RestoreLayout.stagedDirectory(session: session, bookID: journal.bookID)
            .appendingPathComponent(local.fileName)
        guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) else { return }
        try manager.moveItem(at: source, to: target)
    }

    /// Undoes steps 4, 3 and 2 (each only if done), leaving `Books/` as before the commit.
    /// The records are never touched: `replaceBook` either committed (then this is not called)
    /// or changed nothing.
    static func rollBack(_ journal: RestoreJournal, session: URL, store: LibraryStore) throws {
        let manager = FileManager.default
        let staged = RestoreLayout.stagedDirectory(session: session, bookID: journal.bookID)
        let live = store.bookDirectoryURL(bookID: journal.bookID)
        if !manager.fileExists(atPath: staged.path), manager.fileExists(atPath: live.path) {
            try manager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: live, to: staged)
        }
        if let local = journal.localPDF {
            let aside = RestoreLayout.asideDirectory(session: session, bookID: journal.bookID, replacedID: local.bookID)
            let original = aside.appendingPathComponent(local.fileName, isDirectory: false)
            let reused = staged.appendingPathComponent(journal.pdfFileName, isDirectory: false)
            if manager.fileExists(atPath: aside.path), !manager.fileExists(atPath: original.path),
               manager.fileExists(atPath: reused.path) {
                try manager.moveItem(at: reused, to: original)
            }
        }
        if let local = journal.localOriginal {
            let aside = RestoreLayout.asideDirectory(session: session, bookID: journal.bookID, replacedID: local.bookID)
            let kept = aside.appendingPathComponent(local.fileName)
            let carried = staged.appendingPathComponent(local.fileName)
            if manager.fileExists(atPath: aside.path), !manager.fileExists(atPath: kept.path),
               manager.fileExists(atPath: carried.path) {
                try manager.moveItem(at: carried, to: kept)
            }
        }
        for id in journal.setAsideIDs {
            let aside = RestoreLayout.asideDirectory(session: session, bookID: journal.bookID, replacedID: id)
            let target = store.bookDirectoryURL(bookID: id)
            if manager.fileExists(atPath: aside.path), !manager.fileExists(atPath: target.path) {
                try manager.moveItem(at: aside, to: target)
            }
        }
    }
}
