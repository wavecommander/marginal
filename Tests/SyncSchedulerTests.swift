import Foundation
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

/// A round runner the test scripts: each round returns `next` (or waits at `hold` first).
@MainActor
final class FakeSyncRunner: SyncRoundRunning {
    var next: SyncStatus = .upToDate(Date(timeIntervalSinceReferenceDate: 1))
    /// When set, rounds wait here until it opens (or the round is stopped).
    var hold: SyncTestGate?
    private(set) var rounds = 0
    private(set) var manualRounds = 0
    private(set) var stops = 0

    func runRound(manual: Bool) async -> SyncStatus {
        rounds += 1
        if manual { manualRounds += 1 }
        if let hold { await hold.wait() }
        return next
    }

    func stopRound() async {
        stops += 1
        hold?.open()
    }
}

/// `SyncScheduler` (C4b) on fakes: a scripted runner, a clock, a sleep the test releases, and
/// background-time assertions.
@MainActor
final class SyncSchedulerRig {
    let store: LibraryStore
    let runner = FakeSyncRunner()
    let lifecycle = FakeAppLifecycle()
    let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
    let sleeper = ManualSleeper()
    let syncOrigin = ChangeOrigin(label: "sync")
    let settings: SyncSettings
    let backupRunning = Flag()
    let scheduler: SyncScheduler
    private let suite: String

    init(on: Bool = true, account: String? = "account-1") throws {
        store = try LibraryStore.ephemeral()
        suite = "SyncSchedulerTests-\(UUID().uuidString)"
        settings = SyncSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.setAccount(account)
        if on { settings.isEnabled = true }
        let clock = clock, sleeper = sleeper, backupRunning = backupRunning
        scheduler = SyncScheduler(runner: runner, settings: settings, hub: store.hub, syncOrigin: syncOrigin,
                                  isBackupRunning: { backupRunning.isOn }, lifecycle: lifecycle,
                                  now: { clock.now }, sleep: { try await sleeper.sleep($0) })
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: store.rootDirectory)
    }
}

@MainActor
@Suite(.serialized)
struct SyncSchedulerTests {
    typealias Support = BackupTestSupport

    @Test func changesSettleIntoOneRoundAndSyncsOwnWritesAreIgnored() async throws {
        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        let book = UUID()
        for page in 0..<20 { rig.store.hub.post(.pageInkChanged(bookID: book, pageIndex: page), origin: nil) }
        // Each change restarts the timer: one sleeper waits.
        #expect(await Support.waitUntil { rig.sleeper.waiting == 1 })
        #expect(rig.runner.rounds == 0)
        rig.sleeper.releaseAll()
        #expect(await Support.waitUntil { rig.runner.rounds == 1 })
        #expect(rig.scheduler.triggers == [.libraryChanged])

        // Sync's own writes, and changes no backup holds, start nothing.
        rig.store.hub.post(.noteSaved(bookID: book, target: .page(1), noteID: UUID()), origin: rig.syncOrigin)
        rig.store.hub.post(.recognisedTextChanged(bookID: book, pageIndex: 1), origin: nil)
        #expect(!rig.scheduler.hasPendingChange)
        // Another window's change does.
        rig.store.hub.post(.bookmarksChanged(bookID: book, pageIndex: 1), origin: ChangeOrigin(label: "window"))
        #expect(rig.scheduler.hasPendingChange)
    }

    @Test func nothingRunsWhenOffSignedOutOrDuringABackup() async throws {
        let off = try SyncSchedulerRig(on: false)
        defer { off.tearDown() }
        #expect(await off.scheduler.run(.foregroundTick) == .skipped(.off))
        #expect(await off.scheduler.run(.manual) == .skipped(.off))
        off.store.hub.post(.bookSaved(bookID: UUID()), origin: nil)
        #expect(!off.scheduler.hasPendingChange, "a change while off schedules nothing")
        off.scheduler.scenePhaseChanged(.background)
        #expect(off.lifecycle.begun.isEmpty, "no background time asked for")

        let signedOut = try SyncSchedulerRig(on: true, account: nil)
        defer { signedOut.tearDown() }
        #expect(await signedOut.scheduler.run(.appActivated) == .skipped(.off))

        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        rig.backupRunning.isOn = true
        #expect(await rig.scheduler.run(.foregroundTick) == .skipped(.backupRunning))
        #expect(await rig.scheduler.run(.manual) == .skipped(.backupRunning))
        rig.backupRunning.isOn = false
        #expect(await rig.scheduler.run(.foregroundTick) == .ran(rig.runner.next))
        #expect(off.runner.rounds == 0 && signedOut.runner.rounds == 0 && rig.runner.rounds == 1)

        // Turned off later: no more rounds.
        rig.settings.isEnabled = false
        #expect(await rig.scheduler.run(.windowActivated) == .skipped(.off))
        #expect(rig.runner.rounds == 1)
    }

    @Test func goingToTheBackgroundRunsInsideAnAssertionAndStopsWhenTimeRunsOut() async throws {
        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.lifecycle.begun.count == 1)
        #expect(await Support.waitUntil { rig.runner.rounds == 1 && rig.lifecycle.outstanding == 0 }, "the assertion ends with the round")
        #expect(rig.scheduler.triggers == [.wentToBackground])

        // A round that outlasts the background time is stopped and the assertion ended.
        let gate = SyncTestGate()
        rig.runner.hold = gate
        rig.scheduler.scenePhaseChanged(.background)
        #expect(await Support.waitUntil { rig.runner.rounds == 2 && gate.isWaiting })
        #expect(rig.lifecycle.outstanding == 1)
        rig.lifecycle.expireAll()
        #expect(rig.lifecycle.outstanding == 0)
        #expect(await Support.waitUntil { rig.runner.stops == 1 }, "the round is stopped")
        #expect(await Support.waitUntil { !rig.scheduler.isRunning })
        #expect(rig.lifecycle.outstanding == 0)
    }

    @Test func theTwoMinuteTickRunsOnlyInFront() async throws {
        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.scenePhaseChanged(.active)
        #expect(await Support.waitUntil { rig.runner.rounds == 1 }, "activation runs a round")
        #expect(await Support.waitUntil { rig.sleeper.waiting == 1 }, "the tick waits")
        rig.sleeper.releaseAll()
        #expect(await Support.waitUntil { rig.runner.rounds == 2 })
        #expect(rig.scheduler.triggers == [.appActivated, .foregroundTick])
        #expect(await Support.waitUntil { rig.sleeper.waiting == 1 }, "and waits again")

        // Another window coming forward runs one too.
        rig.scheduler.windowBecameActive()
        #expect(await Support.waitUntil { rig.runner.rounds == 3 })

        // In the background the tick stops.
        rig.scheduler.scenePhaseChanged(.background)
        #expect(await Support.waitUntil { rig.runner.rounds == 4 && rig.sleeper.waiting == 0 })
        rig.sleeper.releaseAll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.runner.rounds == 4)
        rig.scheduler.windowBecameActive()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.runner.rounds == 4, "a window can't come forward while the app is away")
        #expect(!rig.scheduler.triggers.contains(.windowActivated) || rig.scheduler.triggers.filter { $0 == .windowActivated }.count == 1)
    }

    @Test func failuresBackOffAndASuccessOrSyncNowResetsIt() async throws {
        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        rig.runner.next = .failed("Couldn’t reach the account.")
        #expect(await rig.scheduler.run(.foregroundTick) == .ran(.failed("Couldn’t reach the account.")))
        let first = rig.clock.now.addingTimeInterval(30)
        #expect(rig.scheduler.backoffUntil == first)
        #expect(await rig.scheduler.run(.foregroundTick) == .skipped(.backingOff(until: first)))
        #expect(await rig.scheduler.run(.libraryChanged) == .skipped(.backingOff(until: first)))
        rig.clock.advance(31)
        #expect(await rig.scheduler.run(.foregroundTick) == .ran(.failed("Couldn’t reach the account.")))
        #expect(rig.scheduler.backoffUntil == rig.clock.now.addingTimeInterval(60), "it grows")
        #expect(rig.scheduler.failures == 2)
        for _ in 0..<8 {
            rig.clock.advance(3600)
            await rig.scheduler.run(.foregroundTick)
        }
        #expect(rig.scheduler.backoffUntil == rig.clock.now.addingTimeInterval(SyncBackoff.standard.ceiling), "to a ceiling")

        // Sync Now goes through the back-off and resets it.
        let rounds = rig.runner.rounds
        #expect(await rig.scheduler.run(.manual) == .ran(.failed("Couldn’t reach the account.")))
        #expect(rig.runner.rounds == rounds + 1)
        #expect(rig.scheduler.failures == 1, "counting again from the manual round")

        // Offline counts as a failure; the network coming back runs at once.
        rig.runner.next = .waiting(.offline)
        rig.clock.advance(3600)
        await rig.scheduler.run(.foregroundTick)
        #expect(rig.scheduler.backoffUntil != nil)
        rig.runner.next = .upToDate(rig.clock.now)
        rig.scheduler.networkBecameAvailable()
        #expect(await Support.waitUntil { rig.scheduler.lastStatus == .upToDate(rig.clock.now) })
        #expect(rig.scheduler.triggers.last == .networkReturned)
        #expect(rig.scheduler.backoffUntil == nil && rig.scheduler.failures == 0, "a success resets it")

        // The network returning when the last round was fine runs nothing extra.
        let before = rig.runner.rounds
        rig.scheduler.networkBecameAvailable()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.runner.rounds == before)
    }

    @Test func oneRoundAtATimeAndAManualRoundWaitsForTheRunningOne() async throws {
        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        let gate = SyncTestGate()
        rig.runner.hold = gate
        let first = Task { await rig.scheduler.run(.foregroundTick) }
        #expect(await Support.waitUntil { gate.isWaiting })
        #expect(await rig.scheduler.run(.windowActivated) == .alreadyRunning)
        let manual = Task { await rig.scheduler.run(.manual) }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        #expect(await first.value == .ran(rig.runner.next))
        #expect(await manual.value == .ran(rig.runner.next))
        #expect(rig.runner.rounds == 1)
    }

    @Test func theBackgroundTaskRunsSyncWhileTheSwitchIsOn() async throws {
        let rig = try SyncSchedulerRig()
        defer { rig.tearDown() }
        #expect(rig.scheduler.wantsBackgroundTime)
        await rig.scheduler.runInBackgroundTask()
        #expect(rig.scheduler.triggers == [.backgroundTask])
        rig.settings.isEnabled = false
        #expect(!rig.scheduler.wantsBackgroundTime)
    }
}
