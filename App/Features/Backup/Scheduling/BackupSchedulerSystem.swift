import BackgroundTasks
import Foundation
import UIKit

// The scheduler's only contact with BGTaskScheduler and UIApplication, behind small protocols so
// its logic is tested with fakes (`BackupSchedulerTestSupport`).

/// A background processing request, as the scheduler describes it.
nonisolated struct BackupBackgroundTaskRequest: Equatable, Sendable {
    var identifier: String
    /// `nil`: no start delay.
    var earliestBeginDate: Date?
    var requiresNetworkConnectivity: Bool
    var requiresExternalPower: Bool
}

/// A background task the system launched the app to run.
@MainActor
protocol BackupBackgroundTaskHandle: AnyObject {
    /// Called (on the main actor) shortly before the task's time runs out.
    var expirationHandler: (@MainActor () -> Void)? { get set }
    /// Tells the system the task is finished. The scheduler calls it exactly once per task.
    func setTaskCompleted(success: Bool)
}

/// `BGTaskScheduler`, as the scheduler uses it.
@MainActor
protocol BackupTaskScheduling: AnyObject {
    /// Registers the launch handler for `identifier`; `false` when it was not registered (the
    /// identifier is not permitted by `Info.plist`, or it is already registered in this process).
    /// The handler runs on the main actor.
    func register(identifier: String, launchHandler: @escaping @MainActor (any BackupBackgroundTaskHandle) -> Void) -> Bool
    /// Submits (or replaces) the pending request with the request's identifier.
    func submit(_ request: BackupBackgroundTaskRequest) throws
    /// Cancels the pending request with this identifier, if any.
    func cancel(identifier: String)
}

/// `UIApplication`'s background-time assertions, as the scheduler uses them.
@MainActor
protocol BackupAppLifecycle: AnyObject {
    /// Asks for time to finish work if the app moves to the background. `expirationHandler` runs
    /// on the main actor shortly before that time runs out and must end the assertion. Returns
    /// `.invalid` when no time can be given.
    func beginBackgroundTask(name: String, expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

// MARK: - Live

/// The real `BGTaskScheduler.shared`.
final class SystemBackupTaskScheduler: BackupTaskScheduling {
    /// Identifiers registered in this process: a second registration of one kills the app.
    private static var registered: Set<String> = []

    func register(identifier: String, launchHandler: @escaping @MainActor (any BackupBackgroundTaskHandle) -> Void) -> Bool {
        guard !Self.registered.contains(identifier) else { return false }
        // The main queue, so the handler can run on the main actor.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { launchHandler(SystemBackupBackgroundTask(task)) }
        }
        if registered { Self.registered.insert(identifier) }
        return registered
    }

    func submit(_ request: BackupBackgroundTaskRequest) throws {
        let processing = BGProcessingTaskRequest(identifier: request.identifier)
        processing.earliestBeginDate = request.earliestBeginDate
        processing.requiresNetworkConnectivity = request.requiresNetworkConnectivity
        processing.requiresExternalPower = request.requiresExternalPower
        // The synchronous `submit(_:)` is deprecated from iOS 27 in favour of an async variant
        // that reports more errors; it is used on every system so that a submission and a later
        // cancellation always reach the scheduler in the order they were made.
        try BGTaskScheduler.shared.submit(processing)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// A `BGTask` handed to the scheduler.
final class SystemBackupBackgroundTask: BackupBackgroundTaskHandle {
    private let task: BGTask

    init(_ task: BGTask) { self.task = task }

    var expirationHandler: (@MainActor () -> Void)? {
        didSet {
            guard let handler = expirationHandler else {
                task.expirationHandler = nil
                return
            }
            // The system does not say which thread calls the expiration handler.
            task.expirationHandler = {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { handler() }
                } else {
                    DispatchQueue.main.async { handler() }
                }
            }
        }
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

/// The real `UIApplication.shared`.
final class SystemBackupAppLifecycle: BackupAppLifecycle {
    func beginBackgroundTask(name: String, expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// Work that shares the backup's background processing task (sync, `SyncScheduler`).
@MainActor
protocol BackupBackgroundCompanion: AnyObject {
    /// Whether the task should be submitted for this work (with the network required), even
    /// when no backup is pending.
    var wantsBackgroundTime: Bool { get }
    /// Runs in the task, after the backup's run.
    func runInBackgroundTask() async
    /// The task's time is running out: stop at once.
    func cancelBackgroundTaskRun()
}
