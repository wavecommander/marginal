import Foundation
import ReaderBackup
import Testing
@testable import TactileTexts

/// The picked-folder destination when its folder is in iCloud Drive: items that are in iCloud
/// but not downloaded to this iPad (simulated with placeholders and a fake iCloud status), and
/// whether a new backup has been uploaded yet. Needs no iCloud account.
final class BackupDestinationNotDownloadedTests {
    /// Holds the folder's bookmark for the test.
    private let suite = BackupTestDefaults()

    deinit { suite.cleanup() }

    /// The destination over `folder`, as if the reader had picked it in Files.
    private func destination(folder: URL, coordinator: any BackupFileCoordinating = SystemFileCoordinator(),
                             ubiquity: any BackupUbiquitousItemControl = FakeUbiquity(),
                             wait: BackupDownloadWaitPolicy = .standard) throws -> PickedFolderBackupDestination {
        let store = BackupFolderStore(defaults: suite.defaults, bookmarking: FakeBookmarking())
        try store.setFolder(folder)
        return PickedFolderBackupDestination(store: store, coordinator: coordinator, ubiquity: ubiquity, downloadWait: wait)
    }

    // MARK: Not downloaded yet

    @Test func placeholderNames() {
        #expect(BackupICloudPlaceholder.placeholderName(for: "a.ttbackup") == ".a.ttbackup.icloud")
        #expect(BackupICloudPlaceholder.itemName(forPlaceholder: ".a.ttbackup.icloud") == "a.ttbackup")
        #expect(BackupICloudPlaceholder.itemName(forPlaceholder: "a.ttbackup.icloud") == nil)
        #expect(BackupICloudPlaceholder.itemName(forPlaceholder: ".icloud") == nil)
        #expect(BackupICloudPlaceholder.itemName(forPlaceholder: "..icloud") == nil)
        #expect(BackupICloudPlaceholder.itemName(forPlaceholder: "..hidden.icloud") == nil)
        #expect(BackupICloudPlaceholder.itemName(forPlaceholder: ".a.ttbackup") == nil)
    }

    @Test func listingIncludesSnapshotsNotDownloadedYet() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let folder = try destination(folder: picked.url)
        let backups = picked.url.appendingPathComponent("Tactile Texts Backups", isDirectory: true)

        let local = backupTestSnapshotName(minutes: 0)
        let remote = backupTestSnapshotName(minutes: 10, device: "Other iPad")
        try await folder.uploadSnapshot(from: try scratch.file("a", backupTestBytes(50)), name: local, progress: nil)
        try writeICloudPlaceholder(name: remote, size: 123_456, in: backups)
        // Ignored: a placeholder for something that is not a snapshot, an unreadable placeholder,
        // and a placeholder beside the downloaded item it stands for.
        try writeICloudPlaceholder(name: "notes.txt", size: 10, in: backups)
        try Data("junk".utf8).write(to: backups.appendingPathComponent(".\(backupTestSnapshotName(minutes: 20)).icloud"))
        try writeICloudPlaceholder(name: local, size: 999, in: backups)

        let listed = try await folder.listSnapshots()
        #expect(listed.map(\.name) == [remote, local])
        #expect(listed[0].byteSize == 123_456)
        #expect(listed[0].deviceName == "Other iPad")
        #expect(listed[1].byteSize == 50)
    }

    /// Snapshots an earlier version put in `Backups/` still list (also as placeholders), and
    /// deleting one removes its placeholder there.
    @Test func snapshotsInTheOlderBackupsFolderStillWork() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let folder = try destination(folder: picked.url)
        let legacy = picked.url.appendingPathComponent("Backups", isDirectory: true)
        let current = picked.url.appendingPathComponent("Tactile Texts Backups", isDirectory: true)

        let old = backupTestSnapshotName(minutes: 0), older = backupTestSnapshotName(minutes: -5, device: "Other iPad")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try backupTestBytes(40).write(to: legacy.appendingPathComponent(old))
        try writeICloudPlaceholder(name: older, size: 77, in: legacy)
        let new = try await folder.uploadSnapshot(from: try scratch.file("n", backupTestBytes(10)),
                                                  name: backupTestSnapshotName(minutes: 10), progress: nil)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent(new.name).path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent(new.name).path))

        let listed = try await folder.listSnapshots()
        #expect(listed.map(\.name) == [new.name, old, older])

        let file = scratch.url.appendingPathComponent("downloaded")
        try await folder.downloadSnapshot(listed[1], to: file, progress: nil)
        #expect(try Data(contentsOf: file) == backupTestBytes(40))

        try await folder.deleteSnapshot(listed[1])
        try await folder.deleteSnapshot(listed[2])
        #expect(try await folder.listSnapshots().map(\.name) == [new.name])
        #expect(try FileManager.default.contentsOfDirectory(atPath: legacy.path).isEmpty)
    }

    @Test func pdfPlaceholderCountsAsPresent() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let folder = try destination(folder: picked.url)
        let hash = String(repeating: "c", count: 64)
        try writeICloudPlaceholder(name: "\(hash).pdf", size: 5_000, in: picked.url.appendingPathComponent("PDFs", isDirectory: true))

        #expect(try await folder.hasPDF(sha256: hash, size: 5_000))
        #expect(try await !folder.hasPDF(sha256: hash, size: 4_999))
        // Present, so the upload is skipped: the source does not even exist.
        try await folder.uploadPDF(from: scratch.url.appendingPathComponent("missing.pdf"), sha256: hash, size: 5_000, progress: nil)
        #expect(!FileManager.default.fileExists(atPath: picked.url.appendingPathComponent("PDFs/\(hash).pdf").path))
    }

    /// A placeholder only: the download is requested, awaited, and the snapshot read once it
    /// arrives (iCloud replaces the placeholder with the file).
    @Test func downloadFetchesAPlaceholderFirst() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let backups = picked.url.appendingPathComponent("Tactile Texts Backups", isDirectory: true)
        let name = backupTestSnapshotName(minutes: 3)
        let bytes = backupTestBytes(2_048, seed: 4)
        try writeICloudPlaceholder(name: name, size: 2_048, in: backups)

        let ubiquity = FakeUbiquity()
        let polls = PollCounter()
        polls.onPoll = { n in
            guard n == 3 else { return }
            try? bytes.write(to: backups.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: backups.appendingPathComponent(BackupICloudPlaceholder.placeholderName(for: name)))
        }
        let folder = try destination(folder: picked.url, ubiquity: ubiquity,
                                 wait: polls.policy(start: .seconds(30), timeout: .seconds(60)))
        let snapshot = try #require(try await folder.listSnapshots().first)
        #expect(snapshot.name == name && snapshot.byteSize == 2_048)

        let out = scratch.url.appendingPathComponent("out")
        try await folder.downloadSnapshot(snapshot, to: out, progress: nil)
        #expect(try Data(contentsOf: out) == bytes)
        #expect(ubiquity.requested == [name])
        #expect(polls.count == 3)
    }

    /// A dataless item iCloud reports as not downloaded: requested and awaited until iCloud
    /// reports it downloaded.
    @Test func downloadWaitsForIcloudToReportDownloaded() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let ubiquity = FakeUbiquity()
        let polls = PollCounter()
        let folder = try destination(folder: picked.url, ubiquity: ubiquity,
                                 wait: polls.policy(start: .seconds(10), timeout: .seconds(60)))
        let bytes = backupTestBytes(3_000, seed: 5)
        let hash = ContentHash.sha256(of: bytes)
        try await folder.uploadPDF(from: try scratch.file("p.pdf", bytes), sha256: hash, size: 3_000, progress: nil)
        let url = picked.url.appendingPathComponent("PDFs/\(hash).pdf")
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: false), for: url)
        polls.onPoll = { n in
            if n == 2 { ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: false, isDownloading: true), for: url) }
            if n == 4 { ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true), for: url) }
        }
        let out = scratch.url.appendingPathComponent("out.pdf")
        try await folder.downloadPDF(sha256: hash, to: out, progress: nil)
        #expect(try Data(contentsOf: out) == bytes)
        #expect(ubiquity.requested == ["\(hash).pdf"])
        #expect(polls.count == 4)

        // Already downloaded: no request, no wait.
        try await folder.downloadPDF(sha256: hash, to: out, progress: nil)
        #expect(ubiquity.requested.count == 1)
        #expect(polls.count == 4)
    }

    @Test func downloadThatNeverStartsReportsOffline() async throws {
        let (picked, scratch, folder, snapshot, polls, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false), start: .seconds(5), timeout: .seconds(600))
        defer { picked.cleanup(); scratch.cleanup() }
        let error = await thrownError { try await folder.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        #expect(error as? BackupError == BackupDownloadFailure.notStarted(snapshot.name))
        #expect(polls.count == 5)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("o").path))
    }

    @Test func downloadThatNeverCompletesTimesOut() async throws {
        let (picked, scratch, folder, snapshot, polls, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false, isDownloading: true), start: .seconds(5), timeout: .seconds(20))
        defer { picked.cleanup(); scratch.cleanup() }
        let error = await thrownError { try await folder.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        #expect(error as? BackupError == BackupDownloadFailure.timedOut(snapshot.name))
        #expect(polls.count == 20)
    }

    @Test func downloadErrorFromIcloudIsReported() async throws {
        let (picked, scratch, folder, snapshot, polls, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false, downloadingError: CocoaError(.ubiquitousFileUnavailable)),
            start: .seconds(5), timeout: .seconds(20))
        defer { picked.cleanup(); scratch.cleanup() }
        let error = await thrownError { try await folder.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        #expect(error as? BackupError == BackupDownloadFailure.failed(snapshot.name))
        #expect(polls.count == 0)
    }

    @Test func cancellingTheWaitStopsIt() async throws {
        let (picked, scratch, folder, snapshot, _, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false, isDownloading: true), start: .seconds(5), timeout: .seconds(3600),
            realSleep: true)
        defer { picked.cleanup(); scratch.cleanup() }
        let task = Task { try await folder.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let error = await thrownError { try await task.value }
        #expect(error is CancellationError)
    }

    @Test func deletingASnapshotNotDownloadedRemovesItsPlaceholder() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let backups = picked.url.appendingPathComponent("Tactile Texts Backups", isDirectory: true)
        let name = backupTestSnapshotName(minutes: 8)
        try writeICloudPlaceholder(name: name, size: 77, in: backups)
        let coordinator = RecordingCoordinator(real: picked.url)
        let folder = try destination(folder: picked.url, coordinator: coordinator)
        let snapshot = try #require(try await folder.listSnapshots().first)
        coordinator.reset()
        try await folder.deleteSnapshot(snapshot)
        #expect(try await folder.listSnapshots().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent(BackupICloudPlaceholder.placeholderName(for: name)).path))
        #expect(coordinator.log.filter { $0.path.hasPrefix("Tactile Texts Backups/") }.allSatisfy { $0.kind == .deleting })
    }

    @Test func uploadState() async throws {
        let picked = try BackupDestinationScratch("Picked"); defer { picked.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let ubiquity = FakeUbiquity()
        let folder = try destination(folder: picked.url, ubiquity: ubiquity)
        let snapshot = try await folder.uploadSnapshot(from: try scratch.file("a", backupTestBytes(10)),
                                                       name: backupTestSnapshotName(minutes: 0), progress: nil)
        let url = picked.url.appendingPathComponent("Tactile Texts Backups/\(snapshot.name)")
        #expect(await folder.uploadState(of: snapshot) == .notTracked)
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: false), for: url)
        #expect(await folder.uploadState(of: snapshot) == .waiting)
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: false, isUploading: true), for: url)
        #expect(await folder.uploadState(of: snapshot) == .uploading)
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: false, uploadingError: CocoaError(.ubiquitousFileNotUploadedDueToQuota)), for: url)
        guard case .failed(let reason) = await folder.uploadState(of: snapshot) else { Issue.record("not failed"); return }
        #expect(reason.contains("iCloud storage is full"))
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: true), for: url)
        #expect(await folder.uploadState(of: snapshot) == .uploaded)
    }

    // MARK: Helpers

    /// A snapshot that is in the folder but that iCloud reports with `status`.
    private func notDownloadedSnapshot(status: BackupUbiquitousItemStatus, start: Duration, timeout: Duration, realSleep: Bool = false)
    async throws -> (BackupDestinationScratch, BackupDestinationScratch, PickedFolderBackupDestination, BackupSnapshotInfo, PollCounter, FakeUbiquity) {
        let picked = try BackupDestinationScratch("Picked")
        let scratch = try BackupDestinationScratch()
        let ubiquity = FakeUbiquity()
        let polls = PollCounter()
        let wait = realSleep ? BackupDownloadWaitPolicy(pollInterval: .milliseconds(20), startTimeout: start, timeout: timeout)
            : polls.policy(start: start, timeout: timeout)
        let folder = try destination(folder: picked.url, ubiquity: ubiquity, wait: wait)
        let snapshot = try await folder.uploadSnapshot(from: try scratch.file("a", backupTestBytes(64)),
                                                       name: backupTestSnapshotName(minutes: 2), progress: nil)
        ubiquity.set(status, for: picked.url.appendingPathComponent("Tactile Texts Backups/\(snapshot.name)"))
        return (picked, scratch, folder, snapshot, polls, ubiquity)
    }
}
