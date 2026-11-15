import Foundation
import ReaderBackup
import Testing
@testable import Marginal

/// The iCloud container destination with a temporary directory standing in for the container,
/// and the handling of items that are in iCloud but not downloaded (simulated: placeholders and
/// a fake iCloud status). Needs no iCloud account.
struct BackupDestinationICloudTests {
    typealias Reason = ICloudBackupDestination.Reason

    private func destination(container: URL?, signedIn: Bool = true, buildHasICloud: Bool? = true,
                             coordinator: any BackupFileCoordinating = SystemFileCoordinator(),
                             ubiquity: any BackupUbiquitousItemControl = FakeUbiquity(),
                             wait: BackupDownloadWaitPolicy = .standard,
                             lookups: LookupCounter? = nil) -> ICloudBackupDestination {
        ICloudBackupDestination(containerURL: { lookups?.increment(); return container },
                                isSignedIn: { signedIn }, buildHasICloud: { buildHasICloud },
                                coordinator: coordinator, ubiquity: ubiquity, downloadWait: wait)
    }

    // MARK: Availability

    @Test func unavailableReasons() async throws {
        let lookups = LookupCounter()
        let notInBuild = destination(container: nil, signedIn: false, buildHasICloud: false, lookups: lookups)
        #expect(notInBuild.id == "icloud")
        #expect(notInBuild.displayName == "iCloud")
        #expect(await notInBuild.availability() == .unavailable(reason: Reason.notInBuild))
        #expect(await thrownError { _ = try await notInBuild.listSnapshots() } as? BackupError
                == .destinationUnavailable(reason: Reason.notInBuild))
        // Signed out: the container is not looked up at all.
        #expect(lookups.count == 0)

        #expect(await destination(container: nil, signedIn: false, buildHasICloud: true).availability()
                == .unavailable(reason: Reason.notSignedIn))
        #expect(await destination(container: nil, signedIn: false, buildHasICloud: nil).availability()
                == .unavailable(reason: Reason.unknown))
        #expect(await destination(container: nil, signedIn: true, buildHasICloud: true).availability()
                == .unavailable(reason: Reason.containerUnavailable))
        #expect(await destination(container: nil, signedIn: true, buildHasICloud: false).availability()
                == .unavailable(reason: Reason.notInBuild))
    }

    /// With a container, it is available whatever the entitlement probe says (the probe only
    /// chooses the wording of an unavailable reason).
    @Test func containerMakesItAvailableAndCreatesDocuments() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let coordinator = RecordingCoordinator(real: container.url)
        let iCloud = destination(container: container.url, buildHasICloud: nil, coordinator: coordinator)
        #expect(await iCloud.availability() == .available)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: container.url.appendingPathComponent("Documents").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(Set(coordinator.log) == [.init(path: "Documents", kind: .writing), .init(path: "Documents", kind: .readingMetadataOnly)])
    }

    // MARK: Behaviour under Documents/

    @Test func fullBehaviourUnderDocuments() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let coordinator = RecordingCoordinator(real: container.url)
        let iCloud = destination(container: container.url, coordinator: coordinator)
        let documents = container.url.appendingPathComponent("Documents", isDirectory: true)

        let older = backupTestSnapshotName(minutes: 0), newer = backupTestSnapshotName(minutes: 1)
        try await iCloud.uploadSnapshot(from: try scratch.file("a", backupTestBytes(300, seed: 1)), name: older, progress: nil)
        try await iCloud.uploadSnapshot(from: try scratch.file("b", backupTestBytes(400, seed: 2)), name: newer, progress: nil)
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Backups/\(older)").path))
        let listed = try await iCloud.listSnapshots()
        #expect(listed.map(\.name) == [newer, older])

        let out = scratch.url.appendingPathComponent("out")
        try await iCloud.downloadSnapshot(listed[0], to: out, progress: nil)
        #expect(try Data(contentsOf: out) == backupTestBytes(400, seed: 2))

        let pdfBytes = backupTestBytes(1_000, seed: 9)
        let hash = ContentHash.sha256(of: pdfBytes)
        try await iCloud.uploadPDF(from: try scratch.file("p.pdf", pdfBytes), sha256: hash, size: 1_000, progress: nil)
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("PDFs/\(hash).pdf").path))
        #expect(try await iCloud.hasPDF(sha256: hash, size: 1_000))
        let pdfOut = scratch.url.appendingPathComponent("out.pdf")
        try await iCloud.downloadPDF(sha256: hash, to: pdfOut, progress: nil)
        #expect(try Data(contentsOf: pdfOut) == pdfBytes)

        try await iCloud.deleteSnapshot(listed[1])
        #expect(try await iCloud.listSnapshots().map(\.name) == [newer])

        // Every access was coordinated, all inside the container's Documents folder.
        #expect(!coordinator.log.isEmpty)
        #expect(coordinator.log.allSatisfy { $0.path == "Documents" || $0.path.hasPrefix("Documents/") })
        #expect(coordinator.log.contains(.init(path: "Documents/Backups/\(older)", kind: .writingForReplacing)))
        #expect(coordinator.log.contains(.init(path: "Documents/Backups/\(older)", kind: .deleting)))
        #expect(coordinator.log.contains(.init(path: "Documents/PDFs/\(hash).pdf", kind: .reading)))
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
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let iCloud = destination(container: container.url)
        let backups = container.url.appendingPathComponent("Documents/Backups", isDirectory: true)

        let local = backupTestSnapshotName(minutes: 0)
        let remote = backupTestSnapshotName(minutes: 10, device: "Other iPad")
        try await iCloud.uploadSnapshot(from: try scratch.file("a", backupTestBytes(50)), name: local, progress: nil)
        try writeICloudPlaceholder(name: remote, size: 123_456, in: backups)
        // Ignored: a placeholder for something that is not a snapshot, an unreadable placeholder,
        // and a placeholder beside the downloaded item it stands for.
        try writeICloudPlaceholder(name: "notes.txt", size: 10, in: backups)
        try Data("junk".utf8).write(to: backups.appendingPathComponent(".\(backupTestSnapshotName(minutes: 20)).icloud"))
        try writeICloudPlaceholder(name: local, size: 999, in: backups)

        let listed = try await iCloud.listSnapshots()
        #expect(listed.map(\.name) == [remote, local])
        #expect(listed[0].byteSize == 123_456)
        #expect(listed[0].deviceName == "Other iPad")
        #expect(listed[1].byteSize == 50)
    }

    @Test func pdfPlaceholderCountsAsPresent() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let iCloud = destination(container: container.url)
        let hash = String(repeating: "c", count: 64)
        try writeICloudPlaceholder(name: "\(hash).pdf", size: 5_000, in: container.url.appendingPathComponent("Documents/PDFs", isDirectory: true))

        #expect(try await iCloud.hasPDF(sha256: hash, size: 5_000))
        #expect(try await !iCloud.hasPDF(sha256: hash, size: 4_999))
        // Present, so the upload is skipped: the source does not even exist.
        try await iCloud.uploadPDF(from: scratch.url.appendingPathComponent("missing.pdf"), sha256: hash, size: 5_000, progress: nil)
        #expect(!FileManager.default.fileExists(atPath: container.url.appendingPathComponent("Documents/PDFs/\(hash).pdf").path))
    }

    /// A placeholder only: the download is requested, awaited, and the snapshot read once it
    /// arrives (iCloud replaces the placeholder with the file).
    @Test func downloadFetchesAPlaceholderFirst() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let backups = container.url.appendingPathComponent("Documents/Backups", isDirectory: true)
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
        let iCloud = destination(container: container.url, ubiquity: ubiquity,
                                 wait: polls.policy(start: .seconds(30), timeout: .seconds(60)))
        let snapshot = try #require(try await iCloud.listSnapshots().first)
        #expect(snapshot.name == name && snapshot.byteSize == 2_048)

        let out = scratch.url.appendingPathComponent("out")
        try await iCloud.downloadSnapshot(snapshot, to: out, progress: nil)
        #expect(try Data(contentsOf: out) == bytes)
        #expect(ubiquity.requested == [name])
        #expect(polls.count == 3)
    }

    /// A dataless item iCloud reports as not downloaded: requested and awaited until iCloud
    /// reports it downloaded.
    @Test func downloadWaitsForIcloudToReportDownloaded() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let ubiquity = FakeUbiquity()
        let polls = PollCounter()
        let iCloud = destination(container: container.url, ubiquity: ubiquity,
                                 wait: polls.policy(start: .seconds(10), timeout: .seconds(60)))
        let bytes = backupTestBytes(3_000, seed: 5)
        let hash = ContentHash.sha256(of: bytes)
        try await iCloud.uploadPDF(from: try scratch.file("p.pdf", bytes), sha256: hash, size: 3_000, progress: nil)
        let url = container.url.appendingPathComponent("Documents/PDFs/\(hash).pdf")
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: false), for: url)
        polls.onPoll = { n in
            if n == 2 { ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: false, isDownloading: true), for: url) }
            if n == 4 { ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true), for: url) }
        }
        let out = scratch.url.appendingPathComponent("out.pdf")
        try await iCloud.downloadPDF(sha256: hash, to: out, progress: nil)
        #expect(try Data(contentsOf: out) == bytes)
        #expect(ubiquity.requested == ["\(hash).pdf"])
        #expect(polls.count == 4)

        // Already downloaded: no request, no wait.
        try await iCloud.downloadPDF(sha256: hash, to: out, progress: nil)
        #expect(ubiquity.requested.count == 1)
        #expect(polls.count == 4)
    }

    @Test func downloadThatNeverStartsReportsOffline() async throws {
        let (container, scratch, iCloud, snapshot, polls, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false), start: .seconds(5), timeout: .seconds(600))
        defer { container.cleanup(); scratch.cleanup() }
        let error = await thrownError { try await iCloud.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        #expect(error as? BackupError == BackupDownloadFailure.notStarted(snapshot.name))
        #expect(polls.count == 5)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("o").path))
    }

    @Test func downloadThatNeverCompletesTimesOut() async throws {
        let (container, scratch, iCloud, snapshot, polls, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false, isDownloading: true), start: .seconds(5), timeout: .seconds(20))
        defer { container.cleanup(); scratch.cleanup() }
        let error = await thrownError { try await iCloud.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        #expect(error as? BackupError == BackupDownloadFailure.timedOut(snapshot.name))
        #expect(polls.count == 20)
    }

    @Test func downloadErrorFromIcloudIsReported() async throws {
        let (container, scratch, iCloud, snapshot, polls, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false, downloadingError: CocoaError(.ubiquitousFileUnavailable)),
            start: .seconds(5), timeout: .seconds(20))
        defer { container.cleanup(); scratch.cleanup() }
        let error = await thrownError { try await iCloud.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        #expect(error as? BackupError == BackupDownloadFailure.failed(snapshot.name))
        #expect(polls.count == 0)
    }

    @Test func cancellingTheWaitStopsIt() async throws {
        let (container, scratch, iCloud, snapshot, _, _) = try await notDownloadedSnapshot(
            status: BackupUbiquitousItemStatus(isDownloaded: false, isDownloading: true), start: .seconds(5), timeout: .seconds(3600),
            realSleep: true)
        defer { container.cleanup(); scratch.cleanup() }
        let task = Task { try await iCloud.downloadSnapshot(snapshot, to: scratch.url.appendingPathComponent("o"), progress: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let error = await thrownError { try await task.value }
        #expect(error is CancellationError)
    }

    @Test func deletingASnapshotNotDownloadedRemovesItsPlaceholder() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let backups = container.url.appendingPathComponent("Documents/Backups", isDirectory: true)
        let name = backupTestSnapshotName(minutes: 8)
        try writeICloudPlaceholder(name: name, size: 77, in: backups)
        let coordinator = RecordingCoordinator(real: container.url)
        let iCloud = destination(container: container.url, coordinator: coordinator)
        let snapshot = try #require(try await iCloud.listSnapshots().first)
        coordinator.reset()
        try await iCloud.deleteSnapshot(snapshot)
        #expect(try await iCloud.listSnapshots().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent(BackupICloudPlaceholder.placeholderName(for: name)).path))
        #expect(coordinator.log.filter { $0.path.hasPrefix("Documents/Backups/") }.allSatisfy { $0.kind == .deleting })
    }

    @Test func uploadState() async throws {
        let container = try BackupDestinationScratch("Container"); defer { container.cleanup() }
        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        let ubiquity = FakeUbiquity()
        let iCloud = destination(container: container.url, ubiquity: ubiquity)
        let snapshot = try await iCloud.uploadSnapshot(from: try scratch.file("a", backupTestBytes(10)),
                                                       name: backupTestSnapshotName(minutes: 0), progress: nil)
        let url = container.url.appendingPathComponent("Documents/Backups/\(snapshot.name)")
        #expect(await iCloud.uploadState(of: snapshot) == .notTracked)
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: false), for: url)
        #expect(await iCloud.uploadState(of: snapshot) == .waiting)
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: false, isUploading: true), for: url)
        #expect(await iCloud.uploadState(of: snapshot) == .uploading)
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: false, uploadingError: CocoaError(.ubiquitousFileNotUploadedDueToQuota)), for: url)
        guard case .failed(let reason) = await iCloud.uploadState(of: snapshot) else { Issue.record("not failed"); return }
        #expect(reason.contains("iCloud storage is full"))
        ubiquity.set(BackupUbiquitousItemStatus(isDownloaded: true, isUploaded: true), for: url)
        #expect(await iCloud.uploadState(of: snapshot) == .uploaded)
    }

    // MARK: Entitlement probe and factory

    @Test func entitlementProbe() throws {
        // This test build is unsigned, so it has no iCloud entitlement.
        #expect(ICloudEntitlementProbe.hasContainerEntitlement() == false)

        let entitlements: [String: Any] = [ICloudEntitlementProbe.containerKey: [ICloudBackupDestination.containerIdentifier]]
        var profile = Data([0x30, 0x80, 0x06, 0x09])
        profile += try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements, "Name": "Test"],
                                                      format: .xml, options: 0)
        profile += Data([0x00, 0xA0, 0x82])
        let parsed = try #require(ICloudEntitlementProbe.profileEntitlements(profile))
        #expect(ICloudEntitlementProbe.lists(parsed))
        #expect(!ICloudEntitlementProbe.lists([ICloudEntitlementProbe.containerKey: ["iCloud.other"]]))
        #expect(!ICloudEntitlementProbe.lists([:]))
        #expect(ICloudEntitlementProbe.profileEntitlements(Data("no plist here".utf8)) == nil)
    }

    @Test func factoryOffersFolderThenICloud() async throws {
        let suite = BackupTestDefaults(); defer { suite.cleanup() }
        let destinations = BackupDestinationFactory.folderAndICloud(defaults: suite.defaults)
        #expect(destinations.all.map(\.id) == ["folder", "icloud"])
        #expect(destinations.all.map(\.displayName) == ["Folder", "iCloud"])
        #expect(await destinations.folder.availability() == .unavailable(reason: BackupFolderStore.notChosenReason))
        // This build has no iCloud entitlement, whatever account the simulator has.
        #expect(await destinations.iCloud.availability() == .unavailable(reason: Reason.notInBuild))

        let scratch = try BackupDestinationScratch(); defer { scratch.cleanup() }
        try destinations.folderStore.setFolder(try scratch.directory("Chosen"))
        #expect(await destinations.folder.availability() == .available)
        #expect(destinations.folder.displayName == "Chosen")
    }

    // MARK: Helpers

    /// A snapshot that is in the container but that iCloud reports with `status`.
    private func notDownloadedSnapshot(status: BackupUbiquitousItemStatus, start: Duration, timeout: Duration, realSleep: Bool = false)
    async throws -> (BackupDestinationScratch, BackupDestinationScratch, ICloudBackupDestination, BackupSnapshotInfo, PollCounter, FakeUbiquity) {
        let container = try BackupDestinationScratch("Container")
        let scratch = try BackupDestinationScratch()
        let ubiquity = FakeUbiquity()
        let polls = PollCounter()
        let wait = realSleep ? BackupDownloadWaitPolicy(pollInterval: .milliseconds(20), startTimeout: start, timeout: timeout)
            : polls.policy(start: start, timeout: timeout)
        let iCloud = destination(container: container.url, ubiquity: ubiquity, wait: wait)
        let snapshot = try await iCloud.uploadSnapshot(from: try scratch.file("a", backupTestBytes(64)),
                                                       name: backupTestSnapshotName(minutes: 2), progress: nil)
        ubiquity.set(status, for: container.url.appendingPathComponent("Documents/Backups/\(snapshot.name)"))
        return (container, scratch, iCloud, snapshot, polls, ubiquity)
    }
}

/// Counts container lookups.
nonisolated final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}
