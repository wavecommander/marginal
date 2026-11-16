import FileProvider
import Foundation
import ReaderBackup
import Testing
@testable import TactileTexts

/// The picked-folder destination: the bookmark store, and the destination over a temporary
/// directory standing in for the folder picked in Files.
struct BackupDestinationFolderTests {
    // MARK: Bookmark store

    @Test func bookmarkRoundTripPersistsAcrossStoreInstances() throws {
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let folder = try scratch.directory("My Backups")

        let store = BackupFolderStore(defaults: suite.defaults)
        #expect(!store.hasFolder)
        #expect(store.resolveFolder() == .unavailable(reason: BackupFolderStore.notChosenReason))
        try store.setFolder(folder)
        #expect(store.hasFolder)
        #expect(store.folderName == "My Backups")

        // A new store over the same defaults (as after a relaunch) resolves the same folder.
        let reopened = BackupFolderStore(defaults: suite.defaults)
        guard case .resolved(let url, let name) = reopened.resolveFolder() else {
            Issue.record("bookmark did not resolve"); return
        }
        #expect(url.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        #expect(name == "My Backups")
        #expect(PickedFolderBackupDestination(store: reopened).displayName == "My Backups")

        reopened.clearFolder()
        #expect(!BackupFolderStore(defaults: suite.defaults).hasFolder)
        #expect(BackupFolderStore(defaults: suite.defaults).resolveFolder() == .unavailable(reason: BackupFolderStore.notChosenReason))
    }

    @Test func staleBookmarkIsRefreshed() throws {
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let folder = try scratch.directory("Picked")
        let bookmarks = FakeBookmarking()
        let store = BackupFolderStore(defaults: suite.defaults, bookmarking: bookmarks)
        try store.setFolder(folder)
        #expect(bookmarks.made == 1)
        bookmarks.markStale(Data("1|\(folder.path)".utf8))

        // Stale: still resolves, and a new bookmark replaces the old one.
        guard case .resolved(let url, _) = store.resolveFolder() else { Issue.record("stale bookmark did not resolve"); return }
        #expect(url.path == folder.path)
        #expect(bookmarks.made == 2)
        // The refreshed bookmark is not stale, so resolving again makes no new one.
        _ = BackupFolderStore(defaults: suite.defaults, bookmarking: bookmarks).resolveFolder()
        #expect(bookmarks.made == 2)
    }

    @Test func unresolvableBookmarkMakesTheDestinationUnavailable() async throws {
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let bookmarks = FakeBookmarking()
        let store = BackupFolderStore(defaults: suite.defaults, bookmarking: bookmarks)
        try store.setFolder(try scratch.directory("Gone Provider"))
        bookmarks.failResolving(true)

        let reason = BackupFolderStore.notFoundReason("Gone Provider")
        #expect(reason.contains("Choose the backup folder again"))
        #expect(store.resolveFolder() == .unavailable(reason: reason))
        let destination = PickedFolderBackupDestination(store: store)
        #expect(await destination.availability() == .unavailable(reason: reason))
        let error = await thrownError { _ = try await destination.listSnapshots() }
        #expect(error as? BackupError == .destinationUnavailable(reason: reason))
        // The name stays known so the UI can say which folder to choose again.
        #expect(destination.displayName == "Gone Provider")

        // Real bookmark data that is garbage behaves the same way.
        let garbage = BackupFolderStore(defaults: suite.defaults, key: "garbage", bookmarking: GarbageBookmarking())
        try garbage.setFolder(scratch.url)
        guard case .unavailable(let garbageReason) = garbage.resolveFolder() else { Issue.record("garbage resolved"); return }
        #expect(garbageReason.contains("Choose the backup folder again"))
    }

    @Test func deletedFolderIsUnavailableAndNotRecreated() async throws {
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let folder = try scratch.directory("Deleted Later")
        let store = BackupFolderStore(defaults: suite.defaults)
        try store.setFolder(folder)
        let destination = PickedFolderBackupDestination(store: store)
        #expect(await destination.availability() == .available)

        try FileManager.default.removeItem(at: folder)
        let reason = BackupFolderStore.notFoundReason("Deleted Later")
        #expect(await destination.availability() == .unavailable(reason: reason))
        let source = try scratch.file("archive", backupTestBytes(100))
        let error = await thrownError {
            try await destination.uploadSnapshot(from: source, name: backupTestSnapshotName(minutes: 0), progress: nil)
        }
        #expect(error as? BackupError == .destinationUnavailable(reason: reason))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func noFolderChosen() async throws {
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let destination = PickedFolderBackupDestination(store: BackupFolderStore(defaults: suite.defaults))
        #expect(destination.id == "folder")
        #expect(destination.displayName == "Folder")
        #expect(await destination.availability() == .unavailable(reason: BackupFolderStore.notChosenReason))
        let error = await thrownError { _ = try await destination.hasPDF(sha256: String(repeating: "a", count: 64), size: 1) }
        #expect(error as? BackupError == .destinationUnavailable(reason: BackupFolderStore.notChosenReason))
    }

    // MARK: Destination behaviour through the coordinator

    /// The folder resolves to a path that does not exist; only the coordinator maps it to the
    /// real directory, so every operation that works went through it.
    @Test func everyOperationGoesThroughTheCoordinatorWithTheRightIntent() async throws {
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let real = try scratch.directory("Real Folder")
        let nominal = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Picked", isDirectory: true)
        let bookmarks = FakeBookmarking()
        bookmarks.resolvesTo = nominal
        let store = BackupFolderStore(defaults: suite.defaults, bookmarking: bookmarks)
        try store.setFolder(real)
        let coordinator = RecordingCoordinator(real: real, nominal: nominal)
        let destination = PickedFolderBackupDestination(store: store, coordinator: coordinator)
        typealias A = RecordingCoordinator.Access

        #expect(await destination.availability() == .available)
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly)])

        // Upload two snapshots.
        let older = backupTestSnapshotName(minutes: 0), newer = backupTestSnapshotName(minutes: 5)
        let olderBytes = backupTestBytes(5_000, seed: 1), newerBytes = backupTestBytes(7_000, seed: 2)
        coordinator.reset()
        let progress = ProgressLog()
        let stored = try await destination.uploadSnapshot(from: try scratch.file("a", olderBytes), name: older, progress: progress.callback)
        try await destination.uploadSnapshot(from: try scratch.file("b", newerBytes), name: newer, progress: nil)
        #expect(stored.byteSize == 5_000)
        #expect(progress.values.last == 1)
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly),
                                         A(path: "Backups/\(older)", kind: .writingForReplacing),
                                         A(path: "Backups/\(newer)", kind: .writingForReplacing)])
        #expect(try Data(contentsOf: real.appendingPathComponent("Backups/\(older)")) == olderBytes)

        // List: newest first, with sizes; anything else in the folder is ignored.
        try Data("x".utf8).write(to: real.appendingPathComponent("Backups/notes.txt"))
        coordinator.reset()
        let listed = try await destination.listSnapshots()
        #expect(listed.map(\.name) == [newer, older])
        #expect(listed.map(\.byteSize) == [7_000, 5_000])
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly), A(path: "Backups", kind: .reading)])

        // Download.
        coordinator.reset()
        let downloaded = scratch.url.appendingPathComponent("downloaded")
        try await destination.downloadSnapshot(listed[1], to: downloaded, progress: nil)
        #expect(try Data(contentsOf: downloaded) == olderBytes)
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly),
                                         A(path: "Backups/\(older)", kind: .readingMetadataOnly),
                                         A(path: "Backups/\(older)", kind: .reading)])

        // PDFs: upload, present, skip when present, download.
        let pdfBytes = backupTestBytes(20_000, seed: 3)
        let pdf = try scratch.file("book.pdf", pdfBytes)
        let hash = ContentHash.sha256(of: pdfBytes)
        let pdfPath = "PDFs/\(hash).pdf"
        #expect(try await !destination.hasPDF(sha256: hash, size: 20_000))
        coordinator.reset()
        try await destination.uploadPDF(from: pdf, sha256: hash, size: 20_000, progress: nil)
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly),
                                         A(path: pdfPath, kind: .readingMetadataOnly),
                                         A(path: pdfPath, kind: .writingForReplacing)])
        #expect(try Data(contentsOf: real.appendingPathComponent(pdfPath)) == pdfBytes)
        coordinator.reset()
        #expect(try await destination.hasPDF(sha256: hash, size: 20_000))
        #expect(try await !destination.hasPDF(sha256: hash, size: 19_999))
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly), A(path: pdfPath, kind: .readingMetadataOnly)])
        // Present: skipped without touching the source (which no longer exists).
        try FileManager.default.removeItem(at: pdf)
        coordinator.reset()
        let skipProgress = ProgressLog()
        try await destination.uploadPDF(from: pdf, sha256: hash, size: 20_000, progress: skipProgress.callback)
        #expect(skipProgress.values == [1])
        #expect(!coordinator.log.contains { $0.kind == .writingForReplacing })
        coordinator.reset()
        let downloadedPDF = scratch.url.appendingPathComponent("downloaded.pdf")
        try await destination.downloadPDF(sha256: hash, to: downloadedPDF, progress: nil)
        #expect(try Data(contentsOf: downloadedPDF) == pdfBytes)
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly),
                                         A(path: pdfPath, kind: .readingMetadataOnly),
                                         A(path: pdfPath, kind: .reading)])
        let missing = await thrownError {
            try await destination.downloadPDF(sha256: String(repeating: "b", count: 64), to: downloadedPDF, progress: nil)
        }
        #expect(missing as? BackupError == .pdfNotAtDestination(sha256: String(repeating: "b", count: 64)))

        // Delete, twice (the second finds nothing and succeeds).
        coordinator.reset()
        try await destination.deleteSnapshot(listed[1])
        try await destination.deleteSnapshot(listed[1])
        #expect(Set(coordinator.log) == [A(path: "", kind: .readingMetadataOnly), A(path: "Backups/\(older)", kind: .deleting)])
        #expect(try await destination.listSnapshots().map(\.name) == [newer])

        // Nothing was written outside the folder, and no temporary files are left.
        #expect(!(coordinator.log.contains { $0.path.hasPrefix("OUTSIDE:") }))
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: real.path).filter { $0.contains(".partial") }
        #expect(leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: nominal.path))
    }

    @Test func coordinatorErrorsAreTranslated() async throws {
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let folder = try scratch.directory("Offline")
        let store = BackupFolderStore(defaults: suite.defaults)
        try store.setFolder(folder)
        let coordinator = RecordingCoordinator(real: folder)
        let destination = PickedFolderBackupDestination(store: store, coordinator: coordinator)

        // A provider that can't be reached: unavailable with its reason, operations throw it.
        coordinator.fail(with: NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.serverUnreachable.rawValue))
        let offline = BackupFileCoordinationError.offlineReason("Offline")
        #expect(await destination.availability() == .unavailable(reason: offline))
        #expect(await thrownError { _ = try await destination.listSnapshots() } as? BackupError
                == .destinationUnavailable(reason: BackupFileCoordinationError.offlineReason("Backups")))

        coordinator.fail(with: CocoaError(.fileReadNoPermission))
        #expect(await thrownError { _ = try await destination.listSnapshots() } as? BackupError == .permissionDenied(name: "Backups"))

        // Coordination cancelled because the app was suspended: stopped, not failed.
        coordinator.fail(with: CocoaError(.userCancelled))
        #expect(await thrownError { _ = try await destination.listSnapshots() } is CancellationError)
    }

    @Test func errorTranslation() {
        let url = URL(fileURLWithPath: "/x/Backups/a.ttbackup")
        func translated(_ error: any Error) -> BackupError? { BackupFileCoordinationError.translate(error, url: url) as? BackupError }
        #expect(translated(CocoaError(.fileNoSuchFile)) == .fileNotFound(name: "a.ttbackup"))
        #expect(translated(CocoaError(.fileWriteOutOfSpace)) == .notEnoughSpace)
        #expect(translated(CocoaError(.fileWriteVolumeReadOnly)) == .permissionDenied(name: "a.ttbackup"))
        #expect(translated(CocoaError(.ubiquitousFileUnavailable)) == .destinationUnavailable(reason: BackupFileCoordinationError.offlineReason("a.ttbackup")))
        #expect(translated(NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.noSuchItem.rawValue)) == .fileNotFound(name: "a.ttbackup"))
        #expect(translated(NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.insufficientQuota.rawValue)) == .notEnoughSpace)
        #expect(translated(POSIXError(.ENOSPC)) == .notEnoughSpace)
        #expect(translated(NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES) as NSError]))
                == .permissionDenied(name: "a.ttbackup"))
        #expect(translated(NSError(domain: "Other", code: 42)) == .fileAccessFailed(name: "a.ttbackup", code: 42))
        // Already-translated errors pass through.
        #expect(translated(BackupError.notABackup) == .notABackup)
    }
}

/// Bookmark data that is not a bookmark, resolved by the system.
private nonisolated struct GarbageBookmarking: BackupFolderBookmarking {
    func bookmarkData(for url: URL) throws -> Data { Data("not a bookmark".utf8) }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { try SystemFolderBookmarking().resolve(data) }
}

/// Collects progress values.
nonisolated final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.withLock { _values } }
    var callback: BackupProgress { { [self] value in lock.withLock { _values.append(value) } } }
}
