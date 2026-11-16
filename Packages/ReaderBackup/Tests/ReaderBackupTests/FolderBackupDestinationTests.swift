import Foundation
import Testing
@testable import ReaderBackup

/// Records every access through the hook and maps a virtual root (which does not exist) onto a
/// real directory, so any access that bypassed the hook would fail.
final class AccessRecorder: @unchecked Sendable {
    let virtualRoot: URL
    let realRoot: URL
    private let lock = NSLock()
    private var log: [(path: String, intent: FolderBackupDestination.AccessIntent)] = []

    init(realRoot: URL) {
        self.realRoot = realRoot
        virtualRoot = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Backups Folder", isDirectory: true)
    }

    var calls: [(path: String, intent: FolderBackupDestination.AccessIntent)] { lock.withLock { log } }
    func reset() { lock.withLock { log.removeAll() } }

    var hook: FolderBackupDestination.AccessHook {
        { [self] url, intent, body in
            let virtual = virtualRoot.path
            #expect(url.path.hasPrefix(virtual), "access outside the root: \(url.path)")
            let relative = String(url.path.dropFirst(virtual.count))
            lock.withLock { log.append((relative, intent)) }
            try body(URL(fileURLWithPath: realRoot.path + relative))
        }
    }
}

struct FolderBackupDestinationTests {
    static let sha = String(repeating: "ab", count: 32)

    func snapshot(_ dir: TemporaryDirectory, _ name: String, _ contents: Data) throws -> URL {
        try dir.file("local/\(name)", contents)
    }

    @Test func newSnapshotsGoInTheLocalFolderAndOldOnesInBackupsStillWork() async throws {
        let dir = try TemporaryDirectory()
        let root = dir.url.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = FolderBackupDestination(root: root, backupsDirectory: BackupFolderLayout.localBackupsDirectory,
                                                  legacyBackupsDirectories: [BackupFolderLayout.backupsDirectory])
        let old = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_000_000), deviceName: "iPad A")
        let new = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_090_000), deviceName: "iPad B")
        try dir.file("root/Backups/\(old)", Data("old".utf8))

        try await destination.uploadSnapshot(from: try snapshot(dir, "n", Data("new".utf8)), name: new, progress: nil)
        #expect(dir.allPaths(under: "root/Tactile Texts Backups") == [new])
        #expect(dir.allPaths(under: "root/Backups") == [old])

        let listed = try await destination.listSnapshots()
        #expect(listed.map(\.name) == [new, old])

        let downloaded = dir.url.appendingPathComponent("downloaded.ttbackup")
        try await destination.downloadSnapshot(listed[1], to: downloaded, progress: nil)
        #expect(try Data(contentsOf: downloaded) == Data("old".utf8))

        // A name in both folders lists once and deletes from both.
        try dir.file("root/Backups/\(new)", Data("dup".utf8))
        #expect(try await destination.listSnapshots().map(\.name) == [new, old])
        try await destination.deleteSnapshot(listed[0])
        try await destination.deleteSnapshot(listed[1])
        #expect(try await destination.listSnapshots().isEmpty)
    }

    @Test func uploadListDownloadDelete() async throws {
        let dir = try TemporaryDirectory()
        let root = dir.url.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = FolderBackupDestination(root: root)
        #expect(destination.id == "folder:\(root.path)")
        #expect(destination.displayName == "root")
        #expect(await destination.availability() == .available)
        #expect(try await destination.listSnapshots().isEmpty)

        let older = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_000_000), deviceName: "iPad A")
        let newer = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_090_000), deviceName: "iPad B")
        let bigData = pseudoRandomData(count: multiChunkSize, seed: 4)
        let log = ProgressLog()
        let uploaded = try await destination.uploadSnapshot(from: try snapshot(dir, "a", bigData), name: older, progress: log.callback)
        #expect(log.isWellFormed)
        #expect(uploaded == BackupSnapshotInfo(id: older, name: older, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                              deviceName: "iPad A", byteSize: Int64(bigData.count)))
        try await destination.uploadSnapshot(from: try snapshot(dir, "b", Data("new".utf8)), name: newer, progress: nil)
        #expect(dir.allPaths(under: "root/Backups") == [older, newer].sorted())

        // Unknown files, hidden files, folders and names that are not snapshots are ignored.
        try dir.file("root/Backups/notes.txt", Data("x".utf8))
        try dir.file("root/Backups/.\(newer).icloud", Data("x".utf8))
        try dir.file("root/Backups/garbage.ttbackup", Data("x".utf8))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Backups/2020-01-01T00-00-00Z dir.ttbackup"),
                                                withIntermediateDirectories: true)
        let listed = try await destination.listSnapshots()
        #expect(listed.map(\.name) == [newer, older])
        #expect(listed.map(\.byteSize) == [3, Int64(bigData.count)])

        let downloaded = dir.url.appendingPathComponent("downloaded.ttbackup")
        try await destination.downloadSnapshot(listed[1], to: downloaded, progress: nil)
        #expect(try Data(contentsOf: downloaded) == bigData)

        try await destination.deleteSnapshot(listed[1])
        #expect(try await destination.listSnapshots().map(\.name) == [newer])
        try await destination.deleteSnapshot(listed[1]) // already gone: fine
        await #expect(throws: BackupError.snapshotNotFound(name: older)) {
            try await destination.downloadSnapshot(listed[1], to: downloaded, progress: nil)
        }
        await #expect(throws: BackupError.invalidSnapshotName(name: "../x.ttbackup")) {
            try await destination.uploadSnapshot(from: downloaded, name: "../x.ttbackup", progress: nil)
        }
    }

    @Test func pdfsAreStoredOnceAndVerified() async throws {
        let dir = try TemporaryDirectory()
        let root = dir.url.appendingPathComponent("root", isDirectory: true)
        let destination = FolderBackupDestination(root: root)
        let pdf = pseudoRandomData(count: multiChunkSize, seed: 8)
        let source = try dir.file("book.pdf", pdf)
        let digest = try ContentHash.digest(ofFileAt: source)

        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size) == false)
        let log = ProgressLog()
        try await destination.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: log.callback)
        #expect(log.isWellFormed)
        #expect(dir.allPaths(under: "root/PDFs") == ["\(digest.sha256).pdf"])
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size))
        #expect(try await destination.hasPDF(sha256: digest.sha256.uppercased(), size: digest.size))
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size + 1) == false)

        // Already there with the right size: skipped (the source is not even opened).
        try await destination.uploadPDF(from: dir.url.appendingPathComponent("gone.pdf"), sha256: digest.sha256, size: digest.size, progress: nil)

        let local = dir.url.appendingPathComponent("restored.pdf")
        try await destination.downloadPDF(sha256: digest.sha256, to: local, progress: nil)
        #expect(try Data(contentsOf: local) == pdf)

        // A damaged copy at the destination is refused on download, leaving nothing locally.
        let stored = root.appendingPathComponent("PDFs/\(digest.sha256).pdf")
        try flipByte(stored, at: 1000)
        let other = dir.url.appendingPathComponent("other.pdf")
        await #expect(throws: BackupError.contentMismatch(name: "\(digest.sha256).pdf")) {
            try await destination.downloadPDF(sha256: digest.sha256, to: other, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: other.path))
        #expect(dir.allPaths().filter { $0.contains(".partial") }.isEmpty)

        await #expect(throws: BackupError.pdfNotAtDestination(sha256: Self.sha)) {
            try await destination.downloadPDF(sha256: Self.sha, to: other, progress: nil)
        }
        await #expect(throws: BackupError.self) { try await destination.hasPDF(sha256: "../../etc/passwd", size: 1) }
    }

    @Test func aFailedWriteLeavesNoPartialNames() async throws {
        let dir = try TemporaryDirectory()
        let root = dir.url.appendingPathComponent("root", isDirectory: true)
        let destination = FolderBackupDestination(root: root)
        let source = try dir.file("book.pdf", pseudoRandomData(count: multiChunkSize, seed: 9))
        let size = Int64(multiChunkSize)

        // The caller's hash is wrong: refused, nothing visible (not even a hidden temporary).
        await #expect(throws: BackupError.contentMismatch(name: "book.pdf")) {
            try await destination.uploadPDF(from: source, sha256: Self.sha, size: size, progress: nil)
        }
        #expect(dir.allPaths(under: "root/PDFs").isEmpty)

        // Cancelled half-way through a snapshot upload.
        let name = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_000_000), deviceName: "iPad")
        let task = Task {
            try await destination.uploadSnapshot(from: source, name: name, progress: { fraction in
                if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(dir.allPaths(under: "root/Backups").isEmpty)
        #expect(try await destination.listSnapshots().isEmpty)

        // Cancelled PDF upload.
        let digest = try ContentHash.digest(ofFileAt: source)
        let pdfTask = Task {
            try await destination.uploadPDF(from: source, sha256: digest.sha256, size: digest.size, progress: { fraction in
                if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await pdfTask.value }
        #expect(dir.allPaths(under: "root/PDFs").isEmpty)
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size) == false)
    }

    @Test func everyAccessGoesThroughTheHook() async throws {
        let dir = try TemporaryDirectory()
        let real = dir.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let recorder = AccessRecorder(realRoot: real)
        let destination = FolderBackupDestination(root: recorder.virtualRoot, id: "test", displayName: "Test", access: recorder.hook)
        let name = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_700_000_000), deviceName: "iPad")
        let snapshotPath = "/Backups/\(name)"
        let source = try dir.file("snap", Data("snapshot".utf8))
        let pdf = try dir.file("doc.pdf", Data("pdf bytes".utf8))
        let digest = try ContentHash.digest(ofFileAt: pdf)
        let pdfPath = "/PDFs/\(digest.sha256).pdf"
        typealias Intent = FolderBackupDestination.AccessIntent

        func expectCalls(_ expected: [(String, Intent)], _ comment: Comment) {
            let calls = recorder.calls
            #expect(calls.map(\.path) == expected.map(\.0), comment)
            #expect(calls.map(\.intent) == expected.map(\.1), comment)
            recorder.reset()
        }

        #expect(await destination.availability() == .available)
        expectCalls([("", .read)], "availability")
        let info = try await destination.uploadSnapshot(from: source, name: name, progress: nil)
        expectCalls([(snapshotPath, .write)], "upload snapshot")
        #expect(try await destination.listSnapshots() == [info])
        expectCalls([("/Backups", .read)], "list")
        try await destination.downloadSnapshot(info, to: dir.url.appendingPathComponent("down"), progress: nil)
        expectCalls([(snapshotPath, .read)], "download snapshot")
        #expect(try await destination.hasPDF(sha256: digest.sha256, size: digest.size) == false)
        expectCalls([(pdfPath, .read)], "hasPDF")
        try await destination.uploadPDF(from: pdf, sha256: digest.sha256, size: digest.size, progress: nil)
        expectCalls([(pdfPath, .write)], "upload PDF")
        try await destination.downloadPDF(sha256: digest.sha256, to: dir.url.appendingPathComponent("down.pdf"), progress: nil)
        expectCalls([(pdfPath, .read)], "download PDF")
        try await destination.deleteSnapshot(info)
        expectCalls([(snapshotPath, .delete)], "delete")
        #expect(try await destination.listSnapshots().isEmpty)
        // The real directory holds what the operations wrote.
        #expect(dir.allPaths(under: "real") == ["Backups", "PDFs", "PDFs/\(digest.sha256).pdf"])
    }

    @Test func aMissingFolderIsUnavailable() async throws {
        let dir = try TemporaryDirectory()
        let destination = FolderBackupDestination(root: dir.url.appendingPathComponent("Gone"), displayName: "My Backups")
        guard case .unavailable(let reason) = await destination.availability() else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("“My Backups” can’t be found"))
        let failing = FolderBackupDestination(root: dir.url, access: { url, _, _ in throw BackupError.permissionDenied(name: url.lastPathComponent) })
        #expect(await failing.availability() == .unavailable(reason: BackupError.permissionDenied(name: dir.url.lastPathComponent).localizedDescription))
    }
}

struct RetentionTests {
    func info(_ seconds: Int, _ device: String = "iPad") -> BackupSnapshotInfo {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds))
        let name = SnapshotName.make(createdAt: date, deviceName: device)
        return BackupSnapshotInfo(id: name, name: name, createdAt: date, deviceName: device, byteSize: 1)
    }

    @Test func keepsTheNewestTen() {
        let all = (0..<12).map { info($0 * 3600) }.shuffled()
        let deleted = SnapshotRetention.snapshotsToDelete(all)
        #expect(deleted == [info(3600), info(0)])
        #expect(SnapshotRetention.defaultKeepCount == 10)
    }

    @Test func fewerThanTheLimitDeletesNothing() {
        #expect(SnapshotRetention.snapshotsToDelete((0..<10).map { info($0) }).isEmpty)
        #expect(SnapshotRetention.snapshotsToDelete([]).isEmpty)
    }

    @Test func customCountsAndTies() {
        let all = [info(0, "A"), info(0, "B"), info(10)]
        #expect(SnapshotRetention.snapshotsToDelete(all, keeping: 2) == [info(0, "A")])
        #expect(SnapshotRetention.snapshotsToDelete(all, keeping: 0) == [info(0, "B"), info(0, "A")], "the newest is always kept")
    }
}
