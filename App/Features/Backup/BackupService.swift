import Foundation
import Observation
import ReaderBackup
import ReaderCore
import UIKit

// MARK: - Job

/// The one backup or restore in progress, observable by every window (progress and Cancel).
@Observable
@MainActor
final class BackupJob: Identifiable {
    enum Kind: Equatable, Sendable {
        /// A `.ttbackup` file for the reader to save somewhere.
        case backUpToFile
        /// A backup to a destination (its display name).
        case backUpToDestination(String)
        /// Reading a backup (downloading it from a destination first) for the restore preview.
        case openBackup
        /// Restoring books from an open backup.
        case restore
    }

    enum Phase: Equatable, Sendable {
        case preparing
        /// Open readers and notes are saving what is on screen.
        case savingOpenBooks
        case checkingSpace
        /// Computing PDFs' content hashes (once per book; cached afterwards).
        case hashingPDFs
        case writingBackup
        case uploadingPDFs
        case uploadingBackup
        case removingOldBackups
        case downloading
        case reading
        /// Extracting and verifying the chosen books.
        case extracting
        /// Swapping the restored books into the Library.
        case committing
        case cleaningUp
    }

    nonisolated let id = UUID()
    let kind: Kind
    private(set) var phase = Phase.preparing
    /// Fraction of the whole job done, `0...1`, never decreasing.
    private(set) var fraction = 0.0
    private(set) var isCancelled = false
    @ObservationIgnored var cancelAction: (() -> Void)?

    init(kind: Kind) { self.kind = kind }

    /// Cancels the job: file work stops at its next 4 MiB chunk and temporary files are removed.
    /// A restore that has begun swapping books in finishes that step.
    func cancel() {
        isCancelled = true
        cancelAction?()
    }

    func set(phase: Phase) { if self.phase != phase { self.phase = phase } }
    func set(fraction: Double) {
        let clamped = max(self.fraction, min(1, fraction))
        if clamped != self.fraction { self.fraction = clamped }
    }

    /// A progress callback (any thread) mapping a step's `0...1` onto `start...end` of the job.
    nonisolated func reporter(from start: Double, to end: Double) -> BackupProgress {
        { [weak self] value in
            let overall = start + (end - start) * min(1, max(0, value))
            Task { @MainActor in self?.set(fraction: overall) }
        }
    }
}

// MARK: - Values

/// What a backup's size would be, for the choice "Notes and ink only: 14 MB · With PDFs: 3.2 GB".
nonisolated struct BackupSizeEstimate: Equatable, Sendable {
    /// Records, ink, covers and archive overhead.
    var notesAndInk: Int64
    /// The same plus every distinct PDF on disk.
    var withPDFs: Int64
}

/// A finished backup to a file.
nonisolated struct BackupFileResult: Equatable, Sendable {
    /// The `.ttbackup` in the app's temporary directory. Move it where the reader chooses, then
    /// `BackupService.discardTemporaryFile(_:)` (stale ones are removed at the next launch).
    var url: URL
    var byteSize: Int64
    var bookCount: Int
    /// Books left out because neither their PDF nor its recorded hash exists, so the backup
    /// could not say which PDF they need.
    var skippedBookTitles: [String]
}

/// A finished backup to a destination.
nonisolated struct DestinationBackupResult: Equatable, Sendable {
    var snapshot: BackupSnapshotInfo
    var bookCount: Int
    /// PDFs uploaded by this run.
    var uploadedPDFs: Int
    /// PDFs the destination already held.
    var alreadyPresentPDFs: Int
    /// Old snapshots deleted by retention.
    var deletedSnapshots: Int
    var skippedBookTitles: [String]
}

/// What a restore did.
nonisolated struct RestoreSummary: Equatable, Sendable {
    struct RestoredBook: Equatable, Sendable, Identifiable {
        var id: UUID
        var title: String
        /// `false`: restored without its PDF ("PDF missing"; Locate PDF… links it).
        var hasPDF: Bool
    }

    struct Failure: Equatable, Sendable, Identifiable {
        var id: UUID
        var title: String
        /// Reader-facing.
        var message: String
    }

    var restored: [RestoredBook] = []
    /// Books not restored; each left exactly as it was.
    var failures: [Failure] = []
    /// Notes dropped because they were empty once their missing ink was accounted for.
    var droppedEmptyNotes = 0

    /// Restored books that still need their PDF.
    var needingPDF: [RestoredBook] { restored.filter { !$0.hasPDF } }
}

/// Failures of the backup engine itself (the archive and destination code throws `BackupError`;
/// cancellation throws `CancellationError`).
nonisolated enum BackupServiceError: LocalizedError, Equatable, Sendable {
    /// Another backup or restore is running.
    case busy
    /// Not enough free space for the backup (or the restore's temporary files).
    case notEnoughSpace(required: Int64, available: Int64)
    /// The restore session was closed.
    case sessionClosed
    /// The backup is damaged; nothing was restored. `bookTitle` is the book where it was found.
    case backupDamaged(bookTitle: String, reason: String)
    /// A local book with the same ID or content was added after the restore preview was built.
    case libraryChanged(bookTitle: String)
    /// The destination can't be used now (`reason` is reader-facing).
    case destinationUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .busy:
            "A backup or restore is already in progress. Wait for it to finish, or cancel it, and try again."
        case .notEnoughSpace(let required, let available):
            "There isn’t enough free space: this needs about \(Self.bytes(required)) and \(Self.bytes(available)) is free. Free up some space and try again."
        case .sessionClosed:
            "This backup is no longer open. Open it again to restore from it."
        case .backupDamaged(let title, let reason):
            "Nothing was restored: the backup is damaged (found in “\(title)”). \(reason)"
        case .libraryChanged(let title):
            "“\(title)” changed in the Library after the restore preview was shown, so it wasn’t restored. Open the backup again to see the current state."
        case .destinationUnavailable(let reason):
            reason
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - Service

/// Backup and restore, one job at a time for the whole app. One per app, owned by
/// `AppEnvironment` beside the import service; every window observes `job`.
///
/// **Backing up** reads a consistent snapshot: open readers and note editors save first
/// (`flushEditors`), then every book's records are read with `LibraryStore.archive(bookID:)` in
/// one main-actor pass with no suspension point between books. All hashing, archiving and
/// uploading then runs off the main actor (`@concurrent`), checking cancellation every 4 MiB.
///
/// **Restoring** (`openBackup` → `restore`) extracts the chosen books into `Restores/<session>/`
/// under the store's root, verifying every file, then commits each book on the main actor with a
/// journal (`RestoreCommit`); an interrupted commit is finished at the next launch
/// (`RestoreRecovery`).
@Observable
@MainActor
final class BackupService {
    /// The running job, `nil` when idle.
    private(set) var job: BackupJob?
    var isBusy: Bool { job != nil }

    @ObservationIgnored let store: LibraryStore
    /// Attributes the restore's store changes.
    @ObservationIgnored let origin = ChangeOrigin(label: "backup")
    /// Where backup files and downloaded snapshots are made (`tmp/Backups`).
    @ObservationIgnored let temporaryRoot: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let flushEditors: @MainActor () async -> Void
    /// Awaited before every job (`AppEnvironment` sets it to its launch work, which finishes
    /// interrupted restores and removes their leftovers).
    @ObservationIgnored var waitUntilReady: @MainActor () async -> Void
    /// Free bytes on the volume holding a URL (`nil`: unknown, the check is skipped). Tests inject it.
    @ObservationIgnored var availableCapacity: @Sendable (URL) -> Int64? = BackupService.volumeAvailableCapacity
    /// Who made the backup (recorded in the manifest and the snapshot name).
    @ObservationIgnored var makeMetadata: @MainActor () -> BackupMetadata = BackupService.defaultMetadata
    /// Tests only: stop each book's commit after this step, as a crash would, and leave the
    /// session's files in place.
    @ObservationIgnored var stopCommitAfter: RestoreCommit.Step?

    /// Space kept free beyond an estimate.
    nonisolated static let spaceMargin: Int64 = 32 * 1024 * 1024
    nonisolated static let lastSuccessKeyPrefix = "backup.lastSuccess."

    /// - Parameters:
    ///   - flushEditors: saves every open editor's pending text and ink and waits (default: the
    ///     live editors on `store`, `OpenEditorRegistry`).
    ///   - waitUntilReady: awaited before every job (the app passes its launch work, which
    ///     finishes interrupted restores).
    init(store: LibraryStore, temporaryRoot: URL? = nil, defaults: UserDefaults = .standard,
         flushEditors: (@MainActor () async -> Void)? = nil, waitUntilReady: @escaping @MainActor () async -> Void = {}) {
        self.store = store
        self.temporaryRoot = temporaryRoot
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Backups", isDirectory: true)
        self.defaults = defaults
        self.flushEditors = flushEditors ?? { [weak store] in
            guard let store else { return }
            await OpenEditorRegistry.shared.flushAll(store: store)
        }
        self.waitUntilReady = waitUntilReady
    }

    // MARK: Running jobs

    /// Runs `body` as the app's one job.
    func run<T: Sendable>(_ kind: BackupJob.Kind, _ body: @escaping @MainActor (BackupJob) async throws -> T) async throws -> T {
        guard job == nil else { throw BackupServiceError.busy }
        let job = BackupJob(kind: kind)
        self.job = job
        defer { if self.job === job { self.job = nil } }
        let waitUntilReady = waitUntilReady
        let task = Task { @MainActor in
            await waitUntilReady()
            try Task.checkCancellation()
            return try await body(job)
        }
        job.cancelAction = { task.cancel() }
        if job.isCancelled { task.cancel() }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        job.set(fraction: 1)
        return result
    }

    // MARK: Temporary files

    /// A new empty directory under `temporaryRoot` for one job's files.
    func makeTemporaryDirectory() throws -> URL {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Deletes a finished backup file (and its folder) made by `backUpToFile`. Files outside the
    /// temporary directory are left alone.
    func discardTemporaryFile(_ url: URL) {
        let root = temporaryRoot.standardizedFileURL.path
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.path.hasPrefix(root + "/"), folder.deletingLastPathComponent().path == root else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every temporary file of earlier runs. Called at launch, before any job.
    func removeStaleTemporaryFiles() {
        guard job == nil else { return }
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// Throws `notEnoughSpace` when the volume holding `url` has less than `required` (plus a
    /// margin) free.
    func checkSpace(_ required: Int64, at url: URL) throws {
        guard let available = availableCapacity(url) else { return }
        let needed = required + Self.spaceMargin
        if available < needed { throw BackupServiceError.notEnoughSpace(required: needed, available: available) }
    }

    nonisolated static func volumeAvailableCapacity(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func defaultMetadata() -> BackupMetadata {
        let info = Bundle.main.infoDictionary ?? [:]
        return BackupMetadata(createdAt: Date(), appVersion: info["CFBundleShortVersionString"] as? String ?? "",
                              appBuild: info["CFBundleVersion"] as? String ?? "", deviceName: UIDevice.current.name)
    }

    // MARK: Last success

    /// When the last backup to this destination succeeded, or `nil`.
    func lastSuccessfulBackup(destinationID: String) -> Date? {
        defaults.object(forKey: Self.lastSuccessKeyPrefix + destinationID) as? Date
    }

    func recordSuccess(destinationID: String, at date: Date) {
        defaults.set(date, forKey: Self.lastSuccessKeyPrefix + destinationID)
    }
}
