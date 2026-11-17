import Foundation
import Testing
@testable import ReaderBackup

/// A blob store over a directory that records what it is asked to do, and can fail uploads.
final class CountingBlobStore: BackupBlobStore, @unchecked Sendable {
    let inner: FolderBackupBlobStore
    private let lock = NSLock()
    private var downloadLog: [String] = []
    private var uploadLog: [String] = []
    private var deleteLog: [String] = []
    private var uploadFailure: (any Error)?

    init(root: URL) { inner = FolderBackupBlobStore(root: root) }

    var downloads: [String] { lock.withLock { downloadLog } }
    var uploads: [String] { lock.withLock { uploadLog } }
    var deletes: [String] { lock.withLock { deleteLog } }
    func reset() { lock.withLock { downloadLog = []; uploadLog = []; deleteLog = [] } }
    func failUploads(with error: (any Error)?) { lock.withLock { uploadFailure = error } }

    func availability() async -> BackupDestinationAvailability { await inner.availability() }
    func list(_ folder: BackupBlobFolder) async throws -> [BackupBlobInfo] { try await inner.list(folder) }
    func size(of key: BackupBlobKey) async throws -> Int64? { try await inner.size(of: key) }

    func upload(from file: URL, to key: BackupBlobKey, progress: BackupProgress?) async throws {
        let failure: (any Error)? = lock.withLock {
            uploadLog.append(key.path)
            return uploadFailure
        }
        if let failure { throw failure }
        try await inner.upload(from: file, to: key, progress: progress)
    }

    func download(_ key: BackupBlobKey, to file: URL, progress: BackupProgress?) async throws {
        lock.withLock { downloadLog.append(key.path) }
        try await inner.download(key, to: file, progress: progress)
    }

    func delete(_ key: BackupBlobKey) async throws {
        lock.withLock { deleteLog.append(key.path) }
        try await inner.delete(key)
    }
}

struct StoreFailure: LocalizedError, Equatable {
    var errorDescription: String? { "The cloud service is unavailable." }
}

/// A store directory, a temporary directory and destinations over them.
final class EncryptedFixture: @unchecked Sendable {
    let dir: TemporaryDirectory
    let store: CountingBlobStore

    init() throws {
        dir = try TemporaryDirectory()
        let root = dir.url.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CountingBlobStore(root: root)
    }

    var temporaryDirectory: URL { dir.url.appendingPathComponent("tmp", isDirectory: true) }

    func destination(key: BackupEncryptionKey = sequentialKey, capacity: Int64? = nil) -> EncryptedBackupDestination {
        EncryptedBackupDestination(id: "tactile-cloud", displayName: "Tactile Cloud", store: store, key: key,
                                   temporaryDirectory: temporaryDirectory, availableCapacity: { _ in capacity })
    }

    /// Every file in the store with its contents.
    func storeContents() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in dir.allPaths(under: "store") {
            let url = dir.url.appendingPathComponent("store/\(path)")
            if FileOps.regularFileSize(url) != nil { result[path] = try Data(contentsOf: url) }
        }
        return result
    }

    func storePaths(_ folder: String) -> [String] { dir.allPaths(under: "store/\(folder)") }

    /// `true` when the temporary directory holds nothing.
    var temporaryFilesAreGone: Bool { dir.allPaths(under: "tmp").isEmpty }
}

struct EncryptedBackupDestinationTests {
    static let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let newerDate = Date(timeIntervalSince1970: 1_700_090_000)

    @Test func theWholeProtocolOverTheOnDiskStore() async throws {
        let f = try EncryptedFixture()
        let destination = f.destination()
        #expect(destination.id == "tactile-cloud")
        #expect(destination.displayName == "Tactile Cloud")
        #expect(await destination.availability() == .available)
        #expect(try await destination.checkKey() == .nothingStored)
        #expect(try await destination.listSnapshots().isEmpty)

        let older = SnapshotName.make(createdAt: Self.olderDate, deviceName: "Ben’s iPad")
        let newer = SnapshotName.make(createdAt: Self.newerDate, deviceName: "Studio iPad")
        let bigData = pseudoRandomData(count: multiChunkSize, seed: 4)
        let log = ProgressLog()
        let uploaded = try await destination.uploadSnapshot(from: try f.dir.file("local/a", bigData), name: older, progress: log.callback)
        #expect(log.isWellFormed)
        #expect(uploaded.name == older)
        #expect(uploaded.deviceName == "Ben’s iPad")
        #expect(uploaded.createdAt == Self.olderDate)
        #expect(uploaded.byteSize == FileOps.regularFileSize(f.dir.url.appendingPathComponent("store/Backups/\(uploaded.id)")))
        #expect(uploaded.byteSize > Int64(bigData.count))
        let uploadedNewer = try await destination.uploadSnapshot(from: try f.dir.file("local/b", Data("new".utf8)), name: newer, progress: nil)
        #expect(f.storePaths("").contains(EncryptedBackupDestination.keyCheckObjectName), "the first upload wrote the key check")

        // Objects that are not this destination's snapshots are ignored.
        try f.dir.file("store/Backups/notes.txt", Data("x".utf8))
        try f.dir.file("store/Backups/\(older)", Data("a plain backup".utf8))
        try f.dir.file("store/Backups/2020-01-01T00-00-00Z.\(String(repeating: "0", count: 148)).ttenc", Data("forged".utf8))
        try f.dir.file("store/Backups/.hidden.ttenc", Data("x".utf8))
        let listed = try await destination.listSnapshots()
        #expect(listed == [uploadedNewer, uploaded])
        #expect(listed.map(\.name) == [newer, older])

        let downloaded = f.dir.url.appendingPathComponent("downloaded.ttbackup")
        let downloadLog = ProgressLog()
        try await destination.downloadSnapshot(listed[1], to: downloaded, progress: downloadLog.callback)
        #expect(downloadLog.isWellFormed)
        #expect(try Data(contentsOf: downloaded) == bigData)

        try await destination.deleteSnapshot(listed[1])
        #expect(try await destination.listSnapshots() == [uploadedNewer])
        try await destination.deleteSnapshot(listed[1]) // already gone: fine
        await #expect(throws: BackupError.snapshotNotFound(name: older)) {
            try await destination.downloadSnapshot(listed[1], to: downloaded, progress: nil)
        }
        await #expect(throws: BackupError.invalidSnapshotName(name: "../x.ttbackup")) {
            try await destination.uploadSnapshot(from: downloaded, name: "../x.ttbackup", progress: nil)
        }
        let plain = BackupSnapshotInfo(id: older, name: older, createdAt: Self.olderDate, deviceName: "Ben’s iPad", byteSize: 1)
        await #expect(throws: BackupError.invalidSnapshotName(name: older)) {
            try await destination.downloadSnapshot(plain, to: downloaded, progress: nil)
        }

        // PDFs.
        let pdf = pseudoRandomData(count: multiChunkSize, seed: 8)
        let source = try f.dir.file("book.pdf", pdf)
        let digest = try ContentHash.digest(ofFileAt: source)
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size) == false)
        let pdfLog = ProgressLog()
        try await destination.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: pdfLog.callback)
        #expect(pdfLog.isWellFormed)
        #expect(f.storePaths("PDFs").count == 1)
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size))
        #expect(try await destination.hasPDF(sha256: digest.sha256.uppercased(), size: digest.size))
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size + 1) == false)
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size - 1) == false)

        // Already there: skipped (no upload, and the source is not even opened).
        f.store.reset()
        let skipLog = ProgressLog()
        try await destination.uploadPDF(from: f.dir.url.appendingPathComponent("gone.pdf"), sha256: digest.sha256, size: digest.size,
                                        progress: skipLog.callback)
        #expect(f.store.uploads.isEmpty)
        #expect(skipLog.values == [1])

        let local = f.dir.url.appendingPathComponent("restored.pdf")
        try await destination.downloadPDF(sha256: digest.sha256, to: local, progress: nil)
        #expect(try Data(contentsOf: local) == pdf)
        let missing = String(repeating: "ab", count: 32)
        await #expect(throws: BackupError.pdfNotAtDestination(sha256: missing)) {
            try await destination.downloadPDF(sha256: missing, to: local, progress: nil)
        }
        await #expect(throws: BackupError.self) { try await destination.hasPDF(sha256: "../../etc/passwd", size: 1) }

        #expect(f.temporaryFilesAreGone)
        #expect(f.dir.allPaths().filter { $0.contains("partial") }.isEmpty)
    }

    @Test func storedNamesRevealNoDeviceNameAndListingDownloadsNothing() async throws {
        let f = try EncryptedFixture()
        let destination = f.destination()
        let devices = ["Ben’s iPad", "Zoë’s Studio iPad Pro", "ipad"]
        let source = try f.dir.file("snap", Data("snapshot".utf8))
        var uploaded: [BackupSnapshotInfo] = []
        for (index, device) in devices.enumerated() {
            let name = SnapshotName.make(createdAt: Self.olderDate.addingTimeInterval(Double(index)), deviceName: device)
            uploaded.append(try await destination.uploadSnapshot(from: source, name: name, progress: nil))
        }
        let objectNames = f.storePaths("Backups")
        #expect(objectNames.count == 3)
        for device in devices {
            let utf8 = Array(device.utf8)
            let forms = [
                device, device.lowercased(), device.uppercased(), device.replacingOccurrences(of: " ", with: "-"),
                device.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
                hexString(utf8), hexString(utf8).uppercased(),
                Data(utf8).base64EncodedString(), Data(utf8).base64EncodedString().replacingOccurrences(of: "=", with: ""),
                Base32.lowercaseString(utf8), Base32.lowercaseString(utf8).uppercased(),
                "ipad", "iPad", "Studio", "Ben",
            ]
            for objectName in objectNames {
                for form in forms where form.count >= 3 {
                    #expect(!objectName.lowercased().contains(form.lowercased()), "\(form) in \(objectName)")
                }
            }
        }
        // Every object name has the same length whatever the device name (padding).
        #expect(Set(objectNames.map(\.count)).count == 1)

        // The same device name and timestamp give the same object name: uploading again replaces.
        let again = try await destination.uploadSnapshot(from: source, name: uploaded[0].name, progress: nil)
        #expect(again.id == uploaded[0].id)
        #expect(f.storePaths("Backups").count == 3)
        let otherInstance = f.destination()
        #expect(ObjectNames(key: sequentialKey).snapshotObjectName(createdAt: Self.olderDate, deviceName: "Ben’s iPad") == uploaded[0].id)

        // A fresh destination lists real device names; it downloads only the key check, never a
        // snapshot, and once the key is confirmed it downloads nothing at all.
        f.store.reset()
        let listed = try await otherInstance.listSnapshots()
        #expect(listed.map(\.deviceName) == devices.reversed())
        #expect(listed.map(\.name) == uploaded.reversed().map(\.name))
        #expect(f.store.downloads == [EncryptedBackupDestination.keyCheckObjectName])
        f.store.reset()
        _ = try await otherInstance.listSnapshots()
        #expect(f.store.downloads.isEmpty)

        // A device name longer than 64 UTF-8 bytes is listed cut short, the same way upload reports it.
        let longDevice = String(repeating: "日本", count: 20) // 120 bytes after sanitising (60 characters)
        let longInfo = try await destination.uploadSnapshot(from: source, name: SnapshotName.make(createdAt: Self.newerDate, deviceName: longDevice),
                                                            progress: nil)
        #expect(longInfo.deviceName == String(repeating: "日本", count: 10) + "日")
        #expect(try await destination.listSnapshots().first == longInfo)
        #expect(longInfo.id.utf8.count <= 255)

        // An object name moved to another timestamp no longer authenticates.
        let moved = "2019" + uploaded[0].id.dropFirst(4)
        try FileManager.default.moveItem(at: f.dir.url.appendingPathComponent("store/Backups/\(uploaded[0].id)"),
                                         to: f.dir.url.appendingPathComponent("store/Backups/\(moved)"))
        #expect(try await destination.listSnapshots().map(\.id) == [longInfo.id, uploaded[2].id, uploaded[1].id])
    }

    @Test func pdfObjectNamesAreKeyedHashes() async throws {
        let f = try EncryptedFixture()
        let source = try f.dir.file("book.pdf", Data("%PDF-1.7 tiny".utf8))
        let digest = try ContentHash.digest(ofFileAt: source)
        try await f.destination().uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        let stored = f.storePaths("PDFs")
        #expect(stored.count == 1)
        #expect(!stored[0].contains(digest.sha256))
        #expect(!stored[0].contains(String(digest.sha256.prefix(16))))
        #expect(stored[0].hasSuffix(".ttenc"))
        let other = BackupEncryptionKey.generate()
        let names = [ObjectNames(key: sequentialKey).pdfObjectName(sha256: digest.sha256),
                     ObjectNames(key: other).pdfObjectName(sha256: digest.sha256)]
        #expect(names[0] == stored[0])
        #expect(names[0] != names[1])
        #expect(ObjectNames(key: other).snapshotObjectName(createdAt: Self.olderDate, deviceName: "iPad")
                != ObjectNames(key: sequentialKey).snapshotObjectName(createdAt: Self.olderDate, deviceName: "iPad"))
    }

    @Test func thePublicPDFNameAndMetadataAreWhatTheDestinationWrites() async throws {
        let f = try EncryptedFixture()
        let source = try f.dir.file("book.pdf", Data("%PDF-1.7 shared with sync".utf8))
        let digest = try ContentHash.digest(ofFileAt: source)
        try await f.destination().uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        let name = try EncryptedBackupDestination.pdfObjectName(sha256: digest.sha256.uppercased(), key: sequentialKey)
        #expect(f.storePaths("PDFs") == [name])
        #expect(name == ObjectNames(key: sequentialKey).pdfObjectName(sha256: digest.sha256))
        let stored = f.dir.url.appendingPathComponent("store/PDFs/\(name)")
        let opened = try BackupFileEncryption.decrypt(stored, to: f.dir.url.appendingPathComponent("opened.pdf"),
                                                      key: sequentialKey)
        #expect(opened.metadata == EncryptedBackupDestination.pdfObjectMetadata(sha256: digest.sha256, size: digest.size,
                                                                                objectName: name))
        #expect(opened.metadata == ["kind": "pdf", "object": name, "sha256": digest.sha256, "size": String(digest.size)])
        #expect(throws: BackupError.pdfNotAtDestination(sha256: "abc")) {
            try EncryptedBackupDestination.pdfObjectName(sha256: "abc", key: sequentialKey)
        }
    }

    @Test func damagedAndSwappedObjectsAreRefused() async throws {
        let f = try EncryptedFixture()
        let destination = f.destination()
        let a = try await destination.uploadSnapshot(from: try f.dir.file("a", Data("snapshot A".utf8)),
                                                     name: SnapshotName.make(createdAt: Self.olderDate, deviceName: "iPad"), progress: nil)
        let b = try await destination.uploadSnapshot(from: try f.dir.file("b", Data("snapshot B".utf8)),
                                                     name: SnapshotName.make(createdAt: Self.newerDate, deviceName: "iPad"), progress: nil)
        let output = f.dir.url.appendingPathComponent("out")
        func storeURL(_ path: String) -> URL { f.dir.url.appendingPathComponent("store/\(path)") }

        // A damaged byte.
        try flipByte(storeURL("Backups/\(a.id)"), at: 70)
        await #expect(throws: BackupError.encryptedObjectDamaged(name: a.name)) {
            try await destination.downloadSnapshot(a, to: output, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // One snapshot's object copied over another's: authentic, but not the snapshot asked for.
        try FileManager.default.removeItem(at: storeURL("Backups/\(a.id)"))
        try FileManager.default.copyItem(at: storeURL("Backups/\(b.id)"), to: storeURL("Backups/\(a.id)"))
        await #expect(throws: BackupError.encryptedObjectDamaged(name: a.name)) {
            try await destination.downloadSnapshot(a, to: output, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // PDFs: one encrypted PDF renamed over another.
        let pdfA = try f.dir.file("a.pdf", pseudoRandomData(count: 3000, seed: 1))
        let pdfB = try f.dir.file("b.pdf", pseudoRandomData(count: 3000, seed: 2))
        let digestA = try ContentHash.digest(ofFileAt: pdfA)
        let digestB = try ContentHash.digest(ofFileAt: pdfB)
        try await destination.uploadPDF(from: pdfA, sha256: digestA.sha256, size: digestA.size, progress: nil)
        try await destination.uploadPDF(from: pdfB, sha256: digestB.sha256, size: digestB.size, progress: nil)
        let names = ObjectNames(key: sequentialKey)
        let objectA = storeURL("PDFs/\(names.pdfObjectName(sha256: digestA.sha256))")
        let objectB = storeURL("PDFs/\(names.pdfObjectName(sha256: digestB.sha256))")
        try FileManager.default.removeItem(at: objectB)
        try FileManager.default.moveItem(at: objectA, to: objectB)
        #expect(try await destination.hasPDF(sha256: digestB.sha256, size: digestB.size), "same size: looks present")
        let mismatchB = BackupError.contentMismatch(name: BackupFolderLayout.pdfFileName(sha256: digestB.sha256))
        await #expect(throws: mismatchB) { try await destination.downloadPDF(sha256: digestB.sha256, to: output, progress: nil) }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // An authentic object whose metadata claims B but whose content is A: the plaintext hash
        // check refuses it.
        try BackupFileEncryption.encrypt(pdfA, to: objectB, key: sequentialKey,
                                         metadata: ["kind": "pdf", "object": names.pdfObjectName(sha256: digestB.sha256),
                                                    "sha256": digestB.sha256, "size": String(digestB.size)])
        await #expect(throws: mismatchB) { try await destination.downloadPDF(sha256: digestB.sha256, to: output, progress: nil) }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // A damaged PDF.
        try FileManager.default.removeItem(at: objectB)
        try await destination.uploadPDF(from: pdfB, sha256: digestB.sha256, size: digestB.size, progress: nil)
        try flipByte(objectB, at: 2000)
        await #expect(throws: BackupError.encryptedObjectDamaged(name: BackupFolderLayout.pdfFileName(sha256: digestB.sha256))) {
            try await destination.downloadPDF(sha256: digestB.sha256, to: output, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(f.temporaryFilesAreGone)
        #expect(f.dir.allPaths().filter { $0.contains("partial") }.isEmpty)
    }

    @Test func theKeyCheckTellsAWrongKeyFromAnEmptyStore() async throws {
        let f = try EncryptedFixture()
        let right = f.destination()
        #expect(try await right.checkKey() == .nothingStored)
        #expect(try f.storeContents().isEmpty, "checking writes nothing")
        let snapshot = try await right.uploadSnapshot(from: try f.dir.file("s", Data("snap".utf8)),
                                                      name: SnapshotName.make(createdAt: Self.olderDate, deviceName: "iPad"), progress: nil)
        let keyCheck = try #require(try f.storeContents()[EncryptedBackupDestination.keyCheckObjectName])
        #expect(keyCheck.count == 49)

        // The same key later, from a new destination value.
        #expect(try await f.destination().checkKey() == .matches)
        #expect(await f.destination().availability() == .available)

        // A different key.
        let wrong = f.destination(key: BackupEncryptionKey.generate())
        #expect(try await wrong.checkKey() == .differentKey)
        #expect(await wrong.availability() == .unavailable(reason: BackupError.wrongEncryptionKey.localizedDescription))
        let before = try f.storeContents()
        f.store.reset()
        let source = try f.dir.file("pdf", Data("pdf".utf8))
        let digest = try ContentHash.digest(ofFileAt: source)
        let output = f.dir.url.appendingPathComponent("out")
        await #expect(throws: BackupError.wrongEncryptionKey) { try await wrong.listSnapshots() }
        await #expect(throws: BackupError.wrongEncryptionKey) {
            try await wrong.uploadSnapshot(from: source, name: SnapshotName.make(createdAt: Self.newerDate, deviceName: "iPad"), progress: nil)
        }
        await #expect(throws: BackupError.wrongEncryptionKey) {
            try await wrong.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        }
        await #expect(throws: BackupError.wrongEncryptionKey) { try await wrong.hasPDF(sha256: digest.sha256, size: digest.size) }
        await #expect(throws: BackupError.wrongEncryptionKey) { try await wrong.downloadPDF(sha256: digest.sha256, to: output, progress: nil) }
        let foreign = BackupSnapshotInfo(id: snapshot.id, name: snapshot.name, createdAt: snapshot.createdAt, deviceName: "iPad", byteSize: 1)
        await #expect(throws: BackupError.wrongEncryptionKey) { try await wrong.downloadSnapshot(foreign, to: output, progress: nil) }
        await #expect(throws: BackupError.wrongEncryptionKey) { try await wrong.deleteSnapshot(foreign) }
        #expect(f.store.uploads.isEmpty)
        #expect(f.store.deletes.isEmpty)
        #expect(try f.storeContents() == before, "nothing in the store changed")
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // Without the key check, the snapshot names are the evidence.
        try FileManager.default.removeItem(at: f.dir.url.appendingPathComponent("store/key-check"))
        #expect(try await f.destination().checkKey() == .matches)
        #expect(try await wrong.checkKey() == .differentKey)
        await #expect(throws: BackupError.wrongEncryptionKey) {
            try await wrong.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        }
        #expect(try f.storeContents()[EncryptedBackupDestination.keyCheckObjectName] == nil)
        try await f.destination().uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        #expect(try f.storeContents()[EncryptedBackupDestination.keyCheckObjectName] == keyCheck, "rewritten by the next upload")

        // A damaged key check is not mistaken for a different key.
        try flipByte(f.dir.url.appendingPathComponent("store/key-check"), at: 20)
        #expect(try await f.destination().checkKey() == .matches)
        #expect(try await wrong.checkKey() == .differentKey)

        // A key check from a newer app is respected, not overwritten.
        var newer = [UInt8](keyCheck)
        newer[8] = 2
        newer.replaceSubrange(41..<49, with: keyCheckChecksum(newer[0..<41]))
        try Data(newer).write(to: f.dir.url.appendingPathComponent("store/key-check"))
        let fresh = f.destination()
        #expect(await fresh.availability() == .unavailable(reason: BackupError.newerFormatVersion(2).localizedDescription))
        await #expect(throws: BackupError.newerFormatVersion(2)) {
            try await fresh.uploadPDF(from: source, sha256: String(repeating: "cd", count: 32), size: 3, progress: nil)
        }
        #expect(try f.storeContents()[EncryptedBackupDestination.keyCheckObjectName] == Data(newer))
    }

    @Test func aDamagedKeyCheckInAnEmptyStoreIsReplaced() async throws {
        let f = try EncryptedFixture()
        try f.dir.file("store/key-check", Data("garbage".utf8))
        let destination = f.destination()
        #expect(try await destination.checkKey() == .nothingStored)
        try await destination.uploadSnapshot(from: try f.dir.file("s", Data("x".utf8)),
                                             name: SnapshotName.make(createdAt: Self.olderDate, deviceName: "iPad"), progress: nil)
        #expect(try await f.destination().checkKey() == .matches)
    }

    @Test func notEnoughSpaceIsRefusedBeforeEncrypting() async throws {
        let f = try EncryptedFixture()
        let destination = f.destination(capacity: 4096)
        let big = try f.dir.file("big.pdf", pseudoRandomData(count: 10_000, seed: 3))
        let digest = try ContentHash.digest(ofFileAt: big)
        await #expect(throws: BackupError.notEnoughSpace) {
            try await destination.uploadPDF(from: big, sha256: digest.sha256, size: digest.size, progress: nil)
        }
        await #expect(throws: BackupError.notEnoughSpace) {
            try await destination.uploadSnapshot(from: big, name: SnapshotName.make(createdAt: Self.olderDate, deviceName: "iPad"), progress: nil)
        }
        #expect(f.storePaths("PDFs").isEmpty)
        #expect(f.storePaths("Backups").isEmpty)
        #expect(f.temporaryFilesAreGone)
        #expect(BackupError.notEnoughSpace.localizedDescription.contains("enough free space"))
        // Enough room: fine.
        try await f.destination(capacity: 100_000).uploadPDF(from: big, sha256: digest.sha256, size: digest.size, progress: nil)
        #expect(f.storePaths("PDFs").count == 1)
    }

    @Test func temporaryFilesAreRemovedAfterFailureAndCancellation() async throws {
        let f = try EncryptedFixture()
        let destination = f.destination()
        let source = try f.dir.file("big.pdf", pseudoRandomData(count: multiChunkSize, seed: 11))
        let digest = try ContentHash.digest(ofFileAt: source)
        let name = SnapshotName.make(createdAt: Self.olderDate, deviceName: "iPad")
        try await destination.uploadSnapshot(from: try f.dir.file("first", Data("x".utf8)), name: name, progress: nil) // key check written

        // The caller's hash is wrong: refused before upload.
        await #expect(throws: BackupError.contentMismatch(name: "big.pdf")) {
            try await destination.uploadPDF(from: source, sha256: String(repeating: "ab", count: 32), size: digest.size, progress: nil)
        }
        #expect(f.temporaryFilesAreGone)

        // The store fails: its error passes through.
        f.store.failUploads(with: StoreFailure())
        await #expect(throws: StoreFailure()) {
            try await destination.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        }
        await #expect(throws: StoreFailure()) { try await destination.uploadSnapshot(from: source, name: name, progress: nil) }
        #expect(f.temporaryFilesAreGone)
        f.store.failUploads(with: nil)

        // Cancelled while encrypting, for both kinds of upload.
        let pdfTask = Task {
            try await destination.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: { fraction in
                if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await pdfTask.value }
        let snapshotTask = Task {
            try await destination.uploadSnapshot(from: source, name: SnapshotName.make(createdAt: Self.newerDate, deviceName: "iPad"),
                                                 progress: { fraction in if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        await #expect(throws: CancellationError.self) { try await snapshotTask.value }
        #expect(f.temporaryFilesAreGone)
        #expect(f.storePaths("PDFs").isEmpty)
        #expect(try await destination.listSnapshots().count == 1)

        // Cancelled while downloading and decrypting.
        try await destination.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: nil)
        let output = f.dir.url.appendingPathComponent("out.pdf")
        let downloadTask = Task {
            try await destination.downloadPDF(sha256: digest.sha256, to: output, progress: { fraction in
                if fraction > 0.6 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await downloadTask.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(f.temporaryFilesAreGone)
        #expect(f.dir.allPaths().filter { $0.contains("partial") }.isEmpty)
    }
}

struct FolderBackupBlobStoreTests {
    @Test func keepsTheBlobStoreContract() async throws {
        let dir = try TemporaryDirectory()
        let root = dir.url.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FolderBackupBlobStore(root: root)
        #expect(await store.availability() == .available)
        #expect(try await store.list(.backups).isEmpty)
        #expect(try await store.size(of: .pdf("a.ttenc")) == nil)

        let source = try dir.file("source", Data("hello".utf8))
        let log = ProgressLog()
        try await store.upload(from: source, to: .pdf("a.ttenc"), progress: log.callback)
        #expect(log.isWellFormed)
        try await store.upload(from: source, to: .control("key-check"), progress: nil)
        try dir.file("root/PDFs/.hidden", Data("x".utf8))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PDFs/folder"), withIntermediateDirectories: true)
        #expect(try await store.list(.pdfs) == [BackupBlobInfo(name: "a.ttenc", byteSize: 5)])
        #expect(try await store.size(of: .control("key-check")) == 5)
        #expect(dir.allPaths(under: "root").sorted() == ["PDFs", "PDFs/.hidden", "PDFs/a.ttenc", "PDFs/folder", "key-check"])

        let output = dir.url.appendingPathComponent("out")
        try await store.download(.pdf("a.ttenc"), to: output, progress: nil)
        #expect(try Data(contentsOf: output) == Data("hello".utf8))
        await #expect(throws: BackupError.fileNotFound(name: "b.ttenc")) { try await store.download(.pdf("b.ttenc"), to: output, progress: nil) }
        try await store.delete(.pdf("a.ttenc"))
        try await store.delete(.pdf("a.ttenc"))
        #expect(try await store.size(of: .pdf("a.ttenc")) == nil)
        for unsafe in ["../x", ".x", "", "a/b", "a\\b"] {
            await #expect(throws: BackupError.unsafeEntryName(name: unsafe)) { try await store.size(of: .backup(unsafe)) }
        }
        #expect(BackupBlobKey.backup("x").path == "Backups/x")
        #expect(BackupBlobKey.control("x").path == "x")
        #expect(await FolderBackupBlobStore(root: dir.url.appendingPathComponent("gone")).availability() != .available)
    }

    @Test func aFolderDestinationsDirectoryHoldsEncryptedBackupsThroughItsHook() async throws {
        let dir = try TemporaryDirectory()
        let real = dir.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let recorder = AccessRecorder(realRoot: real)
        let folder = FolderBackupDestination(root: recorder.virtualRoot, access: recorder.hook)
        let destination = EncryptedBackupDestination(id: "enc", displayName: "Encrypted", store: folder.blobStore, key: sequentialKey,
                                                     temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        let name = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_000_000), deviceName: "iPad")
        let info = try await destination.uploadSnapshot(from: try dir.file("snap", Data("snapshot".utf8)), name: name, progress: nil)
        #expect(try await destination.listSnapshots() == [info])
        #expect(recorder.calls.contains { $0.path == "/Backups/\(info.id)" && $0.intent == .write })
        #expect(dir.allPaths(under: "real").contains("Backups/\(info.id)"))
        #expect(dir.allPaths(under: "real").contains("key-check"))
    }
}

/// The first 8 bytes of SHA-256 of `prefix` (the key check's checksum).
func keyCheckChecksum(_ prefix: ArraySlice<UInt8>) -> [UInt8] {
    Array(bytes(fromHex: ContentHash.sha256(of: Data(prefix))).prefix(8))
}
