import Foundation
import ReaderBackup
import Testing
@testable import ReaderSync

struct EncryptedSyncStoreTests {
    final class Setup: @unchecked Sendable {
        let dir: TemporaryDirectory
        let objects = InMemorySyncObjectStore()
        let sync: EncryptedSyncStore
        let bookKey: String

        init(key: BackupEncryptionKey = sequentialKey) throws {
            dir = try TemporaryDirectory()
            sync = Sample.store(key: key, objects: objects, temporary: dir.url.appendingPathComponent("tmp"))
            bookKey = try sync.bookKey(pdfSHA256: sha256(Sample.pdf))
        }

        func store(key: BackupEncryptionKey) -> EncryptedSyncStore {
            Sample.store(key: key, objects: objects, temporary: dir.url.appendingPathComponent("tmp"))
        }

        var headKey: String { "Sync/v1/books/\(bookKey)" }
        var temporaryFilesAreGone: Bool { dir.files(under: "tmp").isEmpty }
    }

    // MARK: Heads

    @Test func headsAreWrittenWithCompareAndSwapAndReadBack() async throws {
        let s = try Setup()
        #expect(try await s.sync.readHead(bookKey: s.bookKey) == nil)
        let first = Sample.head(version: 1)
        let eTag1 = try await s.sync.writeHead(first, bookKey: s.bookKey, condition: .ifAbsent)
        let read = try #require(try await s.sync.readHead(bookKey: s.bookKey))
        #expect(read == SyncHeadRead(head: first, eTag: eTag1))
        #expect(s.objects.object(s.headKey)?.metadata == ["write-id": first.writeID])
        #expect(s.objects.object(s.headKey)?.eTag == eTag1)

        // A second first head is refused, as is a write over a stale ETag.
        await #expect(throws: SyncError.preconditionFailed(key: s.headKey)) {
            try await s.sync.writeHead(Sample.head(version: 1), bookKey: s.bookKey, condition: .ifAbsent)
        }
        let second = Sample.head(version: 2, previous: 1)
        let eTag2 = try await s.sync.writeHead(second, bookKey: s.bookKey, condition: .ifMatch(eTag: eTag1))
        await #expect(throws: SyncError.preconditionFailed(key: s.headKey)) {
            try await s.sync.writeHead(Sample.head(version: 2, previous: 1), bookKey: s.bookKey, condition: .ifMatch(eTag: eTag1))
        }
        #expect(try await s.sync.readHead(bookKey: s.bookKey) == SyncHeadRead(head: second, eTag: eTag2))
        #expect(try await s.sync.listHeads() == [SyncHeadListing(bookKey: s.bookKey, eTag: eTag2,
                                                                 size: Int64(s.objects.object(s.headKey)!.data.count),
                                                                 lastModified: s.objects.now)])
        #expect(s.temporaryFilesAreGone)
    }

    @Test func concurrentHeadWritersHaveOneWinner() async throws {
        let s = try Setup()
        let base = try await s.sync.writeHead(Sample.head(version: 1), bookKey: s.bookKey, condition: .ifAbsent)
        let winners = Collected<SyncHead>()
        let refused = Collected<Int>()
        await withTaskGroup(of: Void.self) { group in
            for device in 0..<12 {
                group.addTask {
                    let head = Sample.head(version: 2, previous: 1)
                    do {
                        try await s.sync.writeHead(head, bookKey: s.bookKey, condition: .ifMatch(eTag: base))
                        winners.append(head)
                    } catch SyncError.preconditionFailed {
                        refused.append(device)
                    } catch {
                        Issue.record("unexpected \(error)")
                    }
                }
            }
        }
        #expect(winners.values.count == 1 && refused.values.count == 11)
        #expect(try await s.sync.readHead(bookKey: s.bookKey)?.head == winners.values.first)
    }

    @Test func listingSkipsWhatIsNotAHead() async throws {
        let s = try Setup()
        try await s.sync.writeHead(Sample.head(), bookKey: s.bookKey, condition: .ifAbsent)
        s.objects.setObject(Data("x".utf8), at: "Sync/v1/books/not-a-key")
        s.objects.setObject(Data("x".utf8), at: "Sync/v1/books/\(s.bookKey)/nested")
        s.objects.setObject(Data("x".utf8), at: "Sync/v1/blobs/\(s.bookKey)")
        #expect(try await s.sync.listHeads().map(\.bookKey) == [s.bookKey])
        #expect(s.objects.calls.last?.operation == .list, "one listing")
    }

    @Test func aHeadMovedToAnotherBookOrIntoHistoryIsRefused() async throws {
        let s = try Setup()
        let head = Sample.head(version: 1)
        try await s.sync.writeHead(head, bookKey: s.bookKey, condition: .ifAbsent)
        let sealed = try #require(s.objects.object(s.headKey)?.data)

        // Renamed to another book's key.
        let otherKey = try s.sync.bookKey(pdfSHA256: sha256(Data("another PDF".utf8)))
        s.objects.setObject(sealed, at: "Sync/v1/books/\(otherKey)")
        await #expect(throws: SyncError.objectDamaged(key: "Sync/v1/books/\(otherKey)")) {
            try await s.sync.readHead(bookKey: otherKey)
        }
        // Passed off as a history object.
        let historyKey = "Sync/v1/history/\(s.bookKey)/1"
        s.objects.setObject(sealed, at: historyKey)
        await #expect(throws: SyncError.objectDamaged(key: historyKey)) {
            try await s.sync.readHistory(bookKey: s.bookKey, version: 1)
        }
        // A history object at another version's name.
        try await s.sync.writeHistory(head, bookKey: s.bookKey)
        s.objects.setObject(try #require(s.objects.object(historyKey)?.data), at: "Sync/v1/history/\(s.bookKey)/2")
        await #expect(throws: SyncError.objectDamaged(key: "Sync/v1/history/\(s.bookKey)/2")) {
            try await s.sync.readHistory(bookKey: s.bookKey, version: 2)
        }
    }

    @Test func aHeadForAnotherPDFCannotBeWrittenUnderThisBook() async throws {
        let s = try Setup()
        let other = Sample.head(pdf: Data("another PDF".utf8))
        await #expect(throws: SyncError.invalidName(s.bookKey)) {
            try await s.sync.writeHead(other, bookKey: s.bookKey, condition: .ifAbsent)
        }
        await #expect(throws: SyncError.invalidHead) {
            try await s.sync.writeHead(Sample.head(version: 2, previous: 2), bookKey: s.bookKey, condition: .ifAbsent)
        }
        #expect(s.objects.keys.isEmpty)
    }

    @Test func tamperedHeadsWrongKeysAndNewerEnvelopesAreRefused() async throws {
        let s = try Setup()
        try await s.sync.writeHead(Sample.head(), bookKey: s.bookKey, condition: .ifAbsent)
        let sealed = [UInt8](try #require(s.objects.object(s.headKey)?.data))
        #expect(Array(sealed[0..<10]) == [0x89, 0x54, 0x54, 0x53, 0x59, 0x4E, 0x0D, 0x0A, 1, 1])

        // A different key: every object reads as damaged.
        let stranger = s.store(key: BackupEncryptionKey.generate())
        await #expect(throws: SyncError.objectDamaged(key: s.headKey)) { try await stranger.readHead(bookKey: s.bookKey) }

        // Any byte changed, the kind changed, the object cut short.
        for index in [0, 8, 9, 10, 42, 60, sealed.count - 1] {
            var bytes = sealed
            bytes[index] ^= index == 8 ? 0x20 : 0x01
            s.objects.setObject(Data(bytes), at: s.headKey)
            await #expect(throws: SyncError.objectDamaged(key: s.headKey)) { try await s.sync.readHead(bookKey: s.bookKey) }
        }
        s.objects.setObject(Data(sealed.prefix(60)), at: s.headKey)
        await #expect(throws: SyncError.objectDamaged(key: s.headKey)) { try await s.sync.readHead(bookKey: s.bookKey) }

        // A newer envelope version is reported as such.
        var newer = sealed
        newer[8] = 2
        s.objects.setObject(Data(newer), at: s.headKey)
        await #expect(throws: SyncError.newerFormatVersion(2)) { try await s.sync.readHead(bookKey: s.bookKey) }

        // A head larger than any head may be is not read.
        s.objects.setObject(Data(count: EncryptedSyncStore.maximumHeadSize + 1), at: s.headKey)
        await #expect(throws: SyncError.objectTooLarge(key: s.headKey, limit: EncryptedSyncStore.maximumHeadSize)) {
            try await s.sync.readHead(bookKey: s.bookKey)
        }
    }

    @Test func aNewerHeadFormatInsideAValidEnvelopeIsReported() async throws {
        let s = try Setup()
        var head = Sample.head()
        head.formatVersion = 2
        // Sealed by this code, as a newer app would: the JSON inside says format 2.
        let sealed = try s.sync.sealHead(head, kind: .head, key: s.headKey, bookKey: s.bookKey)
        s.objects.setObject(sealed, at: s.headKey)
        await #expect(throws: SyncError.newerFormatVersion(2)) { try await s.sync.readHead(bookKey: s.bookKey) }
    }

    // MARK: Ambiguous writes

    @Test func aWriteWhoseAnswerWasLostIsReconciledByItsWriteID() async throws {
        let s = try Setup()
        let eTag1 = try await s.sync.writeHead(Sample.head(version: 1), bookKey: s.bookKey, condition: .ifAbsent)

        // The put committed, but its answer was lost.
        let mine = Sample.head(version: 2, previous: 1)
        s.objects.injectFault(.afterEffect, on: .put)
        await #expect(throws: InMemorySyncObjectStore.InjectedFault.self) {
            try await s.sync.writeHead(mine, bookKey: s.bookKey, condition: .ifMatch(eTag: eTag1))
        }
        // Retrying the same conditional write meets its own head...
        await #expect(throws: SyncError.preconditionFailed(key: s.headKey)) {
            try await s.sync.writeHead(mine, bookKey: s.bookKey, condition: .ifMatch(eTag: eTag1))
        }
        // ...and reading back tells "I already won".
        let committed = try await s.sync.reconcileHeadWrite(bookKey: s.bookKey, writeID: mine.writeID)
        #expect(committed == .committed(eTag: try #require(s.objects.object(s.headKey)?.eTag)))

        // The put never arrived: not committed, and the head is the old one.
        let lost = Sample.head(version: 3, previous: 2)
        guard case .committed(let eTag2) = committed else { return }
        s.objects.injectFault(.beforeEffect, on: .put)
        await #expect(throws: InMemorySyncObjectStore.InjectedFault.self) {
            try await s.sync.writeHead(lost, bookKey: s.bookKey, condition: .ifMatch(eTag: eTag2))
        }
        #expect(try await s.sync.reconcileHeadWrite(bookKey: s.bookKey, writeID: lost.writeID)
                == .notCommitted(currentETag: eTag2))

        // Another device won meanwhile: "someone else did".
        let theirs = Sample.head(version: 3, previous: 2)
        let theirETag = try await s.store(key: sequentialKey).writeHead(theirs, bookKey: s.bookKey, condition: .ifMatch(eTag: eTag2))
        #expect(try await s.sync.reconcileHeadWrite(bookKey: s.bookKey, writeID: lost.writeID)
                == .notCommitted(currentETag: theirETag))

        // Forged plaintext metadata does not make a lost write look committed.
        let stored = try #require(s.objects.object(s.headKey))
        s.objects.setObject(stored.data, at: s.headKey, metadata: ["write-id": lost.writeID])
        guard case .notCommitted = try await s.sync.reconcileHeadWrite(bookKey: s.bookKey, writeID: lost.writeID) else {
            Issue.record("a forged write-id was believed")
            return
        }

        // No head at all.
        let emptyKey = try s.sync.bookKey(pdfSHA256: sha256(Data("nothing".utf8)))
        #expect(try await s.sync.reconcileHeadWrite(bookKey: emptyKey, writeID: mine.writeID) == .notCommitted(currentETag: nil))
    }

    // MARK: History

    @Test func historyRoundTrips() async throws {
        let s = try Setup()
        let heads = (1...3).map { Sample.head(version: $0, previous: $0 == 1 ? nil : $0 - 1) }
        for head in heads { try await s.sync.writeHistory(head, bookKey: s.bookKey) }
        // Version 10 sorts after 9 numerically, not as text.
        let tenth = Sample.head(version: 10, previous: 3)
        try await s.sync.writeHistory(tenth, bookKey: s.bookKey)
        #expect(try await s.sync.historyVersions(bookKey: s.bookKey) == [1, 2, 3, 10])
        #expect(try await s.sync.readHistory(bookKey: s.bookKey, version: 2) == heads[1])
        #expect(try await s.sync.readHistory(bookKey: s.bookKey, version: 10) == tenth)
        #expect(try await s.sync.readHistory(bookKey: s.bookKey, version: 4) == nil)
        try await s.sync.deleteHistory(bookKey: s.bookKey, version: 1)
        #expect(try await s.sync.historyVersions(bookKey: s.bookKey) == [2, 3, 10])
        #expect(s.objects.keys.allSatisfy { $0.hasPrefix("Sync/v1/history/\(s.bookKey)/") })
    }

    // MARK: Blobs

    @Test func blobsArePutOnceAndReadBackVerified() async throws {
        let s = try Setup()
        let ink = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let content = try await s.sync.putBlob(ink)
        #expect(content == digest(ink))
        let key = try s.sync.blobKey(sha256: content.sha256)
        #expect(key == "Sync/v1/blobs/" + (try SyncKeys(key: sequentialKey).blobName(sha256: content.sha256)))
        #expect(s.objects.keys == [key])
        #expect(!key.contains(content.sha256.prefix(16)))
        #expect(try await s.sync.hasBlob(content))
        #expect(try await s.sync.blob(content) == ink)

        // Uploading the same content again is skipped.
        s.objects.clearCalls()
        #expect(try await s.sync.putBlob(ink) == content)
        let file = try s.dir.file("ink.drawing", ink)
        #expect(try await s.sync.putBlob(fileAt: file) == content)
        #expect(s.objects.calls.map(\.operation) == [.head, .head])

        let target = s.dir.url.appendingPathComponent("out/ink.drawing")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await s.sync.downloadBlob(content, to: target)
        #expect(try Data(contentsOf: target) == ink)

        // An empty blob is a blob too.
        let empty = try await s.sync.putBlob(Data())
        #expect(try await s.sync.blob(empty) == Data())

        // Not stored.
        let absent = digest("absent")
        #expect(try await !s.sync.hasBlob(absent))
        await #expect(throws: SyncError.objectNotFound(key: try s.sync.blobKey(sha256: absent.sha256))) {
            try await s.sync.blob(absent)
        }
        try await s.sync.deleteBlob(content)
        #expect(try await !s.sync.hasBlob(content))
        #expect(s.temporaryFilesAreGone)
    }

    @Test func aRenamedTamperedOrForeignBlobIsRefused() async throws {
        let s = try Setup()
        let a = try await s.sync.putBlob(Data("blob A".utf8))
        let b = try await s.sync.putBlob(Data("blob B".utf8))
        let keyA = try s.sync.blobKey(sha256: a.sha256), keyB = try s.sync.blobKey(sha256: b.sha256)
        let sealedA = try #require(s.objects.object(keyA)?.data)

        // Blob A renamed over blob B: authentic, but not the object asked for.
        s.objects.setObject(sealedA, at: keyB)
        await #expect(throws: SyncError.objectDamaged(key: keyB)) { try await s.sync.blob(b) }
        await #expect(throws: SyncError.objectDamaged(key: keyB)) {
            try await s.sync.downloadBlob(b, to: s.dir.url.appendingPathComponent("b"))
        }
        #expect(!FileManager.default.fileExists(atPath: s.dir.url.appendingPathComponent("b").path))

        // A byte changed.
        var tampered = [UInt8](sealedA)
        tampered[tampered.count - 20] ^= 0x01
        s.objects.setObject(Data(tampered), at: keyA)
        await #expect(throws: SyncError.objectDamaged(key: keyA)) { try await s.sync.blob(a) }

        // Another key's blob.
        let stranger = s.store(key: BackupEncryptionKey.generate())
        let c = try await stranger.putBlob(Data("blob C".utf8))
        let keyCForUs = try s.sync.blobKey(sha256: c.sha256)
        s.objects.setObject(try #require(s.objects.object(try stranger.blobKey(sha256: c.sha256))?.data), at: keyCForUs)
        await #expect(throws: SyncError.objectDamaged(key: keyCForUs)) { try await s.sync.blob(c) }
        #expect(s.temporaryFilesAreGone)
    }

    @Test func aBlobWhoseContentIsNotTheOneNamedIsRefused() async throws {
        // The right name and metadata, but the plaintext is other bytes: only someone with the
        // key could make this, but the check holds anyway.
        let s = try Setup()
        let claimed = digest("claimed content")
        let key = try s.sync.blobKey(sha256: claimed.sha256)
        let source = try s.dir.file("other", Data("other content!!".utf8)) // same length, other bytes
        let sealed = s.dir.url.appendingPathComponent("sealed")
        try BackupFileEncryption.encrypt(source, to: sealed, key: SyncKeys(key: sequentialKey).content,
                                         metadata: ["kind": "sync-blob", "object": key, "sha256": claimed.sha256,
                                                    "size": String(claimed.size)])
        s.objects.setObject(try Data(contentsOf: sealed), at: key)
        await #expect(throws: SyncError.contentMismatch(key: key)) { try await s.sync.blob(claimed) }
    }

    @Test func blobKeysAreIndependentOfBackupKeys() async throws {
        // A blob does not open with the reader's key as the master: sync content has its own key.
        let s = try Setup()
        let content = try await s.sync.putBlob(Data("independent".utf8))
        let sealed = try s.dir.file("sealed", try #require(s.objects.object(try s.sync.blobKey(sha256: content.sha256))?.data))
        #expect(throws: BackupError.encryptedObjectDamaged(name: "sealed")) {
            try BackupFileEncryption.decrypt(sealed, to: s.dir.url.appendingPathComponent("plain"), key: sequentialKey)
        }
        let opened = try BackupFileEncryption.decrypt(sealed, to: s.dir.url.appendingPathComponent("plain"),
                                                      key: SyncKeys(key: sequentialKey).content)
        #expect(opened.metadata["kind"] == "sync-blob")
    }

    // MARK: PDFs

    @Test func aPDFIsTheSameObjectBackupsStore() async throws {
        let s = try Setup()
        let file = try s.dir.file("book.pdf", Sample.pdf)
        let pdf = digest(Sample.pdf)
        try await s.sync.uploadPDF(fileAt: file, content: pdf)
        let key = try s.sync.pdfKey(sha256: pdf.sha256)
        #expect(s.objects.keys == [key])
        #expect(try await s.sync.hasPDF(pdf))

        // The encrypted backup destination finds the same object, and it opens as its PDF.
        let root = s.dir.url.appendingPathComponent("backup-store")
        let blobStore = FolderBackupBlobStore(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
        try s.objects.object(key)!.data.write(to: root.appendingPathComponent(key))
        let destination = EncryptedBackupDestination(id: "cloud", displayName: "Cloud", store: blobStore, key: sequentialKey,
                                                     temporaryDirectory: s.dir.url.appendingPathComponent("tmp"),
                                                     availableCapacity: { _ in nil })
        #expect(try await destination.hasPDF(sha256: pdf.sha256, size: pdf.size))
        let viaBackup = s.dir.url.appendingPathComponent("via-backup.pdf")
        try await destination.downloadPDF(sha256: pdf.sha256, to: viaBackup, progress: nil)
        #expect(try Data(contentsOf: viaBackup) == Sample.pdf)

        // And a PDF a backup uploaded is one sync downloads, without uploading it again.
        let other = Data("%PDF-1.4 uploaded by a backup".utf8)
        let otherFile = try s.dir.file("other.pdf", other)
        try await destination.uploadPDF(from: otherFile, sha256: sha256(other), size: Int64(other.count), progress: nil)
        let otherKey = try s.sync.pdfKey(sha256: sha256(other))
        s.objects.setObject(try Data(contentsOf: root.appendingPathComponent(otherKey)), at: otherKey)
        s.objects.clearCalls()
        try await s.sync.uploadPDF(fileAt: otherFile, content: digest(other))
        #expect(s.objects.calls.map(\.operation) == [.head])
        let viaSync = s.dir.url.appendingPathComponent("via-sync.pdf")
        try await s.sync.downloadPDF(digest(other), to: viaSync)
        #expect(try Data(contentsOf: viaSync) == other)
        #expect(s.temporaryFilesAreGone)
    }

    @Test func aPDFThatIsNotTheOneNamedIsRefused() async throws {
        let s = try Setup()
        let file = try s.dir.file("book.pdf", Sample.pdf)
        let wrong = digest("not this PDF")
        await #expect(throws: SyncError.contentMismatch(key: try s.sync.pdfKey(sha256: wrong.sha256))) {
            try await s.sync.uploadPDF(fileAt: file, content: wrong)
        }
        #expect(s.objects.keys.isEmpty)
        // A PDF object moved to another PDF's name.
        try await s.sync.uploadPDF(fileAt: file, content: digest(Sample.pdf))
        let movedTo = try s.sync.pdfKey(sha256: wrong.sha256)
        s.objects.setObject(try #require(s.objects.object(try s.sync.pdfKey(sha256: sha256(Sample.pdf)))?.data), at: movedTo)
        await #expect(throws: SyncError.objectDamaged(key: movedTo)) {
            try await s.sync.downloadPDF(wrong, to: s.dir.url.appendingPathComponent("x.pdf"))
        }
        await #expect(throws: SyncError.objectNotFound(key: try s.sync.pdfKey(sha256: digest("absent").sha256))) {
            try await s.sync.downloadPDF(digest("absent"), to: s.dir.url.appendingPathComponent("y.pdf"))
        }
        #expect(s.temporaryFilesAreGone)
    }
}
