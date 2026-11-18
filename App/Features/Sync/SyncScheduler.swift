import Foundation
import os
import ReaderCore
import SwiftUI
import UIKit

let syncSchedulerLog = Logger(subsystem: "software.tactile.texts", category: "SyncScheduler")

/// What the scheduler runs: one sync round (`SyncService`), behind a protocol so its rules are
/// tested with a fake.
@MainActor
protocol SyncRoundRunning: AnyObject {
    /// Runs one round (or waits for the one running) and returns the status it left.
    func runRound(manual: Bool) async -> SyncStatus
    /// Stops the round in progress, if any, and waits for it to stop.
    func stopRound() async
}

extension SyncService: SyncRoundRunning {
    func runRound(manual: Bool) async -> SyncStatus {
        await syncNow()
        return status
    }

    func stopRound() async { await stop() }
}

/// What started a round.
nonisolated enum SyncTrigger: Equatable, Sendable {
    /// A few seconds after a library change settled.
    case libraryChanged
    /// The app went to the background (inside a background-time assertion).
    case wentToBackground
    /// The app became active.
    case appActivated
    /// A window became active while the app was already active.
    case windowActivated
    /// Every two minutes while the app is in front.
    case foregroundTick
    /// The existing background processing task (`BackupScheduler`'s), when the system runs it.
    case backgroundTask
    /// The network came back after a round found it gone.
    case networkReturned
    /// The Sync switch was turned on.
    case switchedOn
    /// Sync Now (or Try Again).
    case manual

    /// Rounds the reader asked for: they run through a back-off and reset it.
    var isManual: Bool { self == .manual || self == .switchedOn }
}

/// When a round may start. Pure: every input is passed in (`SyncSchedulerTests`).
nonisolated enum SyncScheduleRule {
    enum Skip: Equatable, Sendable {
        /// The switch is off, or nobody is signed in (the switch then reads as off).
        case off
        /// A backup or restore runs: one job at a time (the service refuses too).
        case backupRunning
        /// Backing off after failures, until this date.
        case backingOff(until: Date)
    }

    /// `nil`: run now.
    static func skip(isOn: Bool, backupRunning: Bool, trigger: SyncTrigger, backoffUntil: Date?, now: Date) -> Skip? {
        guard isOn else { return .off }
        guard !backupRunning else { return .backupRunning }
        if !trigger.isManual, trigger != .networkReturned, let until = backoffUntil, until > now { return .backingOff(until: until) }
        return nil
    }
}

/// How long to wait after failed rounds: doubling from `base`, up to `ceiling`.
nonisolated struct SyncBackoff: Equatable, Sendable {
    var base: TimeInterval
    var ceiling: TimeInterval

    /// 30 seconds, doubling, at most 15 minutes.
    static let standard = SyncBackoff(base: 30, ceiling: 15 * 60)

    /// The wait after `failures` failed rounds in a row (0: none).
    func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 30)
        return min(ceiling, base * pow(2, Double(exponent)))
    }

    /// How a round's status counts: `true` failed (grow), `false` succeeded (reset), `nil`
    /// neither (waiting for the reader, the key, a backup or a newer app).
    static func counts(_ status: SyncStatus) -> Bool? {
        switch status {
        case .failed, .waiting(.offline): true
        case .upToDate, .waiting(.editInProgress), .waiting(.pullOnly), .waiting(.needsNewerApp): false
        case .idle, .syncing, .needsJoinConfirmation, .needsKey, .waiting(.signedOut), .waiting(.backupOrRestore),
             .waiting(.accountNeedsNewerApp):
            nil
        }
    }
}

/// When sync runs (`docs/CLOUD_SYNC_PLAN.md` "On the iPad", C4b). One per app, owned by
/// `SyncController`, in the style of `BackupScheduler`:
///
/// - **After a change.** Every change on the store's hub that a backup would hold
///   (`StoreChange.affectsBackup`), except sync's own (`syncOrigin`), restarts a short timer
///   (`changeDelay`, a few seconds); a round runs when it ends, so a burst of edits is one round.
/// - **Going to the background**: a round at once, inside a background-time assertion; when
///   that time runs out the round is stopped (it is safe to cut off anywhere) and the
///   assertion ended.
/// - **A window becoming active** (the app's or any window's scene), and **every
///   `tickInterval` (two minutes) while the app is in front**.
/// - **The background processing task**: `BackupScheduler` runs it and asks this scheduler
///   (`BackupBackgroundCompanion`) to sync in it while the switch is on.
/// - **Never** while the switch is off or nobody is signed in, or while a backup or restore runs
///   (the service refuses as well; this only saves the attempt).
/// - **Back-off**: after failed rounds (a failure, or the network gone) automatic triggers wait
///   `SyncBackoff` (growing to a ceiling); a success, Sync Now, or turning the switch on resets
///   it, and the network coming back runs a round at once.
@MainActor
final class SyncScheduler {
    nonisolated static let defaultChangeDelay: Duration = .seconds(3)
    nonisolated static let defaultTickInterval: Duration = .seconds(120)

    /// What a call to `run(_:)` did.
    enum Outcome: Equatable {
        case skipped(SyncScheduleRule.Skip)
        /// A round of this scheduler's was already running; nothing more was started.
        case alreadyRunning
        case ran(SyncStatus)
    }

    let settings: SyncSettings
    private let runner: any SyncRoundRunning
    private let isBackupRunning: () -> Bool
    private let syncOrigin: ChangeOrigin?
    private let lifecycle: any BackupAppLifecycle
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let changeDelay: Duration
    private let tickInterval: Duration
    private let backoff: SyncBackoff

    /// Called after every round with its status and trigger (`SyncController`: PDFs, the
    /// synced-book list).
    var afterRound: ((SyncStatus, SyncTrigger) -> Void)?

    /// Failed rounds in a row.
    private(set) var failures = 0
    /// Automatic rounds wait until then.
    private(set) var backoffUntil: Date?
    /// The last round's status.
    private(set) var lastStatus: SyncStatus?
    /// Rounds this scheduler started, by trigger (tests and diagnostics).
    private(set) var triggers: [SyncTrigger] = []
    private(set) var isInForeground = false
    var isRunning: Bool { currentRun != nil }

    private var hubToken: StoreChangeObservation?
    private var pendingChange: Task<Void, Never>?
    private var ticks: Task<Void, Never>?
    private var currentRun: Task<Outcome, Never>?
    private var assertion = UIBackgroundTaskIdentifier.invalid

    init(runner: any SyncRoundRunning, settings: SyncSettings, hub: StoreChangeHub, syncOrigin: ChangeOrigin?,
         isBackupRunning: @escaping () -> Bool,
         lifecycle: any BackupAppLifecycle = SystemBackupAppLifecycle(),
         now: @escaping () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         changeDelay: Duration = SyncScheduler.defaultChangeDelay,
         tickInterval: Duration = SyncScheduler.defaultTickInterval,
         backoff: SyncBackoff = .standard) {
        self.runner = runner
        self.settings = settings
        self.syncOrigin = syncOrigin
        self.isBackupRunning = isBackupRunning
        self.lifecycle = lifecycle
        self.now = now
        self.sleep = sleep
        self.changeDelay = changeDelay
        self.tickInterval = tickInterval
        self.backoff = backoff
        hubToken = hub.observe { [weak self] event in self?.noteChange(event) }
    }

    // MARK: Scene phase

    /// The app's scene phase (`TactileTextsApp` forwards it).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInForeground = true
            startTicks()
            Task { await self.run(.appActivated) }
        case .background:
            isInForeground = false
            stopTicks()
            pendingChange?.cancel()
            pendingChange = nil
            runInBackgroundTime()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// A window's own scene became active (`WindowRootView`): another window coming forward while
    /// the app is active.
    func windowBecameActive() {
        guard isInForeground else { return }
        Task { await self.run(.windowActivated) }
    }

    /// The network came back (`SyncNetworkMonitor`): a round at once when the last one found it
    /// gone.
    func networkBecameAvailable() {
        guard lastStatus == .waiting(.offline) else { return }
        Task { await self.run(.networkReturned) }
    }

    // MARK: Running

    /// Runs a round if the rules allow (`SyncScheduleRule`). Never starts a second round of its
    /// own while one is running.
    @discardableResult
    func run(_ trigger: SyncTrigger) async -> Outcome {
        if trigger.isManual {
            failures = 0
            backoffUntil = nil
        }
        if let skip = SyncScheduleRule.skip(isOn: settings.isEnabled, backupRunning: isBackupRunning(), trigger: trigger,
                                            backoffUntil: backoffUntil, now: now()) {
            return .skipped(skip)
        }
        if let currentRun {
            // A manual round waits for the running one and then reports its status.
            guard trigger.isManual else { return .alreadyRunning }
            return await currentRun.value
        }
        let run = Task { await self.perform(trigger) }
        currentRun = run
        let outcome = await run.value
        if currentRun == run { currentRun = nil }
        return outcome
    }

    private func perform(_ trigger: SyncTrigger) async -> Outcome {
        triggers.append(trigger)
        let status = await runner.runRound(manual: trigger.isManual)
        lastStatus = status
        switch SyncBackoff.counts(status) {
        case true?:
            failures += 1
            backoffUntil = now().addingTimeInterval(backoff.delay(afterFailures: failures))
        case false?:
            failures = 0
            backoffUntil = nil
        case nil:
            break
        }
        syncSchedulerLog.notice("round (\(String(describing: trigger), privacy: .public)): \(Self.describe(status), privacy: .public)")
        afterRound?(status, trigger)
        return .ran(status)
    }

    /// Stops the round in progress (the switch turned off, a sign-in change).
    func stop() async {
        pendingChange?.cancel()
        pendingChange = nil
        await runner.stopRound()
    }

    /// For the log: the status without any message text.
    nonisolated static func describe(_ status: SyncStatus) -> String {
        switch status {
        case .failed: "failed"
        default: String(describing: status)
        }
    }

    // MARK: Background time

    /// A round at once, inside a background-time assertion; the round is stopped and the
    /// assertion ended when the time runs out.
    private func runInBackgroundTime() {
        guard SyncScheduleRule.skip(isOn: settings.isEnabled, backupRunning: isBackupRunning(), trigger: .wentToBackground,
                                    backoffUntil: backoffUntil, now: now()) == nil else { return }
        beginAssertion()
        Task {
            await self.run(.wentToBackground)
            self.endAssertion()
        }
    }

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = lifecycle.beginBackgroundTask(name: "Sync") { [weak self] in
            guard let self else { return }
            syncSchedulerLog.notice("background time for sync ran out")
            let runner = self.runner
            Task { await runner.stopRound() }
            self.endAssertion()
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        let identifier = assertion
        assertion = .invalid
        lifecycle.endBackgroundTask(identifier)
    }

    // MARK: Ticks

    private func startTicks() {
        guard ticks == nil else { return }
        let sleep = sleep
        let interval = tickInterval
        ticks = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, !Task.isCancelled, self.isInForeground else { return }
                await self.run(.foregroundTick)
            }
        }
    }

    private func stopTicks() {
        ticks?.cancel()
        ticks = nil
    }

    // MARK: Changes

    /// A change on the hub: restarts the settle timer. Sync's own writes, and changes no backup
    /// holds (recognised text of scanned books), are ignored.
    private func noteChange(_ event: StoreChangeEvent) {
        guard event.change.affectsBackup, settings.isEnabled else { return }
        if let syncOrigin, event.isFrom(syncOrigin) { return }
        pendingChange?.cancel()
        let sleep = sleep
        let delay = changeDelay
        pendingChange = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingChange = nil
            await self.run(.libraryChanged)
        }
    }

    /// Whether a settle timer is waiting (tests).
    var hasPendingChange: Bool { pendingChange != nil }
}

// MARK: - The background processing task

extension SyncScheduler: BackupBackgroundCompanion {
    var wantsBackgroundTime: Bool { settings.isEnabled }

    func runInBackgroundTask() async {
        await run(.backgroundTask)
    }

    func cancelBackgroundTaskRun() {
        let runner = runner
        Task { await runner.stopRound() }
    }
}
