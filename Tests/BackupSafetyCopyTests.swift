import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
@testable import TactileTexts

/// The safety copy a restore keeps of the books it changes, and Undo Last Restore
/// (`RestoreSafety.swift`), app-hosted.
@MainActor
struct BackupSafetyCopyTests {
    typealias Support = BackupTestSupport

    @MainActor
    private struct World {
        var scratch: URL
        var store: LibraryStore
        var seeded: Support.Seeded
        /// A backup of the seeded library as it was made (with PDFs).
        var backup: URL

        func cleanUp() {
            for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// A seeded library and a backup of it, then local work on top: a new note, a changed note,
    /// new page ink and a new highlight in `small`, so restoring the backup loses something.
    private func makeWorld(edited: Bool = true) async throws -> World {
        let scratch = try Support.scratch("BackupSafety")
        let store = try LibraryStore.ephemeral()
        let seeded = try await Support.seedLibrary(store)
        let backup = try await Support.makeService(store, scratch: scratch).backUpToFile(includePDFs: true).url
        if edited { try await editLocally(store, seeded.small, label: "after") }
        return World(scratch: scratch, store: store, seeded: seeded, backup: backup)
    }

    private func editLocally(_ store: LibraryStore, _ book: Book, label: String) async throws {
        try store.notes.save(Note(bookID: book.id, target: .page(8), text: "\(label): a note made after the backup"))
        var existing = try #require(try store.notes.note(bookID: book.id, target: .page(4)))
        existing.text += "\n\(label): a line added after the backup"
        existing.modifiedAt = existing.modifiedAt.addingTimeInterval(60)
        try store.notes.save(existing)
        try await store.savePageInk(Support.inkData("\(label)-page-3"), bookID: book.id, pageIndex: 3, origin: nil)
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 7, rects: [CGRect(x: 4, y: 5, width: 60, height: 11)],
                                            color: .green, text: "\(label) highlight"))
    }

    @discardableResult
    private func restoreAll(_ world: World, service: BackupService? = nil, only: Set<UUID>? = nil) async throws -> RestoreSummary {
        let service = service ?? Support.makeService(world.store, scratch: world.scratch)
        let session = try await service.openBackup(at: world.backup)
        defer { session.close() }
        return try await service.restore(only ?? Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
    }

    private func safetyEntries(_ store: LibraryStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: RestoreSafetyStore.root(storeRoot: store.rootDirectory).path)) ?? []
    }

    // MARK: The copy

    @Test func aReplaceKeepsASafetyCopyOfExactlyTheBooksAsTheyWere() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let small = world.seeded.small
        let before = try #require(try Support.archive(world.store, small.id))
        let filesBefore = Support.files(in: world.store.bookDirectoryURL(bookID: small.id))

        let service = Support.makeService(world.store, scratch: world.scratch)
        let summary = try await restoreAll(world, service: service, only: [small.id])
        #expect(summary.restored.map(\.id) == [small.id] && summary.failures.isEmpty)
        #expect(try world.store.notes.note(bookID: small.id, target: .page(8)) == nil, "the replace took the later note away")

        let record = try #require(service.latestRestoreSafetyRecord())
        #expect(record.sourceName == world.backup.lastPathComponent)
        #expect(record.added.isEmpty)
        #expect(record.changed == [.init(previousID: small.id, title: small.title, currentID: small.id, hasKnownPDFHash: true)])

        // The archive: that one book, its records and ink as they were, and no PDF.
        let reader = try BackupArchiveReader(url: RestoreSafetyStore.archiveURL(id: record.id, storeRoot: world.store.rootDirectory))
        #expect(!reader.manifest.includesPDFs && reader.embeddedPDFHashes.isEmpty)
        #expect(reader.manifest.books.map(\.book.id) == [small.id])
        #expect(Support.normalized(try reader.bookArchive(for: small.id)) == before)
        let extracted = world.scratch.appendingPathComponent("extracted", isDirectory: true)
        try reader.extractFiles(ofBook: small.id, into: extracted)
        var expectedFiles = filesBefore
        expectedFiles[small.fileName] = nil
        expectedFiles[BookStorageLayout.contentHashFileName] = nil
        #expect(Support.files(in: extracted) == expectedFiles)
        #expect(Support.restoresDirectoryIsGone(world.store))
    }

    @Test func aBookThatChangedAfterItsCopyWasMadeIsNoLongerCovered() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let small = world.seeded.small
        let service = Support.makeService(world.store, scratch: world.scratch)
        let copy = try await service.makeSafetyCopy(protecting: [small.id, UUID()], sourceName: "test")
        #expect(copy.record.changed.map(\.previousID) == [small.id], "a book that does not exist is not in the copy")
        #expect(copy.isUnchanged(small.id, store: world.store))
        #expect(copy.isUnchanged(UUID(), store: world.store), "nothing there before, nothing there now")

        // The reading position moves at any moment and does not count.
        var book = try #require(try world.store.books.book(id: small.id))
        book.lastReadPageIndex += 3
        book.lastOpenedAt = Date()
        try world.store.books.save(book)
        #expect(copy.isUnchanged(small.id, store: world.store))

        try world.store.bookmarks.setBookmarked(true, bookID: small.id, pageIndex: 11)
        #expect(!copy.isUnchanged(small.id, store: world.store))
        copy.finish()
        #expect(safetyEntries(world.store).isEmpty, "a copy of a restore that changed nothing is not kept")
    }

    // MARK: Undo

    @Test func undoPutsAReplacedBookBackExactlyAsItWas() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let before = try Support.libraryState(world.store)
        let small = world.seeded.small
        let pdfBefore = try Data(contentsOf: world.store.documentURL(for: small))
        let positionBefore = try #require(try world.store.books.book(id: small.id)).lastReadPageIndex

        let service = Support.makeService(world.store, scratch: world.scratch)
        try await restoreAll(world, service: service)
        #expect(try Support.libraryState(world.store) != before)

        let summary = try await service.undoLastRestore()
        #expect(summary.failures.isEmpty && summary.removed.isEmpty)
        #expect(Set(summary.restored.map(\.id)) == [small.id, world.seeded.noOutline.id])
        #expect(summary.needingPDF.isEmpty, "the PDFs on the iPad stay")
        // Records deep-equal; every file byte-equal: PDFs, covers, page ink, note ink, sidecars.
        #expect(try Support.libraryState(world.store) == before)
        #expect(try Data(contentsOf: world.store.documentURL(for: small)) == pdfBefore)
        #expect(try #require(try world.store.books.book(id: small.id)).lastReadPageIndex == positionBefore)
        #expect(try world.store.notes.note(bookID: small.id, target: .page(8)) != nil)

        #expect(service.latestRestoreSafetyRecord() == nil, "an undone restore's copy is removed")
        #expect(safetyEntries(world.store).isEmpty)
        #expect(Support.restoresDirectoryIsGone(world.store))
        #expect(try await world.store.sweepOrphanedBookDirectories().isEmpty)
        await #expect(throws: BackupServiceError.nothingToUndo) { try await service.undoLastRestore() }
    }

    @Test func undoBringsBackTheOriginalIDAfterAReplaceByFingerprint() async throws {
        let world = try await makeWorld(edited: false)
        defer { world.cleanUp() }
        // Another library imported the same PDF on its own: same fingerprint, another ID.
        let target = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: target.rootDirectory) }
        let local = try #require(try await ImportService(store: target).importPDF(at: Support.small).book)
        try target.notes.save(Note(bookID: local.id, target: .page(0), text: "local copy note"))
        try await target.savePageInk(Support.inkData("local-page-1"), bookID: local.id, pageIndex: 1, origin: nil)
        _ = try await target.contentDigest(of: local)
        let before = try Support.libraryState(target)
        #expect(local.id != world.seeded.small.id)

        let service = Support.makeService(target, scratch: world.scratch)
        let session = try await service.openBackup(at: world.backup)
        _ = try await service.restore([world.seeded.small.id], from: session, restorePDFs: false)
        session.close()
        #expect(try target.books.book(id: local.id) == nil)
        let record = try #require(service.latestRestoreSafetyRecord())
        #expect(record.changed.map(\.previousID) == [local.id])
        #expect(record.changed.map(\.currentID) == [world.seeded.small.id])

        let summary = try await service.undoLastRestore()
        #expect(summary.restored.map(\.id) == [local.id] && summary.failures.isEmpty)
        #expect(try target.books.book(id: world.seeded.small.id) == nil)
        #expect(try Support.libraryState(target) == before)
        #expect(try await target.sweepOrphanedBookDirectories().isEmpty)
    }

    @Test func undoRemovesTheBooksARestoreAdded() async throws {
        let world = try await makeWorld(edited: false)
        defer { world.cleanUp() }
        let target = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: target.rootDirectory) }
        let own = try #require(try await ImportService(store: target).importPDF(at: Support.large).book)
        try target.notes.save(Note(bookID: own.id, target: .page(0), text: "already here"))
        let before = try Support.libraryState(target)

        let service = Support.makeService(target, scratch: world.scratch)
        let session = try await service.openBackup(at: world.backup)
        let restored = try await service.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(restored.restored.count == 2)
        let record = try #require(service.latestRestoreSafetyRecord())
        #expect(record.changed.isEmpty)
        #expect(Set(record.added.map(\.id)) == [world.seeded.small.id, world.seeded.noOutline.id])
        let archive = RestoreSafetyStore.archiveURL(id: record.id, storeRoot: target.rootDirectory)
        #expect(!FileManager.default.fileExists(atPath: archive.path), "nothing existing changed: no archive")

        let summary = try await service.undoLastRestore()
        #expect(summary.restored.isEmpty && summary.failures.isEmpty)
        #expect(Set(summary.removed.map(\.id)) == [world.seeded.small.id, world.seeded.noOutline.id])
        #expect(try target.books.allBooks().map(\.id) == [own.id])
        for id in [world.seeded.small.id, world.seeded.noOutline.id] {
            #expect(!FileManager.default.fileExists(atPath: target.bookDirectoryURL(bookID: id).path))
        }
        #expect(try Support.libraryState(target) == before)
        #expect(service.latestRestoreSafetyRecord() == nil)
    }

    @Test func undoPutsBackABookTheReaderDeletedAfterTheRestore() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let small = world.seeded.small
        let before = try #require(try Support.archive(world.store, small.id))
        let inkBefore = Support.files(in: world.store.bookDirectoryURL(bookID: small.id)).filter { $0.key.hasSuffix(".drawing") }
        let digest = try #require(world.store.storedContentDigest(bookID: small.id))

        let service = Support.makeService(world.store, scratch: world.scratch)
        try await restoreAll(world, service: service, only: [small.id])
        try await world.store.deleteBook(id: small.id, origin: nil)
        #expect(try world.store.books.book(id: small.id) == nil)

        let summary = try await service.undoLastRestore()
        #expect(summary.restored.map(\.id) == [small.id])
        #expect(summary.needingPDF.map(\.id) == [small.id], "its PDF went with the delete")
        #expect(try Support.archive(world.store, small.id) == before)
        let files = Support.files(in: world.store.bookDirectoryURL(bookID: small.id))
        #expect(files.filter { $0.key.hasSuffix(".drawing") } == inkBefore)
        #expect(world.store.storedContentDigest(bookID: small.id) == digest, "the hash its PDF must match is kept")
    }

    @Test func undoTwiceWalksBackTwoRestores() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let small = world.seeded.small
        let service = Support.makeService(world.store, scratch: world.scratch)
        let state0 = try Support.libraryState(world.store)

        try await restoreAll(world, service: service, only: [small.id])
        try await editLocally(world.store, small, label: "second")
        let state1 = try Support.libraryState(world.store)
        try await restoreAll(world, service: service, only: [small.id])
        #expect(RestoreSafetyStore.records(storeRoot: world.store.rootDirectory).count == 2)

        _ = try await service.undoLastRestore()
        #expect(try Support.libraryState(world.store) == state1)
        _ = try await service.undoLastRestore()
        #expect(try Support.libraryState(world.store) == state0)
        #expect(service.latestRestoreSafetyRecord() == nil)
    }

    @Test func aBookWithNoPDFAndNoRecordedHashComesBackWithoutAPlaceholderHash() async throws {
        let world = try await makeWorld(edited: false)
        defer { world.cleanUp() }
        let target = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: target.rootDirectory) }
        // A local book with the backup book's ID, no PDF on disk and no recorded hash.
        let s = world.seeded.small
        let bare = Book(id: s.id, title: "No PDF, no hash", fingerprint: "sha256-v1:bare-\(UUID().uuidString)", fileName: "bare.pdf",
                        pageCount: 5, fileSize: 0)
        try target.books.save(bare)
        try target.notes.save(Note(bookID: bare.id, target: .page(2), text: "a note on the bare book"))
        try await target.savePageInk(Support.inkData("bare-ink"), bookID: bare.id, pageIndex: 2, origin: nil)
        let before = try Support.libraryState(target)

        let service = Support.makeService(target, scratch: world.scratch)
        let session = try await service.openBackup(at: world.backup)
        _ = try await service.restore([s.id], from: session, restorePDFs: true)
        session.close()
        let record = try #require(service.latestRestoreSafetyRecord())
        #expect(record.changed.map(\.hasKnownPDFHash) == [false])

        let summary = try await service.undoLastRestore()
        #expect(summary.restored.map(\.id) == [bare.id] && summary.failures.isEmpty)
        #expect(target.storedContentDigest(bookID: bare.id) == nil, "no placeholder hash is left to refuse a PDF later")
        #expect(try Support.libraryState(target) == before)
    }

    // MARK: Retention, failures, interruptions

    @Test func onlyTheNewestFiveSafetyCopiesAreKept() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let service = Support.makeService(world.store, scratch: world.scratch)
        var ids: [UUID] = []
        for round in 0..<7 {
            try world.store.bookmarks.setBookmarked(true, bookID: world.seeded.small.id, pageIndex: 3 + round % 2)
            try await restoreAll(world, service: service, only: [world.seeded.small.id])
            ids.append(try #require(service.latestRestoreSafetyRecord()).id)
        }
        let kept = RestoreSafetyStore.records(storeRoot: world.store.rootDirectory).map(\.id)
        #expect(kept == Array(ids.suffix(RestoreSafetyStore.keepCount).reversed()), "newest first, oldest gone")
        #expect(safetyEntries(world.store).count == RestoreSafetyStore.keepCount)
    }

    @Test func ifTheSafetyCopyCannotBeMadeTheRestoreChangesNothing() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let before = try Support.libraryState(world.store)
        let service = Support.makeService(world.store, scratch: world.scratch)
        service.beforeSafetyCopy = { throw CocoaError(.fileWriteOutOfSpace) }
        do {
            try await restoreAll(world, service: service)
            Issue.record("the restore should have stopped")
        } catch let error as BackupServiceError {
            guard case .safetyCopyFailed = error else { Issue.record("unexpected \(error)"); return }
            #expect(error.localizedDescription.contains("Nothing was restored"))
        }
        #expect(try Support.libraryState(world.store) == before)
        #expect(safetyEntries(world.store).isEmpty)
        #expect(Support.restoresDirectoryIsGone(world.store))
        #expect(service.latestRestoreSafetyRecord() == nil)
    }

    @Test func aRestoreCancelledBeforeCommittingLeavesNoSafetyCopy() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let before = try Support.libraryState(world.store)
        let service = Support.makeService(world.store, scratch: world.scratch)
        service.beforeSafetyCopy = { [weak service] in service?.job?.cancel() }
        await #expect(throws: CancellationError.self) { try await restoreAll(world, service: service) }
        #expect(try Support.libraryState(world.store) == before)
        #expect(safetyEntries(world.store).isEmpty)
        #expect(Support.restoresDirectoryIsGone(world.store))
    }

    @Test func staleAndEmptyCopiesAreRemovedAtLaunch() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let root = world.store.rootDirectory
        let service = Support.makeService(world.store, scratch: world.scratch)
        try await restoreAll(world, service: service, only: [world.seeded.small.id])
        let real = try #require(service.latestRestoreSafetyRecord())
        // A copy that was being written (no record), one whose restore changed nothing, and a stray file.
        let half = RestoreSafetyStore.directory(id: UUID(), storeRoot: root)
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: half.appendingPathComponent(RestoreSafetyStore.archiveFileName))
        let empty = RestoreSafetyRecord(id: UUID(), createdAt: Date(), sourceName: "x",
                                        changed: [.init(previousID: UUID(), title: "t", currentID: nil, hasKnownPDFHash: true)], added: [])
        try RestoreSafetyStore.write(empty, storeRoot: root)
        try Data("stray".utf8).write(to: RestoreSafetyStore.root(storeRoot: root).appendingPathComponent("notes.txt"))

        RestoreSafetyStore.removeStale(storeRoot: root)
        #expect(safetyEntries(world.store) == [real.id.uuidString])
        #expect(service.latestRestoreSafetyRecord() == real)
    }

    @Test func anUndoInterruptedMidWayIsFinishedByRecoveryAndASecondUndo() async throws {
        let world = try await makeWorld()
        defer { world.cleanUp() }
        let before = try Support.libraryState(world.store)
        let service = Support.makeService(world.store, scratch: world.scratch)
        try await restoreAll(world, service: service)
        let record = try #require(service.latestRestoreSafetyRecord())
        #expect(record.changedBooks.count == 2)

        // The undo stops as a crash would, after the first book's records were replaced.
        let interrupted = Support.makeService(world.store, scratch: world.scratch)
        interrupted.stopCommitAfter = .recordsReplaced
        let partial = try await interrupted.undoLastRestore()
        #expect(partial.restored.isEmpty, "a stopped commit is not reported as done")
        #expect(interrupted.latestRestoreSafetyRecord() == record, "the copy is kept until every book is back")
        #expect(!Support.restoresDirectoryIsGone(world.store))

        // Next launch: recovery finishes the interrupted book; undoing again finishes the rest.
        _ = await RestoreRecovery.recover(store: world.store)
        #expect(Support.restoresDirectoryIsGone(world.store))
        let relaunched = Support.makeService(world.store, scratch: world.scratch)
        let summary = try await relaunched.undoLastRestore()
        #expect(summary.failures.isEmpty && summary.restored.count == 2)
        #expect(try Support.libraryState(world.store) == before)
        #expect(relaunched.latestRestoreSafetyRecord() == nil)
        #expect(Support.restoresDirectoryIsGone(world.store))
        #expect(try await world.store.sweepOrphanedBookDirectories().isEmpty)
    }
}
