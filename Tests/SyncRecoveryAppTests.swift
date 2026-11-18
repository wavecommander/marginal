import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync
import Testing
import UIKit
@testable import TactileTexts

/// C5 in the app: Recently Deleted and earlier versions between two real libraries, the safety
/// copy and Undo Last Restore, and housekeeping driven by `SyncService` (once a day, never in a
/// pull-only round), with the folder store's dates.
@MainActor
@Suite(.serialized)
struct SyncRecoveryAppTests {
    typealias S = SyncTestSupport
    typealias Merge = BackupMergeTestSupport

    private let date = Date(timeIntervalSinceReferenceDate: 790_000_000)

    private func access(_ folder: URL, mode: SyncMode = .full, objects: any SyncObjectStore) -> LocalSyncAccess {
        LocalSyncAccess(accountID: "account-1", store: objects, blobStore: FolderBackupBlobStore(root: folder),
                        keyStore: InMemoryBackupKeyStore(key: S.key), mode: mode,
                        temporaryDirectory: folder.appendingPathComponent("tmp"))
    }

    private func service(_ device: SyncTestDevice, access: LocalSyncAccess, scratch: URL) -> (SyncService, BackupService) {
        let sync = SyncService(library: device.core, access: access, root: device.store.rootDirectory.appendingPathComponent("Sync"))
        let backups = BackupTestSupport.makeService(device.store, scratch: scratch.appendingPathComponent(device.name))
        sync.backupService = backups
        return (sync, backups)
    }

    // MARK: Recently Deleted

    @Test func aDeletedBookComesBackFromRecentlyDeletedOnTheOtherDeviceWithItsNotesAndInk() async throws {
        let objects = InMemorySyncObjectStore()
        let a = try SyncTestDevice("A", objects: objects), b = try SyncTestDevice("B", objects: objects)
        defer { a.cleanUp(); b.cleanUp() }
        let bookA = try await a.importBook()
        let bookB = try await b.importBook()
        try await S.settle([a, b], objects: objects, "start")
        try a.store.notes.save(Note(bookID: bookA.id, target: .page(2), text: "Kept through the deletion", createdAt: date))
        try a.store.highlights.save(Highlight(bookID: bookA.id, pageIndex: 1, rects: [CGRect(x: 10, y: 20, width: 90, height: 12)],
                                              color: .green, text: "marked", createdAt: date))
        let pageStroke = S.stroke(80)
        try await S.addPageInk(a, bookA.id, page: 5, [pageStroke])
        _ = try await Merge.writeNote(a.store, bookA.id, target: .page(6), text: "Inked\nnote", strokesOver: [1])
        try await S.settle([a, b], objects: objects, "edits")

        // B deletes it; it goes from A too.
        try await b.store.deleteBook(id: bookB.id, origin: nil)
        try await S.settle([a, b], objects: objects, "deleted on B")
        #expect(try a.store.books.allBooks().isEmpty)

        // A, the other device, finds it in Recently Deleted and restores it.
        let listed = try await a.engine.recentlyDeleted()
        #expect(listed.map(\.title) == [bookA.title])
        #expect(listed.first?.deviceName == "B")
        try await a.engine.restoreDeleted(bookKey: try #require(listed.first).bookKey)
        let back = try #require(try a.store.books.allBooks().first, "made here at once")
        let archive = try a.archive(back)
        #expect(archive.notes.contains { $0.text == "Kept through the deletion" })
        #expect(archive.highlights.map(\.text) == ["marked"])
        #expect(try await a.pageStrokes(back.id, page: 5) == [StrokeIdentity(pageStroke)])
        let inked = try #require(archive.notes.first { $0.target == .page(6) })
        #expect(inked.hasInk)
        let inkHere = try await S.noteInk(a, inked)
        #expect(inkHere != nil)
        #expect(!a.store.hasDocument(back), "its PDF downloads as the setting says")

        // B gets it back with its next round, with everything.
        try await b.sync()
        let atB = try #require(try b.store.books.allBooks().first)
        #expect(try b.archive(atB).notes.contains { $0.text == "Kept through the deletion" })
        #expect(try await b.pageStrokes(atB.id, page: 5) == [StrokeIdentity(pageStroke)])
        try await S.settle([a, b], objects: objects, "after the restore")
        try await S.expectEqual(a, b, "after the restore")
        #expect(try await a.engine.recentlyDeleted().isEmpty)
    }

    // MARK: Earlier versions

    @Test func restoringAnEarlierVersionKeepsASafetyCopyReachesTheOtherDeviceAndCanBeUndone() async throws {
        let scratch = try BackupTestSupport.scratch("SyncEarlier")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let objects = InMemorySyncObjectStore()
        let a = try SyncTestDevice("A", objects: objects), b = try SyncTestDevice("B", objects: objects)
        defer { a.cleanUp(); b.cleanUp() }
        let account = scratch.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let (syncA, _) = service(a, access: access(account, objects: objects), scratch: scratch)
        let (syncB, backupsB) = service(b, access: access(account, objects: objects), scratch: scratch)
        let bookA = try await a.importBook()
        let bookB = try await b.importBook()
        await syncA.confirmJoin()
        await syncB.confirmJoin()

        // Version 1: one note. Then, an hour later: another note and page ink.
        try a.store.notes.save(Note(bookID: bookA.id, target: .page(1), text: "First", createdAt: date))
        await syncA.syncNow()
        objects.advance(by: 3_600)
        try a.store.notes.save(Note(bookID: bookA.id, target: .page(3), text: "Second", createdAt: date))
        try await S.addPageInk(a, bookA.id, page: 4, [S.stroke(60)])
        await syncA.syncNow()
        objects.advance(by: 3_600)
        await syncB.syncNow()
        #expect(Set(try b.archive(bookB).notes.map(\.text)) == ["First", "Second"])

        let versions = try await syncB.versions(bookID: bookB.id)
        let target = try #require(versions.first { $0.summary?.notes == 1 }, "\(versions)")
        #expect(target.summary?.inkedPages == 0)
        #expect(await syncB.currentSummary(bookID: bookB.id)
                == SyncContentSummary(notes: 2, highlights: 0, bookmarks: 0, headings: 0, inkedPages: 1))

        // Not while the reader is working in it: refused, no safety copy, nothing changed.
        let first = try #require(try b.archive(bookB).notes.first { $0.text == "First" })
        b.editors.busy[bookB.id] = SyncBusyEditors(notes: [first.id])
        await #expect(throws: SyncRestoreError.bookBusy) {
            try await syncB.restoreEarlierVersion(bookID: bookB.id, version: target.version, versionDate: Date())
        }
        #expect(backupsB.latestRestoreSafetyRecord() == nil)
        b.editors.busy = [:]

        // Restored here at once, with a safety copy Undo Last Restore uses.
        let plan = try await syncB.restoreEarlierVersion(bookID: bookB.id, version: target.version, versionDate: Date())
        #expect(plan?.restored.notes == 1 && plan?.current.notes == 2)
        #expect(try b.archive(bookB).notes.map(\.text) == ["First"])
        #expect(try await b.store.pageInk(bookID: bookB.id, pageIndex: 4) == nil)
        let record = try #require(backupsB.latestRestoreSafetyRecord())
        #expect(record.changedBooks.map(\.currentID) == [bookB.id])

        // It reaches A as ordinary changes, the removals included.
        await syncB.syncNow()
        await syncA.syncNow()
        #expect(try a.archive(bookA).notes.map(\.text) == ["First"])
        #expect(try await a.store.pageInk(bookID: bookA.id, pageIndex: 4) == nil)

        // Undo Last Restore puts B's book back as it was, and sync carries that too.
        _ = try await backupsB.undoLastRestore()
        #expect(Set(try b.archive(bookB).notes.map(\.text)) == ["First", "Second"])
        #expect(try await b.store.pageInk(bookID: bookB.id, pageIndex: 4) != nil)
        await syncB.syncNow()
        await syncA.syncNow()
        #expect(Set(try a.archive(bookA).notes.map(\.text)) == ["First", "Second"])
        #expect(try await a.store.pageInk(bookID: bookA.id, pageIndex: 4) != nil)
    }

    // MARK: Housekeeping

    @Test func housekeepingRemovesAnOldOrphanKeepsAFreshOneAndAPDFASnapshotNeedsOnceADay() async throws {
        let scratch = try BackupTestSupport.scratch("SyncHousekeeping")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let objects = InMemorySyncObjectStore()
        let a = try SyncTestDevice("A", objects: objects), b = try SyncTestDevice("B", objects: objects)
        defer { a.cleanUp(); b.cleanUp() }
        let account = scratch.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let (syncA, _) = service(a, access: access(account, objects: objects), scratch: scratch)
        let (syncB, _) = service(b, access: access(account, mode: .pullOnly, objects: objects), scratch: scratch)
        _ = try await a.importBook()
        await syncA.confirmJoin()
        let firstRun = try #require(syncA.lastHousekeeping)
        #expect(!firstRun.removedAnything)
        let store = await a.engine.store

        // A snapshot backup in the account that refers to `no-outline.pdf`, which no book here has.
        let source = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: source.rootDirectory) }
        _ = try await ImportService(store: source).importPDF(at: BackupTestSupport.noOutline)
        let destination = EncryptedBackupDestination(id: "cloud", displayName: "Cloud", store: FolderBackupBlobStore(root: account),
                                                     key: S.key, temporaryDirectory: scratch.appendingPathComponent("enc"))
        _ = try await BackupTestSupport.makeService(source, scratch: scratch.appendingPathComponent("source"))
            .backUp(to: destination, includePDFs: false)
        // The sync store holds that PDF and another nothing refers to, and two orphaned blobs.
        let needed = try ContentHash.digest(ofFileAt: BackupTestSupport.noOutline)
        try await store.uploadPDF(fileAt: BackupTestSupport.noOutline, content: needed)
        let lonelyData = Data("%PDF-1.7 nothing refers to this\n%%EOF\n".utf8)
        let lonelyFile = scratch.appendingPathComponent("lonely.pdf")
        try lonelyData.write(to: lonelyFile)
        let lonely = try ContentHash.digest(ofFileAt: lonelyFile)
        try await store.uploadPDF(fileAt: lonelyFile, content: lonely)
        let old = try store.blobKey(sha256: try await store.putBlob(Data("old orphan".utf8)).sha256)
        objects.advance(by: 8 * 86_400)
        let fresh = try store.blobKey(sha256: try await store.putBlob(Data("fresh orphan".utf8)).sha256)

        // Within a day of the last run: nothing runs.
        await syncA.syncNow()
        #expect(objects.keys.contains(old))
        // A day later (by this device's clock): the run removes the old orphan and the lonely PDF.
        let marker = try syncA.accountDirectory("account-1").appendingPathComponent("housekeeping/last-run")
        try Data("\(Date().addingTimeInterval(-2 * 86_400).timeIntervalSinceReferenceDate)\n".utf8).write(to: marker)
        await syncA.syncNow()
        let run = try #require(syncA.lastHousekeeping)
        #expect(run.outcome == .finished && run.removedBlobs == 1 && run.removedPDFs == 1, "\(run)")
        #expect(!objects.keys.contains(old))
        #expect(objects.keys.contains(fresh))
        #expect(objects.keys.contains(try store.pdfKey(sha256: needed.sha256)), "a snapshot still needs it")
        #expect(!objects.keys.contains(try store.pdfKey(sha256: lonely.sha256)))

        // A pull-only device never runs it.
        _ = try await b.importBook()
        await syncB.confirmJoin()
        #expect(syncB.lastHousekeeping == nil)
    }

    /// A blob store that removes every PDF just before a snapshot is uploaded: housekeeping on
    /// another device deciding a PDF this backup relies on is unreferenced.
    private final class VanishingPDFStore: BackupBlobStore, @unchecked Sendable {
        let inner: FolderBackupBlobStore
        init(root: URL) { inner = FolderBackupBlobStore(root: root) }
        func availability() async -> BackupDestinationAvailability { await inner.availability() }
        func list(_ folder: BackupBlobFolder) async throws -> [BackupBlobInfo] { try await inner.list(folder) }
        func size(of key: BackupBlobKey) async throws -> Int64? { try await inner.size(of: key) }
        func upload(from file: URL, to key: BackupBlobKey, progress: BackupProgress?) async throws {
            if key.folder == .backups {
                for pdf in try await inner.list(.pdfs) { try await inner.delete(.pdf(pdf.name)) }
            }
            try await inner.upload(from: file, to: key, progress: progress)
        }
        func download(_ key: BackupBlobKey, to file: URL, progress: BackupProgress?) async throws {
            try await inner.download(key, to: file, progress: progress)
        }
        func delete(_ key: BackupBlobKey) async throws { try await inner.delete(key) }
    }

    @Test func aBackupPutsBackAPDFItReliedOnThatWasRemovedMeanwhile() async throws {
        let scratch = try BackupTestSupport.scratch("BackupVanishingPDF")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: library.rootDirectory) }
        _ = try await ImportService(store: library).importPDF(at: BackupTestSupport.small)
        let root = scratch.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plain = EncryptedBackupDestination(id: "cloud", displayName: "Cloud", store: FolderBackupBlobStore(root: root), key: S.key,
                                               temporaryDirectory: scratch.appendingPathComponent("enc"))
        let service = BackupTestSupport.makeService(library, scratch: scratch)
        #expect(try await service.backUp(to: plain, includePDFs: true).uploadedPDFs == 1)
        // The second backup finds the PDF there, relies on it, and it is removed before its snapshot lands.
        let vanishing = EncryptedBackupDestination(id: "cloud", displayName: "Cloud", store: VanishingPDFStore(root: root), key: S.key,
                                                   temporaryDirectory: scratch.appendingPathComponent("enc"))
        let second = try await service.backUp(to: vanishing, includePDFs: true)
        #expect(second.uploadedPDFs == 0 && second.alreadyPresentPDFs == 1)
        let book = try #require(try library.books.allBooks().first)
        let digest = try #require(library.storedContentDigest(bookID: book.id))
        #expect(try await plain.hasPDF(sha256: digest.sha256, size: digest.size), "put back after the snapshot")
    }

    @Test func theFolderStoreReportsWhenEachObjectWasWritten() async throws {
        let scratch = try BackupTestSupport.scratch("SyncFolderDates")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try FolderSyncObjectStore(root: scratch)
        _ = try await store.put(Data("a".utf8), at: "Sync/v1/blobs/a", metadata: [:], condition: nil)
        let listed = try #require(try await store.list(prefix: "Sync/").first?.lastModified)
        #expect(abs(listed.timeIntervalSinceNow) < 60)
        #expect(try await store.head("Sync/v1/blobs/a")?.lastModified == listed)
        // Writing it again (the same bytes) moves the date.
        let file = scratch.appendingPathComponent("objects").appendingPathComponent(FolderSyncObjectStore.name(for: "Sync/v1/blobs/a"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: file.path)
        #expect(try await store.head("Sync/v1/blobs/a")!.lastModified! < Date(timeIntervalSinceNow: -9 * 86_400))
        _ = try await store.put(Data("a".utf8), at: "Sync/v1/blobs/a", metadata: [:], condition: nil)
        #expect(abs(try await store.head("Sync/v1/blobs/a")!.lastModified!.timeIntervalSinceNow) < 60)
    }

    // MARK: Words

    @Test func theWordsNameTheDeviceAndTheDaysLeft() {
        let here = UUID(), there = UUID()
        let book = SyncDeletedBook(bookKey: String(repeating: "a", count: 64), title: "Strang", deletedAt: date,
                                   deviceID: here, deviceName: "Ben’s iPad", version: 3)
        #expect(SyncRecoveryText.deletedLine(book, thisDeviceID: here, kind: .iPad).hasPrefix("Deleted on this iPad, "))
        #expect(SyncRecoveryText.deletedLine(book, thisDeviceID: here, kind: .iPhone).hasPrefix("Deleted on this iPhone, "))
        #expect(SyncRecoveryText.deletedLine(book, thisDeviceID: there).hasPrefix("Deleted on Ben’s iPad, "))
        var nameless = book
        nameless.deviceName = " "
        #expect(SyncRecoveryText.deletedLine(nameless, thisDeviceID: there).hasPrefix("Deleted on another device, "))
        #expect(book.daysLeft(now: date) == 30)
        #expect(book.daysLeft(now: date.addingTimeInterval(29.5 * 86_400)) == 0)
        #expect(SyncRecoveryText.daysLeft(30) == "30 days left")
        #expect(SyncRecoveryText.daysLeft(1) == "1 day left")
        #expect(SyncRecoveryText.daysLeft(0) == "Last day")
        #expect(SyncRecoveryText.summary(SyncContentSummary(notes: 1, highlights: 0, bookmarks: 2, headings: 0, inkedPages: 3))
                == "1 note, 0 highlights, 2 bookmarks, 3 pages with ink")
        let message = SyncRecoveryText.restoreVersionMessage(
            title: "Strang", current: SyncContentSummary(notes: 2, highlights: 1, bookmarks: 0, headings: 0, inkedPages: 1),
            restored: SyncContentSummary(notes: 1, highlights: 0, bookmarks: 0, headings: 0, inkedPages: 1), kind: .iPhone)
        #expect(message.contains("1 note, 0 highlights, 1 page with ink (now 2 notes, 1 highlight, 1 page with ink)"))
        #expect(message.contains("your other devices") && message.contains("this iPhone"))
        #expect(SyncNoticeText.deleteCarried.contains("Recently Deleted") && SyncNoticeText.deleteCarried.contains("30 days"))
    }
}
