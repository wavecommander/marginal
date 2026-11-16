import Foundation
import ReaderBackup
import ReaderCore
import Testing
import UIKit
@testable import TactileTexts

/// `BackupScheduler` (B5b), app-hosted, with a real `BackupService` and a temporary folder
/// destination; the system scheduler, background tasks and background-time assertions are fakes.
@MainActor
struct BackupSchedulerTests {
    typealias Support = BackupTestSupport
    let id = BackupScheduler.taskIdentifier

    // MARK: Change tracking

    @Test func aBurstOfChangesIsWrittenOnceWithTheLatestTime() async throws {
        let rig = try await SchedulerRig(seed: false)
        defer { rig.tearDown() }
        let book = UUID()
        let writesBefore = rig.defaults.changeWrites
        for index in 0..<50 {
            rig.clock.advance(1)
            rig.store.hub.post(.pageInkChanged(bookID: book, pageIndex: index), origin: nil)
        }
        let latest = rig.clock.now
        #expect(rig.settings.lastChangeAt == nil)
        #expect(rig.defaults.changeWrites == writesBefore)
        #expect(await Support.waitUntil { rig.sleeper.waiting == 1 })

        rig.sleeper.releaseAll()
        #expect(await Support.waitUntil { rig.settings.lastChangeAt == latest })
        #expect(rig.defaults.changeWrites == writesBefore + 1)

        // The next burst waits again; going to the background writes it at once.
        rig.clock.advance(10)
        rig.store.hub.post(.bookSaved(bookID: book), origin: ChangeOrigin(label: "backup"))
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.settings.lastChangeAt == rig.clock.now)
        #expect(rig.defaults.changeWrites == writesBefore + 2)
    }

    @Test func aChangeDuringABackupIsRecordedAfterItsSuccess() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.holdRuns = true
        let manual = Task { try await rig.service.backUp(to: rig.destination, includePDFs: false) }
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        rig.store.hub.post(.bookSaved(bookID: UUID()), origin: nil)
        // The job ends (and records its success) at the real time; the scheduler's clock is later.
        let jobEnd = Date().addingTimeInterval(3600)
        rig.clock.now = jobEnd
        rig.latch.open()
        _ = try await manual.value
        let success = try #require(rig.service.lastSuccessfulBackup(destinationID: rig.destination.id))
        #expect(success < jobEnd)
        #expect(await Support.waitUntil { rig.settings.lastChangeAt == jobEnd })
    }

    // MARK: Running

    @Test func aDueRunBacksUpAndRecordsSuccess() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        let started = rig.clock.now
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .succeeded)
        let snapshots = try await rig.snapshots()
        #expect(snapshots.count == 1)
        #expect(rig.settings.lastAttemptAt == started)
        #expect(rig.settings.lastFailureMessage == nil)
        #expect(rig.service.lastSuccessfulBackup(destinationID: rig.destination.id) != nil)
        // The PDFs went too (automatic backups include them by default).
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: rig.destination.folder.root.appendingPathComponent("PDFs").path)
        #expect(pdfs.count == 2)
        // A foreground run holds a background-time assertion and ends it.
        #expect(rig.lifecycle.begun.count == 1)
        #expect(rig.lifecycle.outstanding == 0)

        // Nothing changed since: not due. A change is then too soon, until 24 hours have passed.
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .notDue(.noChanges))
        let success = try #require(rig.service.lastSuccessfulBackup(destinationID: rig.destination.id))
        rig.clock.now = success.addingTimeInterval(60)
        rig.store.hub.post(.bookSaved(bookID: UUID()), origin: nil)
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .notDue(.tooSoon(until: success.addingTimeInterval(BackupDueRule.interval))))
        rig.clock.now = success.addingTimeInterval(BackupDueRule.interval)
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .succeeded)
        #expect(try await rig.snapshots().count == 2)
    }

    @Test func notDueForAnEmptyLibraryAnUnavailableOrUnknownDestination() async throws {
        let empty = try await SchedulerRig(seed: false)
        defer { empty.tearDown() }
        #expect(await empty.scheduler.runIfDue(.sceneActivated) == .notDue(.emptyLibrary))

        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.destination.unavailableReason = "Not here."
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .notDue(.destinationUnavailable))
        rig.destination.unavailableReason = nil
        rig.settings.destinationID = "folder:/nowhere"
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .notDue(.destinationNotRegistered))
        rig.settings.destinationID = nil
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .notDue(.noDestination))
        rig.settings.destinationID = rig.destination.id
        rig.settings.isEnabled = false
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .notDue(.disabled))
        #expect(try await rig.snapshots().isEmpty)
        #expect(rig.settings.lastAttemptAt == nil)
    }

    @Test func aFailingDestinationRecordsTheMessageAndBacksOff() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.destination.failUploads = true
        let attempt = rig.clock.now
        let message = "The test destination refused the upload."
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .failed(message: message))
        #expect(rig.settings.lastFailureMessage == message)
        #expect(rig.settings.lastAttemptAt == attempt)
        #expect(rig.service.lastSuccessfulBackup(destinationID: rig.destination.id) == nil)

        rig.clock.advance(30 * 60)
        let until = attempt.addingTimeInterval(BackupDueRule.failureBackoff)
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .notDue(.backingOff(until: until)))

        // Going to the background schedules the retry for when the back-off ends.
        rig.scheduler.registerBackgroundTask()
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted.last?.earliestBeginDate == until)

        rig.clock.now = until
        rig.destination.failUploads = false
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .succeeded)
        #expect(rig.settings.lastFailureMessage == nil)
        #expect(rig.settings.lastAttemptAt == until)
    }

    @Test func aSecondTriggerWhileARunIsInProgressStartsNothing() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.holdRuns = true
        let first = Task { await rig.scheduler.runIfDue(.sceneActivated) }
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        #expect(rig.scheduler.isRunning)
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .alreadyRunning)
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .alreadyRunning)
        rig.latch.open()
        #expect(await first.value == .succeeded)
        #expect(!rig.scheduler.isRunning)
        #expect(rig.latch.arrivals == 1)
        #expect(try await rig.snapshots().count == 1)
    }

    @Test func neverDueWhileAnotherJobRuns() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.holdRuns = true
        let manual = Task { try await rig.service.backUpToFile(includePDFs: false) }
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .notDue(.serviceBusy))
        rig.latch.open()
        let file = try await manual.value
        rig.service.discardTemporaryFile(file.url)
        #expect(rig.settings.lastAttemptAt == nil)
    }

    @Test func cancellationIsNotRecordedAsAFailure() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.holdRuns = true
        let run = Task { await rig.scheduler.runIfDue(.sceneActivated) }
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        rig.scheduler.cancelRun()
        #expect(rig.service.job?.isCancelled == true)
        rig.latch.open()
        #expect(await run.value == .cancelled)
        #expect(rig.settings.lastAttemptAt == nil)
        #expect(rig.settings.lastFailureMessage == nil)
        #expect(try await rig.snapshots().isEmpty)
        #expect(rig.lifecycle.outstanding == 0)
    }

    @Test func aResetLaunchRunsNothingUntilAutomaticBackupsAreSwitchedOn() async throws {
        let rig = try await SchedulerRig(enabled: false, armed: false)
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .disarmed)
        rig.settings.destinationID = rig.destination.id
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted.isEmpty)
        #expect(!rig.taskScheduler.calls.contains("cancel:\(id)"))

        rig.settings.isEnabled = true
        #expect(await Support.waitUntil { rig.scheduler.isArmed })
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .succeeded)
    }

    // MARK: Background task

    @Test func registersTheHandlerOnce() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        #expect(rig.scheduler.registerBackgroundTask())
        #expect(rig.scheduler.registerBackgroundTask())
        #expect(rig.taskScheduler.calls == ["register:\(id)"])
    }

    @Test func nothingIsSubmittedWithoutARegisteredHandler() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.taskScheduler.registerResult = false
        #expect(!rig.scheduler.registerBackgroundTask())
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.calls == ["register:\(id)"])
    }

    @Test func backgroundingSchedulesTheTaskForWhenTheRunIsDue() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        // Never backed up: due now, so no start delay; a folder needs no network.
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted == [BackupBackgroundTaskRequest(identifier: id, earliestBeginDate: nil,
                                                                             requiresNetworkConnectivity: false,
                                                                             requiresExternalPower: false)])

        // A run while in the background: afterwards nothing is pending, so the request is
        // cancelled rather than submitted again.
        #expect(await rig.scheduler.runIfDue(.backgroundTask) == .succeeded)
        #expect(rig.taskScheduler.submitted.count == 1)
        #expect(rig.taskScheduler.calls.last == "cancel:\(id)")

        // After a change: 24 hours after the success.
        let success = try #require(rig.service.lastSuccessfulBackup(destinationID: rig.destination.id))
        rig.clock.now = success.addingTimeInterval(60)
        rig.store.hub.post(.bookSaved(bookID: UUID()), origin: nil)
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted.count == 2)
        #expect(rig.taskScheduler.submitted.last?.earliestBeginDate == success.addingTimeInterval(BackupDueRule.interval))
        #expect(rig.taskScheduler.submitted.last?.requiresNetworkConnectivity == false)
    }

    @Test func networkDestinationsRequireTheNetwork() async throws {
        let rig = try await SchedulerRig(destinationID: GoogleDriveBackupDestination.destinationID)
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted.last?.requiresNetworkConnectivity == true)
    }

    @Test func turningAutomaticBackupsOffCancelsTheBackgroundTask() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted.count == 1)
        rig.settings.isEnabled = false
        #expect(await Support.waitUntil { rig.taskScheduler.cancelled == [id] })
        // Backgrounding again submits nothing.
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.taskScheduler.submitted.count == 1)
    }

    @Test func theBackgroundTaskBacksUpAndCompletesOnce() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        let task = FakeBackgroundTask()
        rig.taskScheduler.launch(id, with: task)
        #expect(task.expirationHandler != nil)
        #expect(await Support.waitUntil { !task.completions.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(task.completions == [true])
        #expect(try await rig.snapshots().count == 1)
        // A background-task run needs no extra assertion; nothing pending afterwards.
        #expect(rig.lifecycle.begun.isEmpty)
        #expect(rig.taskScheduler.calls.last == "cancel:\(id)")
        // Expiring after completion does nothing.
        task.expire()
        #expect(task.completions == [true])
    }

    @Test func aFailedBackgroundRunCompletesOnceAndReschedulesAfterTheBackOff() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        rig.destination.failUploads = true
        let attempt = rig.clock.now
        let task = FakeBackgroundTask()
        rig.taskScheduler.launch(id, with: task)
        #expect(await Support.waitUntil { !task.completions.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(task.completions == [false])
        #expect(rig.settings.lastFailureMessage == "The test destination refused the upload.")
        #expect(rig.taskScheduler.submitted.last?.earliestBeginDate == attempt.addingTimeInterval(BackupDueRule.failureBackoff))
    }

    @Test func expirationCancelsTheJobReschedulesAndCompletesOnce() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        rig.holdRuns = true
        let task = FakeBackgroundTask()
        rig.taskScheduler.launch(id, with: task)
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        let submissions = rig.taskScheduler.submitted.count

        task.expire()
        #expect(task.completions == [false])
        #expect(rig.service.job?.isCancelled == true)
        #expect(rig.taskScheduler.submitted.count == submissions + 1)
        #expect(rig.taskScheduler.submitted.last?.earliestBeginDate == nil)

        rig.latch.open()
        #expect(await Support.waitUntil { !rig.scheduler.isRunning && rig.service.job == nil })
        try await Task.sleep(for: .milliseconds(200))
        #expect(task.completions == [false])
        #expect(rig.settings.lastAttemptAt == nil)
        #expect(rig.settings.lastFailureMessage == nil)
        #expect(try await rig.snapshots().isEmpty)
    }

    @Test func aBackgroundTaskDuringAForegroundRunWaitsForIt() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        rig.holdRuns = true
        let foreground = Task { await rig.scheduler.runIfDue(.sceneActivated) }
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        let task = FakeBackgroundTask()
        rig.taskScheduler.launch(id, with: task)
        try await Task.sleep(for: .milliseconds(100))
        #expect(task.completions.isEmpty)
        rig.latch.open()
        #expect(await foreground.value == .succeeded)
        #expect(await Support.waitUntil { task.completions == [true] })
        #expect(rig.latch.arrivals == 1)
    }

    @Test func runningOutOfBackgroundTimeCancelsAForegroundRun() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        rig.scheduler.registerBackgroundTask()
        rig.holdRuns = true
        rig.scheduler.scenePhaseChanged(.active)
        #expect(await Support.waitUntil { rig.latch.arrivals == 1 })
        rig.scheduler.scenePhaseChanged(.background)
        #expect(rig.lifecycle.outstanding == 1)
        let submissions = rig.taskScheduler.submitted.count

        rig.lifecycle.expireAll()
        #expect(rig.lifecycle.outstanding == 0)
        #expect(rig.service.job?.isCancelled == true)
        #expect(rig.taskScheduler.submitted.count > submissions)
        rig.latch.open()
        #expect(await Support.waitUntil { !rig.scheduler.isRunning })
        #expect(rig.settings.lastAttemptAt == nil)
        #expect(rig.lifecycle.outstanding == 0)
    }
}
