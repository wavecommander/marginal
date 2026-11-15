import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// The backup engine end to end (B3), app-hosted: back up a seeded library, restore it into a
/// fresh store, through a folder destination, over books already in the Library (including on
/// an on-disk store that is reopened), damaged archives, `hasInk` reconciliation, one job at a
/// time, cancellation and the free-space refusal.
@MainActor
struct BackupRoundTripTests {
    typealias Support = BackupTestSupport

    // MARK: File round trip

    @Test func roundTripWithPDFsRestoresEverythingIntoAFreshStore() async throws {
        let scratch = try Support.scratch("BackupRT")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let seeded = try await Support.seedLibrary(source)
        let service = Support.makeService(source, scratch: scratch)

        let result = try await service.backUpToFile(includePDFs: true)
        #expect(result.bookCount == 2)
        #expect(result.skippedBookTitles.isEmpty)
        #expect(result.url.pathExtension == BackupFormat.fileExtension)
        #expect(SnapshotName.parse(result.url.lastPathComponent)?.deviceName == "Test iPad")
        let estimate = try await service.estimateSizes()
        #expect(result.byteSize <= estimate.withPDFs)
        #expect(estimate.notesAndInk < estimate.withPDFs)

        let restoring = Support.makeService(target, scratch: scratch)
        let session = try await restoring.openBackup(at: result.url)
        #expect(session.manifest.includesPDFs)
        #expect(session.plan.items.allSatisfy { $0.status == .new && $0.isSelectedByDefault && $0.pdfSource == .embedded })
        let summary = try await restoring.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(summary.failures.isEmpty)
        #expect(summary.restored.count == 2)
        #expect(summary.needingPDF.isEmpty)

        for book in [seeded.small, seeded.noOutline] {
            #expect(try Support.archive(target, book.id) == (try Support.archive(source, book.id)))
            let restored = try #require(try target.books.book(id: book.id))
            #expect(restored.lastReadPageIndex == book.lastReadPageIndex)
            #expect(restored.lastOpenedAt == book.lastOpenedAt)
            #expect(target.hasDocument(restored))
            // Every file byte-equal: PDF, cover, page ink, note ink, sidecar.
            let sourceFiles = Support.files(in: source.bookDirectoryURL(bookID: book.id))
            let targetFiles = Support.files(in: target.bookDirectoryURL(bookID: book.id))
            #expect(targetFiles == sourceFiles)
            #expect(targetFiles.keys.contains(book.fileName))
            #expect(targetFiles.keys.contains(ImportPipeline.coverFileName))
            #expect(targetFiles.keys.contains("ink/9.drawing"))
            let digest = try ContentHash.digest(ofFileAt: target.documentURL(for: restored))
            #expect(target.storedContentDigest(bookID: book.id) == digest)
        }
        #expect(Support.restoresDirectoryIsGone(target))
        service.discardTemporaryFile(result.url)
        #expect(Support.temporaryEntries(service).isEmpty)
    }

    @Test func roundTripWithoutPDFsRestoresBooksMissingTheirDocuments() async throws {
        let scratch = try Support.scratch("BackupRT")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let seeded = try await Support.seedLibrary(source)
        let service = Support.makeService(source, scratch: scratch)
        let result = try await service.backUpToFile(includePDFs: false)
        let estimate = try await service.estimateSizes()
        #expect(result.byteSize <= estimate.notesAndInk)

        let restoring = Support.makeService(target, scratch: scratch)
        let session = try await restoring.openBackup(at: result.url)
        #expect(!session.manifest.includesPDFs)
        #expect(session.plan.items.allSatisfy { $0.pdfSource == .missing })
        // "Restore PDFs" on makes no difference: there is nothing to restore them from.
        let summary = try await restoring.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(summary.restored.count == 2)
        #expect(summary.needingPDF.count == 2)

        for book in [seeded.small, seeded.noOutline] {
            #expect(try Support.archive(target, book.id) == (try Support.archive(source, book.id)))
            let restored = try #require(try target.books.book(id: book.id))
            #expect(!target.hasDocument(restored))
            let entry = try #require(session.manifest.entry(for: book.id))
            #expect(target.storedContentDigest(bookID: book.id) == entry.pdf.digest)
            #expect(entry.pdf.digest == (try ContentHash.digest(ofFileAt: source.documentURL(for: book))))
            var sourceFiles = Support.files(in: source.bookDirectoryURL(bookID: book.id))
            sourceFiles[book.fileName] = nil
            #expect(Support.files(in: target.bookDirectoryURL(bookID: book.id)) == sourceFiles)
        }
    }

    // MARK: Folder destination

    @Test func folderDestinationRoundTripUploadsEachPDFOnceAndKeepsTen() async throws {
        let scratch = try Support.scratch("BackupFolder")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let seeded = try await Support.seedLibrary(source)
        let service = Support.makeService(source, scratch: scratch)
        let folder = FolderBackupDestination(root: scratch.appendingPathComponent("Folder", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)

        #expect(service.lastSuccessfulBackup(destinationID: folder.id) == nil)
        let first = try await service.backUp(to: folder, includePDFs: true)
        #expect(first.uploadedPDFs == 2)
        #expect(first.alreadyPresentPDFs == 0)
        #expect(service.lastSuccessfulBackup(destinationID: folder.id) != nil)
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: folder.root.appendingPathComponent("PDFs").path)
        #expect(pdfs.count == 2)

        let second = try await service.backUp(to: folder, includePDFs: true)
        #expect(second.uploadedPDFs == 0)
        #expect(second.alreadyPresentPDFs == 2)
        #expect(try await folder.listSnapshots().count == 2)
        for _ in 0..<10 { _ = try await service.backUp(to: folder, includePDFs: false) }
        let snapshots = try await folder.listSnapshots()
        #expect(snapshots.count == SnapshotRetention.defaultKeepCount)
        #expect(Support.temporaryEntries(service).isEmpty)

        // Restore the newest snapshot (no embedded PDFs) into a fresh store: PDFs from the folder.
        let restoring = Support.makeService(target, scratch: scratch)
        let session = try await restoring.openBackup(try #require(snapshots.first), from: folder)
        #expect(!session.manifest.includesPDFs)
        #expect(session.destinationPDFHashes.count == 2)
        #expect(session.plan.items.allSatisfy { $0.pdfSource == .destination })
        let summary = try await restoring.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(summary.restored.count == 2 && summary.needingPDF.isEmpty)
        for book in [seeded.small, seeded.noOutline] {
            #expect(try Support.archive(target, book.id) == (try Support.archive(source, book.id)))
            #expect(Support.files(in: target.bookDirectoryURL(bookID: book.id))
                    == Support.files(in: source.bookDirectoryURL(bookID: book.id)))
        }
        #expect(Support.temporaryEntries(restoring).isEmpty)
    }

    // MARK: Replacing books in the Library

    @Test func restoreReplacesTheSameIDOnDiskAndSurvivesReopening() async throws {
        let scratch = try Support.scratch("BackupReplace")
        let root = scratch.appendingPathComponent("Store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let backedUp: BookArchive
        let untouched: BookArchive
        let seeded: BackupTestSupport.Seeded
        let localPDF: Data
        do {
            let store = try LibraryStore.live(rootDirectory: root)
            seeded = try await Support.seedLibrary(store)
            let service = Support.makeService(store, scratch: scratch)
            let file = try await service.backUpToFile(includePDFs: false)
            backedUp = try #require(try Support.archive(store, seeded.small.id))

            // Change both books locally after the backup.
            try store.notes.save(Note(bookID: seeded.small.id, target: .page(11), text: "written after the backup"))
            try store.highlights.save(Highlight(bookID: seeded.small.id, pageIndex: 3, rects: [], color: .blue, text: "later"))
            var small = try #require(try store.books.book(id: seeded.small.id))
            small.lastReadPageIndex = 10
            small.title = "Renamed locally"
            try store.books.save(small)
            try await store.savePageInk(Support.inkData("after"), bookID: small.id, pageIndex: 2, origin: nil)
            try store.notes.save(Note(bookID: seeded.noOutline.id, target: .page(30), text: "other book, later"))
            untouched = try #require(try Support.archive(store, seeded.noOutline.id))
            let untouchedFiles = Support.files(in: store.bookDirectoryURL(bookID: seeded.noOutline.id))
            localPDF = try Data(contentsOf: store.documentURL(for: small))

            var events: [StoreChange] = []
            let token = store.hub.observe { events.append($0.change) }
            let session = try await service.openBackup(at: file.url)
            let item = try #require(session.plan.items.first { $0.id == seeded.small.id })
            #expect(item.status == .inLibrary && item.isSelectedByDefault && item.defaultAction == .merge)
            #expect(item.replacedBookIDs == [seeded.small.id])
            #expect(item.pdfSource == .localBook(seeded.small.id))
            // Only the first book is ticked; the backup has no PDFs, so the local one is reused.
            let summary = try await service.restore([seeded.small.id], from: session, restorePDFs: true)
            session.close()
            token.cancel()
            #expect(summary.failures.isEmpty)
            #expect(summary.restored.map(\.id) == [seeded.small.id])
            #expect(summary.needingPDF.isEmpty)
            #expect(events.contains(.bookDeleted(bookID: seeded.small.id)))
            #expect(events.last == .bookSaved(bookID: seeded.small.id))

            #expect(try Support.archive(store, seeded.small.id) == backedUp)
            #expect(try Data(contentsOf: store.documentURL(for: backedUp.book)) == localPDF)
            #expect(try Support.archive(store, seeded.noOutline.id) == untouched)
            #expect(Support.files(in: store.bookDirectoryURL(bookID: seeded.noOutline.id)) == untouchedFiles)
            #expect(try await store.pageInk(bookID: seeded.small.id, pageIndex: 2) == Support.inkData("S-page-2"))
            #expect(Support.restoresDirectoryIsGone(store))
        }
        // Reopen the on-disk store: the delete-and-reinsert of the same IDs in one save stuck.
        let reopened = try LibraryStore.live(rootDirectory: root)
        #expect(try Support.archive(reopened, seeded.small.id) == backedUp)
        #expect(try Support.archive(reopened, seeded.noOutline.id) == untouched)
        #expect(try reopened.books.allBooks().count == 2)
        #expect(try reopened.notes.noteCount(bookID: seeded.small.id) == backedUp.notes.count)
        #expect(try Data(contentsOf: reopened.documentURL(for: backedUp.book)) == localPDF)
        #expect(try await reopened.sweepOrphanedBookDirectories().isEmpty)
    }

    @Test func restoreReplacesABookWithTheSameFingerprintAndAnotherID() async throws {
        let scratch = try Support.scratch("BackupReplace")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let seeded = try await Support.seedLibrary(source)
        let file = try await Support.makeService(source, scratch: scratch).backUpToFile(includePDFs: false)

        // The target imported the same PDF on its own: same fingerprint, another ID.
        let importer = ImportService(store: target)
        let local = try #require(try await importer.importPDF(at: Support.small).book)
        let other = try #require(try await importer.importPDF(at: Support.noOutline).book)
        try target.notes.save(Note(bookID: local.id, target: .page(0), text: "local copy note"))
        #expect(local.id != seeded.small.id && local.fingerprint == seeded.small.fingerprint)
        let otherState = try Support.archive(target, other.id)

        let service = Support.makeService(target, scratch: scratch)
        let session = try await service.openBackup(at: file.url)
        let item = try #require(session.plan.items.first { $0.id == seeded.small.id })
        #expect(item.status == .inLibrary)
        #expect(item.replacedBookIDs == [local.id])
        let summary = try await service.restore([seeded.small.id], from: session, restorePDFs: false)
        session.close()
        #expect(summary.restored.map(\.id) == [seeded.small.id])
        #expect(summary.needingPDF.isEmpty)
        #expect(try target.books.book(id: local.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: target.bookDirectoryURL(bookID: local.id).path))
        #expect(try Support.archive(target, seeded.small.id) == (try Support.archive(source, seeded.small.id)))
        #expect(target.hasDocument(seeded.small))
        #expect(try Data(contentsOf: target.documentURL(for: seeded.small)) == (try Data(contentsOf: Support.small)))
        // The unselected book of the backup and the other local book are untouched.
        #expect(try target.books.book(id: seeded.noOutline.id) == nil)
        #expect(try Support.archive(target, other.id) == otherState)
        #expect(try await target.sweepOrphanedBookDirectories().isEmpty)
    }

    // MARK: Damaged backups

    @Test func aFlippedByteOrATruncatedFileRestoresNothing() async throws {
        let scratch = try Support.scratch("BackupDamaged")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let seeded = try await Support.seedLibrary(store)
        let service = Support.makeService(store, scratch: scratch)
        let file = try await service.backUpToFile(includePDFs: false)
        // The library moves on, so a restore would visibly change it.
        try store.notes.save(Note(bookID: seeded.small.id, target: .page(8), text: "after the backup"))
        try await store.savePageInk(Support.inkData("later"), bookID: seeded.noOutline.id, pageIndex: 2, origin: nil)
        let before = try Support.libraryState(store)

        // One byte of one ink file flipped inside the archive.
        var bytes = try Data(contentsOf: file.url)
        let marker = Support.inkData("N-page-9", size: 9000)
        let range = try #require(bytes.range(of: marker))
        bytes[range.lowerBound + 100] ^= 0x01
        let flipped = scratch.appendingPathComponent("flipped.ttbackup")
        try bytes.write(to: flipped)
        let session = try await service.openBackup(at: flipped)
        await #expect(throws: BackupServiceError.self) {
            _ = try await service.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        }
        session.close()
        #expect(try Support.libraryState(store) == before)
        #expect(Support.restoresDirectoryIsGone(store))

        // The same file cut short does not even open.
        let original = try Data(contentsOf: file.url)
        let truncated = scratch.appendingPathComponent("truncated.ttbackup")
        try original.prefix(original.count * 2 / 3).write(to: truncated)
        await #expect(throws: BackupError.self) { _ = try await service.openBackup(at: truncated) }
        #expect(try Support.libraryState(store) == before)
        #expect(Support.restoresDirectoryIsGone(store))
        #expect(!service.isBusy)
    }

    // MARK: hasInk

    @Test func hasInkFollowsTheInkFilesAndEmptyNotesAreDropped() async throws {
        let scratch = try Support.scratch("BackupInk")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let book = try #require(try await ImportService(store: source).importPDF(at: Support.small).book)
        let claimsInk = Note(bookID: book.id, target: .page(1), text: "text stays", hasInk: true)
        let onlyInk = Note(bookID: book.id, target: .page(2), text: "  \n", hasInk: true)
        let hasFile = Note(bookID: book.id, target: .page(3), text: "file but no flag", hasInk: false)
        let consistent = Note(bookID: book.id, target: .page(4), text: "ink and flag", hasInk: true)
        for note in [claimsInk, onlyInk, hasFile, consistent] { try source.notes.save(note) }
        try await source.saveNoteInk(Support.inkData("file"), bookID: book.id, noteID: hasFile.id, origin: nil)
        try await source.saveNoteInk(Support.inkData("both"), bookID: book.id, noteID: consistent.id, origin: nil)

        let file = try await Support.makeService(source, scratch: scratch).backUpToFile(includePDFs: false)
        let service = Support.makeService(target, scratch: scratch)
        let session = try await service.openBackup(at: file.url)
        let summary = try await service.restore([book.id], from: session, restorePDFs: true)
        session.close()
        #expect(summary.droppedEmptyNotes == 1)
        #expect(try target.notes.note(id: claimsInk.id)?.hasInk == false)
        #expect(try target.notes.note(id: claimsInk.id)?.text == "text stays")
        #expect(try target.notes.note(id: onlyInk.id) == nil)
        #expect(try target.notes.note(id: hasFile.id)?.hasInk == true)
        #expect(try target.notes.note(id: consistent.id) == consistent)
        #expect(try await target.noteInk(bookID: book.id, noteID: hasFile.id) == Support.inkData("file"))
    }

    // MARK: Jobs

    @Test func oneJobAtATime() async throws {
        let scratch = try Support.scratch("BackupBusy")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        _ = try await Support.seedLibrary(store)
        let latch = TestLatch()
        let service = BackupService(store: store, temporaryRoot: scratch.appendingPathComponent("tmp"),
                                    defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    flushEditors: { await latch.wait() })
        let first = Task { try await service.backUpToFile(includePDFs: false) }
        #expect(await Support.waitUntil { latch.arrivals == 1 })
        #expect(service.job?.kind == .backUpToFile)
        #expect(service.job?.phase == .savingOpenBooks)
        await #expect(throws: BackupServiceError.busy) { _ = try await service.backUpToFile(includePDFs: true) }
        await #expect(throws: BackupServiceError.busy) { _ = try await service.openBackup(at: scratch) }
        latch.open()
        let result = try await first.value
        #expect(!service.isBusy)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        service.discardTemporaryFile(result.url)
        #expect(Support.temporaryEntries(service).isEmpty)
    }

    @Test func cancellingMidBackupLeavesNoTemporaryFiles() async throws {
        let scratch = try Support.scratch("BackupCancel")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let seeded = try await Support.seedLibrary(store)
        // A big file in a book's directory makes the archive slow enough to cancel mid-write.
        let pad = store.bookDirectoryURL(bookID: seeded.small.id).appendingPathComponent("ink/pad.bin")
        FileManager.default.createFile(atPath: pad.path, contents: nil)
        let handle = try FileHandle(forWritingTo: pad)
        let chunk = Data(repeating: 0x5A, count: 4 * 1024 * 1024)
        for _ in 0..<96 { try handle.write(contentsOf: chunk) }
        try handle.close()

        let service = Support.makeService(store, scratch: scratch)
        let running = Task { try await service.backUpToFile(includePDFs: true) }
        #expect(await Support.waitUntil { service.job?.phase == .writingBackup && (service.job?.fraction ?? 0) > 0.01 })
        #expect(Support.temporaryEntries(service).count == 1)
        service.job?.cancel()
        await #expect(throws: CancellationError.self) { _ = try await running.value }
        #expect(!service.isBusy)
        #expect(Support.temporaryEntries(service).isEmpty)
    }

    @Test func notEnoughFreeSpaceIsRefusedBeforeStarting() async throws {
        let scratch = try Support.scratch("BackupSpace")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        _ = try await Support.seedLibrary(store)
        let service = Support.makeService(store, scratch: scratch)
        let estimate = try await service.estimateSizes()
        service.availableCapacity = { _ in estimate.notesAndInk + BackupService.spaceMargin + 1 }
        // Enough for notes and ink only, not with the PDFs.
        do {
            _ = try await service.backUpToFile(includePDFs: true)
            Issue.record("expected notEnoughSpace")
        } catch let error as BackupServiceError {
            guard case .notEnoughSpace(let required, let available) = error else { Issue.record("\(error)"); return }
            #expect(required > available)
            #expect(error.localizedDescription.contains("free"))
        }
        #expect(Support.temporaryEntries(service).isEmpty)
        let small = try await service.backUpToFile(includePDFs: false)
        service.discardTemporaryFile(small.url)
        #expect(Support.temporaryEntries(service).isEmpty)
    }
}
