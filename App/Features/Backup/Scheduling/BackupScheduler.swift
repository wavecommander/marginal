import Foundation
import Observation
import os
import ReaderBackup
import ReaderCore
import SwiftUI
import UIKit

let backupSchedulerLog = Logger(subsystem: "software.tactile.texts", category: "BackupScheduler")

/// Runs automatic backups. One per app, owned by `AppEnvironment`; the Backup screen only edits
/// `BackupAutomaticSettings`, which this reads and records into.
///
/// - **Change tracking.** Every change posted on the store's hub (a restore's own writes
///   included) marks the library changed, except changes whose `affectsBackup` is false
///   (recognised text and recognition state of scanned books). Bursts are coalesced: the time of the latest change is
///   written to the settings at most once per `changeCoalescingDelay`, and at once when the app
///   goes to the background or a run is considered. A change made while a backup or restore job
///   runs is recorded again when that job ends, so it is never hidden by the job's own success
///   time.
/// - **When.** `BackupDueRule` decides, with this scheduler's clock.
/// - **Triggers.** A scene becoming active (`scenePhaseChanged(.active)`), a check every
///   `foregroundCheckInterval` while the app stays in the foreground, and the background
///   processing task `taskIdentifier`, submitted whenever the app goes to the background with a
///   run pending (earliest begin: when it becomes due) and cancelled when automatic backups are
///   turned off or nothing is pending.
/// - **Running.** Waits for launch work (`waitUntilReady`: it finishes interrupted restores),
///   then backs up through `BackupService`, one run at a time. A run started in the foreground
///   holds a background-time assertion so it can finish if the app is put away. A cancelled run
///   and a run refused because another job is in progress are not recorded as attempts.
/// - **Test processes.** With `armed: false` (a launch that reset state) nothing runs or is
///   scheduled until automatic backups are switched on in this process.
@MainActor
final class BackupScheduler {
    /// The background processing task (`BGTaskSchedulerPermittedIdentifiers` in `project.yml`).
    nonisolated static let taskIdentifier = "software.tactile.texts.backup"
    nonisolated static let defaultChangeCoalescingDelay: Duration = .seconds(5)
    nonisolated static let defaultForegroundCheckInterval: Duration = .seconds(15 * 60)

    /// What started a run.
    enum Trigger: Equatable, Sendable {
        case sceneActivated
        case foregroundCheck
        case backgroundTask
    }

    /// What a run did.
    enum Outcome: Equatable, Sendable {
        /// This process reset state and automatic backups have not been switched on since.
        case disarmed
        /// Another automatic run is in progress; nothing was started.
        case alreadyRunning
        case notDue(BackupDueRule.Reason)
        case succeeded
        /// Recorded with this reader-facing message.
        case failed(message: String)
        /// Stopped (expired background time, or `cancelRun()`); not recorded.
        case cancelled
        /// Another backup or restore started first; not recorded.
        case busy
    }

    let settings: BackupAutomaticSettings
    let service: BackupService
    let destinations: BackupDestinationRegistry
    /// Awaited before every run (`AppEnvironment` sets it to its launch work).
    var waitUntilReady: @MainActor () async -> Void

    /// `false` in a process that reset state, until automatic backups are switched on in it.
    private(set) var isArmed: Bool
    /// Whether the background task's launch handler is registered (submitting without one is an
    /// error, so nothing is submitted until it is).
    private(set) var isBackgroundTaskRegistered = false
    /// `true` while an automatic run is in progress.
    var isRunning: Bool { currentRun != nil }
    /// The last request submitted to the system (diagnostics and tests).
    private(set) var lastSubmittedRequest: BackupBackgroundTaskRequest?

    private let taskScheduler: any BackupTaskScheduling
    private let lifecycle: any BackupAppLifecycle
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let changeCoalescingDelay: Duration
    private let foregroundCheckInterval: Duration

    private var hubToken: StoreChangeObservation?
    private var pendingChangeAt: Date?
    private var changeFlush: Task<Void, Never>?
    private var changedDuringJob = false
    private var isWatchingJob = false
    private var lastSeenEnabled: Bool

    private var currentRun: Task<Outcome, Never>?
    /// `true` while the current run is inside `BackupService.backUp` (its job is ours).
    private var ownsServiceJob = false
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var foregroundChecks: Task<Void, Never>?
    private var isInBackground = false

    /// - Parameters:
    ///   - armed: `false` for a process launched to reset state (`-resetState`).
    ///   - now: the clock every decision and recorded time uses.
    ///   - sleep: waits for the change coalescing and the foreground checks (tests shorten it).
    init(settings: BackupAutomaticSettings, service: BackupService, destinations: BackupDestinationRegistry,
         armed: Bool = true,
         taskScheduler: any BackupTaskScheduling = SystemBackupTaskScheduler(),
         lifecycle: any BackupAppLifecycle = SystemBackupAppLifecycle(),
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         changeCoalescingDelay: Duration = BackupScheduler.defaultChangeCoalescingDelay,
         foregroundCheckInterval: Duration = BackupScheduler.defaultForegroundCheckInterval,
         waitUntilReady: @escaping @MainActor () async -> Void = {}) {
        self.settings = settings
        self.service = service
        self.destinations = destinations
        self.isArmed = armed
        self.taskScheduler = taskScheduler
        self.lifecycle = lifecycle
        self.now = now
        self.sleep = sleep
        self.changeCoalescingDelay = changeCoalescingDelay
        self.foregroundCheckInterval = foregroundCheckInterval
        self.waitUntilReady = waitUntilReady
        self.lastSeenEnabled = settings.isEnabled
        hubToken = service.store.hub.observe { [weak self] event in self?.noteChange(event.change) }
        observeSettings()
    }

    // MARK: Background task registration

    /// Registers the background task's launch handler. Call once, before the app finishes
    /// launching (`TactileTextsApp.init`), as `BGTaskScheduler` requires.
    @discardableResult
    func registerBackgroundTask() -> Bool {
        guard !isBackgroundTaskRegistered else { return true }
        isBackgroundTaskRegistered = taskScheduler.register(identifier: Self.taskIdentifier) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: true)
                return
            }
            self.handleBackgroundTask(task)
        }
        if isBackgroundTaskRegistered {
            backupSchedulerLog.notice("background task \(Self.taskIdentifier, privacy: .public) registered")
        } else {
            backupSchedulerLog.error("background task \(Self.taskIdentifier, privacy: .public) not registered")
        }
        return isBackgroundTaskRegistered
    }

    // MARK: Scene phase

    /// The app's scene phase (`TactileTextsApp` forwards it).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInBackground = false
            startForegroundChecks()
            Task { await self.runIfDue(.sceneActivated) }
        case .background:
            isInBackground = true
            stopForegroundChecks()
            flushPendingChange()
            scheduleBackgroundTask()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: Running

    /// Runs an automatic backup if one is due. Never starts a second run while one is in
    /// progress (returns `.alreadyRunning`).
    @discardableResult
    func runIfDue(_ trigger: Trigger) async -> Outcome {
        guard isArmed else { return .disarmed }
        guard currentRun == nil else { return .alreadyRunning }
        let run = Task { await self.perform(trigger) }
        currentRun = run
        let outcome = await run.value
        if currentRun == run { currentRun = nil }
        backupSchedulerLog.notice("automatic backup (\(String(describing: trigger), privacy: .public)): \(String(describing: outcome), privacy: .public)")
        if isInBackground { scheduleBackgroundTask() }
        return outcome
    }

    /// Stops the automatic run in progress, if any (its job stops at the next chunk; nothing is
    /// recorded).
    func cancelRun() {
        currentRun?.cancel()
        if ownsServiceJob { service.job?.cancel() }
    }

    private func perform(_ trigger: Trigger) async -> Outcome {
        await waitUntilReady()
        if Task.isCancelled { return .cancelled }
        flushPendingChange()
        guard let id = settings.destinationID, let destination = destinations.destination(id: id) else {
            // Not due: the rule says why (off, no destination chosen, or not registered).
            if case .notDue(let reason) = BackupDueRule.decide(dueInputs(destination: .notRegistered), now: now()) {
                return .notDue(reason)
            }
            return .notDue(.destinationNotRegistered)
        }
        // Everything but availability first: asking a destination can be slow.
        if case .notDue(let reason) = BackupDueRule.decide(dueInputs(destination: .available), now: now()) {
            return .notDue(reason)
        }
        let availability = await destination.availability()
        if Task.isCancelled { return .cancelled }
        if case .notDue(let reason) = BackupDueRule.decide(dueInputs(destination: availability.isAvailable ? .available : .unavailable),
                                                           now: now()) {
            return .notDue(reason)
        }

        let startedAt = now()
        if trigger != .backgroundTask { beginAssertion() }
        defer { endAssertion() }
        ownsServiceJob = true
        defer { ownsServiceJob = false }
        do {
            _ = try await service.backUp(to: destination, includePDFs: settings.includesPDFs)
            settings.recordAttempt(at: startedAt, failureMessage: nil)
            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch BackupServiceError.busy {
            return .busy
        } catch {
            if Task.isCancelled { return .cancelled }
            let message = Self.readerFacingMessage(error)
            settings.recordAttempt(at: startedAt, failureMessage: message)
            backupSchedulerLog.error("automatic backup to \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed(message: message)
        }
    }

    nonisolated static func readerFacingMessage(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Background task

    /// The system launched the background task: run if due, then schedule the next one (or
    /// cancel it) and complete the task exactly once. On expiration the run is cancelled, the
    /// task rescheduled and completed unsuccessfully.
    func handleBackgroundTask(_ task: any BackupBackgroundTaskHandle) {
        let completion = BackgroundTaskCompletion(task)
        task.expirationHandler = { [weak self] in
            backupSchedulerLog.notice("background task expired")
            self?.cancelRun()
            self?.scheduleBackgroundTask()
            completion.complete(success: false)
        }
        isInBackground = true
        Task {
            let outcome: Outcome
            if let running = currentRun {
                outcome = await running.value
            } else {
                outcome = await runIfDue(.backgroundTask)
            }
            scheduleBackgroundTask()
            switch outcome {
            case .failed, .cancelled, .busy: completion.complete(success: false)
            case .disarmed, .alreadyRunning, .notDue, .succeeded: completion.complete(success: true)
            }
        }
    }

    /// Submits the background task for the next pending run (earliest begin: when it becomes
    /// due; network only for destinations that need it), or cancels it when nothing is pending
    /// or automatic backups are off.
    func scheduleBackgroundTask() {
        guard isBackgroundTaskRegistered, isArmed else { return }
        flushPendingChange()
        guard settings.isEnabled, let id = settings.destinationID else {
            cancelBackgroundTask()
            return
        }
        var inputs = dueInputs(destination: destinations.destination(id: id) == nil ? .notRegistered : .available)
        inputs.serviceIsBusy = false
        let current = now()
        guard let due = BackupDueRule.nextDueDate(inputs, now: current) else {
            cancelBackgroundTask()
            return
        }
        let request = BackupBackgroundTaskRequest(identifier: Self.taskIdentifier,
                                                  earliestBeginDate: due > current ? due : nil,
                                                  requiresNetworkConnectivity: Self.requiresNetwork(destinationID: id),
                                                  requiresExternalPower: false)
        do {
            try taskScheduler.submit(request)
            lastSubmittedRequest = request
            backupSchedulerLog.notice("background task submitted, earliest \(String(describing: request.earliestBeginDate), privacy: .public)")
        } catch {
            // The simulator refuses with `BGTaskScheduler.Error.unavailable`.
            backupSchedulerLog.error("background task not submitted: \(String(describing: error), privacy: .public)")
        }
    }

    private func cancelBackgroundTask() {
        guard isBackgroundTaskRegistered else { return }
        taskScheduler.cancel(identifier: Self.taskIdentifier)
        lastSubmittedRequest = nil
    }

    /// Whether automatic backups to this destination need the network: everything except the
    /// picked folder and a folder by path (a folder in iCloud Drive or another provider is
    /// written locally; the system uploads it).
    nonisolated static func requiresNetwork(destinationID: String) -> Bool {
        let local = destinationID == PickedFolderBackupDestination.destinationID
            || destinationID.hasPrefix("folder:")
        return !local
    }

    // MARK: Background time for a foreground run

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = lifecycle.beginBackgroundTask(name: "Automatic backup") { [weak self] in
            guard let self else { return }
            backupSchedulerLog.notice("background time for the automatic backup ran out")
            self.cancelRun()
            self.endAssertion()
            self.scheduleBackgroundTask()
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        let identifier = assertion
        assertion = .invalid
        lifecycle.endBackgroundTask(identifier)
    }

    // MARK: Foreground checks

    private func startForegroundChecks() {
        guard foregroundChecks == nil else { return }
        let sleep = sleep
        let interval = foregroundCheckInterval
        foregroundChecks = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.runIfDue(.foregroundCheck)
            }
        }
    }

    private func stopForegroundChecks() {
        foregroundChecks?.cancel()
        foregroundChecks = nil
    }

    // MARK: Inputs

    /// The due rule's inputs now, with the destination in `destination`.
    func dueInputs(destination: BackupDueRule.DestinationState) -> BackupDueRule.Inputs {
        let id = settings.destinationID
        let lastSuccess = id.flatMap { service.lastSuccessfulBackup(destinationID: $0) }
        return BackupDueRule.Inputs(
            isEnabled: settings.isEnabled, destinationID: id, destination: destination, serviceIsBusy: service.isBusy,
            lastChangeAt: settings.lastChangeAt, lastSuccessAt: lastSuccess,
            libraryIsEmpty: lastSuccess == nil ? ((try? service.store.books.allBooks().isEmpty) ?? true) : false,
            lastAttemptAt: settings.lastAttemptAt, lastAttemptFailed: settings.lastFailureMessage != nil)
    }

    // MARK: Change tracking

    /// A change posted on the hub. Changes that cannot alter what a backup holds
    /// (`StoreChange.affectsBackup` is false: a scanned book's recognised text and recognition
    /// state, derived from the PDF and never backed up) are ignored, so recognition progress never
    /// makes an automatic backup due.
    private func noteChange(_ change: StoreChange) {
        guard change.affectsBackup else { return }
        pendingChangeAt = now()
        if service.isBusy {
            changedDuringJob = true
            watchForJobEnd()
        }
        guard changeFlush == nil else { return }
        let sleep = sleep
        let delay = changeCoalescingDelay
        changeFlush = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.changeFlush = nil
            self?.flushPendingChange()
        }
    }

    /// Writes the latest coalesced change to the settings now.
    func flushPendingChange() {
        changeFlush?.cancel()
        changeFlush = nil
        guard let date = pendingChangeAt else { return }
        pendingChangeAt = nil
        settings.recordChange(at: date)
    }

    private func watchForJobEnd() {
        guard !isWatchingJob else { return }
        isWatchingJob = true
        withObservationTracking {
            _ = service.job
        } onChange: { [weak self] in
            Task { @MainActor in self?.jobMayHaveEnded() }
        }
    }

    private func jobMayHaveEnded() {
        isWatchingJob = false
        guard !service.isBusy else {
            watchForJobEnd()
            return
        }
        guard changedDuringJob else { return }
        changedDuringJob = false
        // Later than the success time the job may just have recorded.
        pendingChangeAt = now()
        flushPendingChange()
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        observeSettings()
        let enabled = settings.isEnabled
        defer { lastSeenEnabled = enabled }
        guard enabled != lastSeenEnabled else { return }
        if enabled {
            // Switched on in this process: a process that reset state may now run.
            isArmed = true
        } else {
            // Turned off: nothing may run in the background any more.
            cancelBackgroundTask()
        }
    }
}

/// Completes a background task once, whichever path gets there first.
@MainActor
private final class BackgroundTaskCompletion {
    private var task: (any BackupBackgroundTaskHandle)?

    init(_ task: any BackupBackgroundTaskHandle) { self.task = task }

    func complete(success: Bool) {
        guard let task else { return }
        self.task = nil
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
