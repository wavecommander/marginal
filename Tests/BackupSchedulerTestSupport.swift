import Foundation
import ReaderBackup
import ReaderCore
import Testing
import UIKit
@testable import Marginal

// Fakes and a test rig for `BackupScheduler` (B5b): the system scheduler, background tasks,
// background-time assertions, a settable clock, a sleep the test releases, and a destination
// that fails on request.

@MainActor
final class FakeTaskScheduler: BackupTaskScheduling {
    private(set) var handlers: [String: @MainActor (any BackupBackgroundTaskHandle) -> Void] = [:]
    private(set) var submitted: [BackupBackgroundTaskRequest] = []
    private(set) var cancelled: [String] = []
    /// Every call in order: "register:<id>", "submit:<id>", "cancel:<id>".
    private(set) var calls: [String] = []
    var registerResult = true
    var submitError: (any Error)?

    func register(identifier: String, launchHandler: @escaping @MainActor (any BackupBackgroundTaskHandle) -> Void) -> Bool {
        calls.append("register:\(identifier)")
        guard registerResult, handlers[identifier] == nil else { return false }
        handlers[identifier] = launchHandler
        return true
    }

    func submit(_ request: BackupBackgroundTaskRequest) throws {
        calls.append("submit:\(request.identifier)")
        if let submitError { throw submitError }
        submitted.append(request)
    }

    func cancel(identifier: String) {
        calls.append("cancel:\(identifier)")
        cancelled.append(identifier)
    }

    /// The system launching the app for the task.
    func launch(_ identifier: String, with task: FakeBackgroundTask) {
        handlers[identifier]?(task)
    }
}

@MainActor
final class FakeBackgroundTask: BackupBackgroundTaskHandle {
    var expirationHandler: (@MainActor () -> Void)?
    private(set) var completions: [Bool] = []

    func setTaskCompleted(success: Bool) { completions.append(success) }

    /// The system's time for the task running out.
    func expire() {
        let handler = expirationHandler
        handler?()
    }
}

@MainActor
final class FakeAppLifecycle: BackupAppLifecycle {
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var handlers: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
    private var next = 100

    var outstanding: Int { begun.count - ended.count }

    func beginBackgroundTask(name: String, expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        next += 1
        let identifier = UIBackgroundTaskIdentifier(rawValue: next)
        begun.append(identifier)
        handlers[identifier] = expirationHandler
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
        handlers[identifier] = nil
    }

    /// The background time of every outstanding assertion running out.
    func expireAll() {
        for handler in handlers.values { handler() }
    }
}

/// A clock the test sets.
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date = Date()) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A sleep that returns only when the test releases it (or throws when its task is cancelled).
@MainActor
final class ManualSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var waiting: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Lets every current sleep return.
    func releaseAll() {
        let current = waiters
        waiters = [:]
        for continuation in current.values { continuation.resume() }
    }
}

/// `UserDefaults` that counts writes of the last-change key.
final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var changeWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == BackupAutomaticSettings.Key.lastChangeAt { changeWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}

struct TestUploadError: LocalizedError {
    var errorDescription: String? { "The test destination refused the upload." }
}

/// A folder destination that can be told to fail uploads or report itself unavailable.
final class ScriptedDestination: BackupDestination, @unchecked Sendable {
    let folder: FolderBackupDestination
    private let lock = NSLock()
    private var _failUploads = false
    private var _unavailableReason: String?

    init(folder: FolderBackupDestination) { self.folder = folder }

    var failUploads: Bool {
        get { lock.withLock { _failUploads } }
        set { lock.withLock { _failUploads = newValue } }
    }

    var unavailableReason: String? {
        get { lock.withLock { _unavailableReason } }
        set { lock.withLock { _unavailableReason = newValue } }
    }

    var id: String { folder.id }
    var displayName: String { folder.displayName }

    func availability() async -> BackupDestinationAvailability {
        if let reason = unavailableReason { return .unavailable(reason: reason) }
        return await folder.availability()
    }

    func listSnapshots() async throws -> [BackupSnapshotInfo] { try await folder.listSnapshots() }

    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        if failUploads { throw TestUploadError() }
        return try await folder.uploadSnapshot(from: file, name: name, progress: progress)
    }

    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        try await folder.downloadSnapshot(snapshot, to: file, progress: progress)
    }

    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws { try await folder.deleteSnapshot(snapshot) }

    func hasPDF(sha256: String, size: Int64) async throws -> Bool { try await folder.hasPDF(sha256: sha256, size: size) }

    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        if failUploads { throw TestUploadError() }
        try await folder.uploadPDF(from: file, sha256: sha256, size: size, progress: progress)
    }

    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        try await folder.downloadPDF(sha256: sha256, to: file, progress: progress)
    }
}

@MainActor
final class Flag {
    var isOn = false
}

/// A store, a real `BackupService`, a scripted folder destination registered under `id`, the
/// settings (on) and a scheduler on fakes.
@MainActor
final class SchedulerRig {
    let scratch: URL
    let store: LibraryStore
    let service: BackupService
    let defaults: CountingDefaults
    let settings: BackupAutomaticSettings
    let destinations = BackupDestinationRegistry()
    let destination: ScriptedDestination
    let taskScheduler = FakeTaskScheduler()
    let lifecycle = FakeAppLifecycle()
    /// Ten minutes ahead of the real time: `BackupService` records successes with the real time,
    /// and the due rule ignores a success dated after its clock (as after the clock is set back).
    let clock = TestClock(Date().addingTimeInterval(600))
    let sleeper = ManualSleeper()
    /// The service's editor flush waits here when `holdRuns` is set (so a run can be caught
    /// in progress).
    let latch: TestLatch
    private let hold: Flag
    var holdRuns: Bool {
        get { hold.isOn }
        set { hold.isOn = newValue }
    }
    private(set) var scheduler: BackupScheduler!
    private let suiteName: String

    /// - Parameters:
    ///   - seed: import two books with notes and ink.
    ///   - destinationID: the destination's ID (default `folder:<path>`).
    ///   - enabled: automatic backups on, with this destination chosen.
    ///   - armed: as for a normal launch (`false`: a `-resetState` launch).
    init(seed: Bool = true, destinationID: String? = nil, enabled: Bool = true, armed: Bool = true) async throws {
        let scratch = try BackupTestSupport.scratch("BackupScheduler")
        let latch = TestLatch()
        let hold = Flag()
        self.scratch = scratch
        self.latch = latch
        self.hold = hold
        let suiteName = "BackupSchedulerTests-\(UUID().uuidString)"
        self.suiteName = suiteName
        store = try LibraryStore.ephemeral()
        defaults = CountingDefaults(suiteName: suiteName)!
        let serviceDefaults = UserDefaults(suiteName: suiteName + "-service")!
        service = BackupService(store: store, temporaryRoot: scratch.appendingPathComponent("tmp", isDirectory: true),
                                defaults: serviceDefaults, flushEditors: {
                                    if hold.isOn { await latch.wait() }
                                })
        // Snapshot names are to the second: give each backup its own.
        let counter = Counter()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        service.makeMetadata = {
            counter.value += 1
            return BackupMetadata(createdAt: base.addingTimeInterval(Double(counter.value)), appVersion: "test", appBuild: "1",
                                  deviceName: "Test iPad")
        }
        let folderRoot = scratch.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        destination = ScriptedDestination(folder: FolderBackupDestination(root: folderRoot, id: destinationID))
        settings = BackupAutomaticSettings(defaults: defaults)
        destinations.register(destination)
        if enabled {
            settings.isEnabled = true
            settings.destinationID = destination.id
            settings.includesPDFs = true
        }
        if seed { _ = try await BackupTestSupport.seedLibrary(store) }
        let clock = clock
        let sleeper = sleeper
        scheduler = BackupScheduler(settings: settings, service: service, destinations: destinations, armed: armed,
                                    taskScheduler: taskScheduler, lifecycle: lifecycle,
                                    now: { clock.now }, sleep: { try await sleeper.sleep($0) })
    }

    func snapshots() async throws -> [BackupSnapshotInfo] { try await destination.listSnapshots() }

    func tearDown() {
        scheduler.cancelRun()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removePersistentDomain(forName: suiteName + "-service")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: store.rootDirectory)
    }
}
