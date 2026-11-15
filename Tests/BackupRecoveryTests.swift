import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// Crash safety of the restore commit (B3): for every crash point of `RestoreCommit`, the commit
/// is stopped there (leaving exactly what a crash would), launch recovery runs, and the book must
/// be fully restored, `Restores/` empty, and the orphan sweep must remove nothing.
@MainActor
struct BackupRecoveryTests {
    typealias Support = BackupTestSupport

    struct Backups {
        let source: LibraryStore
        let seeded: BackupTestSupport.Seeded
        let withPDFs: URL
        let withoutPDFs: URL
        /// The backed-up book S's records and files.
        let archive: BookArchive
        let files: [String: Data]
    }

    private func makeBackups(_ scratch: URL) async throws -> Backups {
        let source = try LibraryStore.ephemeral()
        let seeded = try await Support.seedLibrary(source)
        let service = Support.makeService(source, scratch: scratch)
        let withPDFs = try await service.backUpToFile(includePDFs: true).url
        let withoutPDFs = try await service.backUpToFile(includePDFs: false).url
        return Backups(source: source, seeded: seeded, withPDFs: withPDFs, withoutPDFs: withoutPDFs,
                       archive: try #require(try Support.archive(source, seeded.small.id)),
                       files: Support.files(in: source.bookDirectoryURL(bookID: seeded.small.id)))
    }

    /// A target library where restoring S replaces two books: X has S's ID (another PDF), Y has
    /// S's fingerprint (another ID, the same PDF, which the restore reuses).
    private func makeReplaceTarget(_ store: LibraryStore, backups: Backups) async throws -> (x: Book, y: Book) {
        let s = backups.seeded.small
        let x = Book(id: s.id, title: "X same ID", fingerprint: "sha256-v1:other-\(UUID().uuidString)", fileName: "x.pdf",
                     pageCount: 3, fileSize: 9)
        try store.books.save(x)
        try FileManager.default.createDirectory(at: store.bookDirectoryURL(bookID: x.id), withIntermediateDirectories: true)
        try Data("not a pdf".utf8).write(to: store.documentURL(for: x))
        try await store.savePageInk(Support.inkData("X-ink"), bookID: x.id, pageIndex: 0, origin: nil)
        try store.notes.save(Note(bookID: x.id, target: .page(0), text: "X's own note"))
        let y = try await ImportService(store: store).importPDF(at: Support.small).book
        try store.notes.save(Note(bookID: y.id, target: .page(1), text: "Y's own note"))
        #expect(y.fingerprint == s.fingerprint && y.id != s.id)
        // The restore hashes local candidates (caching `document.sha256`); do it now so "the
        // library as it was" already includes those caches.
        _ = try await store.contentDigest(of: x)
        _ = try await store.contentDigest(of: y)
        return (x, y)
    }

    private func restoreStopping(after step: RestoreCommit.Step, store: LibraryStore, file: URL, bookID: UUID,
                                 scratch: URL) async throws -> RestoreSummary {
        let service = Support.makeService(store, scratch: scratch)
        service.stopCommitAfter = step
        let session = try await service.openBackup(at: file)
        defer { session.close() }
        return try await service.restore([bookID], from: session, restorePDFs: true)
    }

    private func journals(_ store: LibraryStore) -> [URL] {
        let root = RestoreLayout.root(storeRoot: store.rootDirectory)
        let sessions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return sessions.flatMap { session in
            ((try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? [])
                .map { $0.appendingPathComponent(RestoreLayout.journalFileName) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func expectFullyRestored(_ store: LibraryStore, backups: Backups, replaced: [UUID] = []) async throws {
        let s = backups.seeded.small
        #expect(try Support.archive(store, s.id) == backups.archive)
        #expect(Support.files(in: store.bookDirectoryURL(bookID: s.id)) == backups.files)
        #expect(store.hasDocument(s))
        for id in replaced where id != s.id {
            #expect(try store.books.book(id: id) == nil)
            #expect(!FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: id).path))
        }
        #expect(Support.restoresDirectoryIsGone(store))
        #expect(try await store.sweepOrphanedBookDirectories().isEmpty)
        #expect(Support.files(in: store.bookDirectoryURL(bookID: s.id)) == backups.files)
    }

    // MARK: Every crash point

    @Test(arguments: RestoreCommit.Step.allCases)
    func replacingTwoBooksRecoversFrom(_ step: RestoreCommit.Step) async throws {
        let scratch = try Support.scratch("BackupRecovery")
        let store = try LibraryStore.ephemeral()
        let backups = try await makeBackups(scratch)
        defer { for url in [scratch, store.rootDirectory, backups.source.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let (x, y) = try await makeReplaceTarget(store, backups: backups)

        // The backup without PDFs: S's PDF comes from Y, moved across during the commit.
        let summary = try await restoreStopping(after: step, store: store, file: backups.withoutPDFs,
                                                bookID: backups.seeded.small.id, scratch: scratch)
        #expect(summary.restored.isEmpty)
        #expect(journals(store).count == (step <= .recordsReplaced ? 1 : 0))
        #expect(!Support.restoresDirectoryIsGone(store))
        switch step {
        case .journalWritten:
            #expect(try store.books.book(id: x.id)?.title == "X same ID")
            #expect(FileManager.default.fileExists(atPath: store.documentURL(for: x).path))
        case .allSetAside, .pdfMoved:
            #expect(!FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: x.id).path))
            #expect(!FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: y.id).path))
        case .stagedMovedIn:
            #expect(try store.books.book(id: x.id)?.title == "X same ID")  // records not committed yet
            #expect(FileManager.default.fileExists(atPath: store.documentURL(for: backups.seeded.small).path))
        case .recordsReplaced, .journalRemoved:
            #expect(try Support.archive(store, backups.seeded.small.id) == backups.archive)
        case .firstSetAside:
            let remaining = [x.id, y.id].filter { FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: $0).path) }
            #expect(remaining.count == 1)
        }

        let report = await RestoreRecovery.recover(store: store)
        #expect(report.rolledForward == (step <= .recordsReplaced ? [backups.seeded.small.id] : []))
        #expect(report.rolledBack.isEmpty && report.keptSessions.isEmpty)
        try await expectFullyRestored(store, backups: backups, replaced: [x.id, y.id])
        // Running recovery again finds nothing.
        #expect(await RestoreRecovery.recover(store: store) == RestoreRecoveryReport())
    }

    @Test(arguments: RestoreCommit.Step.allCases)
    func aNewBookRecoversFrom(_ step: RestoreCommit.Step) async throws {
        let scratch = try Support.scratch("BackupRecovery")
        let store = try LibraryStore.ephemeral()
        let backups = try await makeBackups(scratch)
        defer { for url in [scratch, store.rootDirectory, backups.source.rootDirectory] { try? FileManager.default.removeItem(at: url) } }

        _ = try await restoreStopping(after: step, store: store, file: backups.withPDFs, bookID: backups.seeded.small.id,
                                      scratch: scratch)
        if step == .stagedMovedIn {
            // The swapped-in directory has no record yet: the sweep would delete it, which is why
            // recovery runs first.
            #expect(try store.books.book(id: backups.seeded.small.id) == nil)
            #expect(FileManager.default.fileExists(atPath: store.bookDirectoryURL(bookID: backups.seeded.small.id).path))
        }
        _ = await RestoreRecovery.recover(store: store)
        try await expectFullyRestored(store, backups: backups)
        #expect(try store.books.allBooks().map(\.id) == [backups.seeded.small.id])
    }

    @Test func aCrashBeforeTheJournalLandsChangesNothing() async throws {
        let scratch = try Support.scratch("BackupRecovery")
        let store = try LibraryStore.ephemeral()
        let backups = try await makeBackups(scratch)
        defer { for url in [scratch, store.rootDirectory, backups.source.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        _ = try await makeReplaceTarget(store, backups: backups)
        let before = try Support.libraryState(store)

        _ = try await restoreStopping(after: .journalWritten, store: store, file: backups.withoutPDFs,
                                      bookID: backups.seeded.small.id, scratch: scratch)
        // Staged and archived, but the journal never reached the disk.
        for journal in journals(store) { try FileManager.default.removeItem(at: journal) }
        let report = await RestoreRecovery.recover(store: store)
        #expect(report.rolledForward.isEmpty && report.removedSessions == 1)
        #expect(try Support.libraryState(store) == before)
        #expect(Support.restoresDirectoryIsGone(store))
        #expect(try await store.sweepOrphanedBookDirectories().isEmpty)
    }

    @Test func anUnreadableJournalKeepsItsSession() async throws {
        let scratch = try Support.scratch("BackupRecovery")
        let store = try LibraryStore.ephemeral()
        let backups = try await makeBackups(scratch)
        defer { for url in [scratch, store.rootDirectory, backups.source.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        _ = try await makeReplaceTarget(store, backups: backups)
        _ = try await restoreStopping(after: .allSetAside, store: store, file: backups.withoutPDFs,
                                      bookID: backups.seeded.small.id, scratch: scratch)
        let journal = try #require(journals(store).first)
        try Data("{garbage".utf8).write(to: journal)
        let report = await RestoreRecovery.recover(store: store)
        #expect(report.keptSessions.count == 1)
        // The set-aside directories (the only copy of the replaced books' files) are still there.
        let aside = journal.deletingLastPathComponent().appendingPathComponent(RestoreLayout.asideDirectoryName)
        #expect((try FileManager.default.contentsOfDirectory(atPath: aside.path)).count == 2)
    }

    // MARK: On disk, across a relaunch

    @Test(arguments: [RestoreCommit.Step.stagedMovedIn, .recordsReplaced])
    func anOnDiskStoreRecoversAfterReopening(_ step: RestoreCommit.Step) async throws {
        let scratch = try Support.scratch("BackupRecoveryDisk")
        let root = scratch.appendingPathComponent("Store", isDirectory: true)
        let backups = try await makeBackups(scratch)
        defer { for url in [scratch, backups.source.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        var replaced: [UUID] = []
        do {
            let store = try LibraryStore.live(rootDirectory: root)
            let (x, y) = try await makeReplaceTarget(store, backups: backups)
            replaced = [x.id, y.id]
            _ = try await restoreStopping(after: step, store: store, file: backups.withoutPDFs,
                                          bookID: backups.seeded.small.id, scratch: scratch)
        }
        do {
            // "Relaunch": a new store on the same files, recovery before the sweep.
            let store = try LibraryStore.live(rootDirectory: root)
            let report = await RestoreRecovery.recover(store: store)
            #expect(report.rolledForward == [backups.seeded.small.id])
            try await expectFullyRestored(store, backups: backups, replaced: replaced)
        }
        let reopened = try LibraryStore.live(rootDirectory: root)
        #expect(try Support.archive(reopened, backups.seeded.small.id) == backups.archive)
        #expect(try reopened.books.allBooks().map(\.id) == [backups.seeded.small.id])
        #expect(Support.files(in: reopened.bookDirectoryURL(bookID: backups.seeded.small.id)) == backups.files)
    }

    // MARK: A commit the store refuses

    @Test func aRefusedCommitIsRolledBackLeavingTheLibraryAsItWas() async throws {
        let scratch = try Support.scratch("BackupRollback")
        let store = try LibraryStore.ephemeral()
        let backups = try await makeBackups(scratch)
        defer { for url in [scratch, store.rootDirectory, backups.source.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        _ = try await makeReplaceTarget(store, backups: backups)
        // Another book already owns one of the backup's note IDs: replaceBook refuses.
        let stray = try #require(backups.archive.notes.first)
        let other = try await ImportService(store: store).importPDF(at: Support.noOutline).book
        try store.notes.save(Note(id: stray.id, bookID: other.id, target: .page(5), text: "owns the ID"))
        let before = try Support.libraryState(store)

        let service = Support.makeService(store, scratch: scratch)
        let session = try await service.openBackup(at: backups.withoutPDFs)
        let summary = try await service.restore([backups.seeded.small.id], from: session, restorePDFs: true)
        session.close()
        #expect(summary.restored.isEmpty)
        #expect(summary.failures.map(\.id) == [backups.seeded.small.id])
        #expect(try Support.libraryState(store) == before)
        #expect(Support.restoresDirectoryIsGone(store))
        #expect(try await store.sweepOrphanedBookDirectories().isEmpty)
    }
}
