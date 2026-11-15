import Foundation
import Testing
@testable import Marginal

/// `BackupDueRule` on its own, with a fixed clock: every condition and boundary.
struct BackupSchedulerDueRuleTests {
    typealias Rule = BackupDueRule

    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let hour: TimeInterval = 3600

    /// Due: on, available, changed an hour ago, last success 25 hours ago, last attempt (a
    /// success) then too.
    var due: Rule.Inputs {
        Rule.Inputs(isEnabled: true, destinationID: "folder", destination: .available, serviceIsBusy: false,
                    lastChangeAt: now.addingTimeInterval(-hour), lastSuccessAt: now.addingTimeInterval(-25 * hour),
                    libraryIsEmpty: false, lastAttemptAt: now.addingTimeInterval(-25 * hour), lastAttemptFailed: false)
    }

    func decide(_ change: (inout Rule.Inputs) -> Void) -> Rule.Decision {
        var inputs = due
        change(&inputs)
        return Rule.decide(inputs, now: now)
    }

    @Test func dueWhenEveryConditionHolds() {
        #expect(Rule.decide(due, now: now) == .due)
    }

    @Test func notDueWhenOffOrNoDestinationOrBusy() {
        #expect(decide { $0.isEnabled = false } == .notDue(.disabled))
        #expect(decide { $0.destinationID = nil } == .notDue(.noDestination))
        #expect(decide { $0.serviceIsBusy = true } == .notDue(.serviceBusy))
    }

    @Test func notDueForAnUnknownOrUnavailableDestination() {
        #expect(decide { $0.destination = .notRegistered } == .notDue(.destinationNotRegistered))
        #expect(decide { $0.destination = .unavailable } == .notDue(.destinationUnavailable))
    }

    @Test func dueExactly24HoursAfterTheLastSuccessAndNotASecondEarlier() {
        let exactly = now.addingTimeInterval(-24 * hour)
        #expect(decide { $0.lastSuccessAt = exactly } == .due)
        let almost = exactly.addingTimeInterval(1)
        #expect(decide { $0.lastSuccessAt = almost } == .notDue(.tooSoon(until: now.addingTimeInterval(1))))
    }

    @Test func neverBackedUpIsDueUnlessTheLibraryIsEmpty() {
        #expect(decide { $0.lastSuccessAt = nil; $0.lastChangeAt = nil } == .due)
        #expect(decide { $0.lastSuccessAt = nil; $0.libraryIsEmpty = true } == .notDue(.emptyLibrary))
    }

    @Test func notDueWithoutAChangeSinceTheLastSuccess() {
        let success = now.addingTimeInterval(-30 * hour)
        #expect(decide { $0.lastSuccessAt = success; $0.lastChangeAt = success } == .notDue(.noChanges))
        #expect(decide { $0.lastSuccessAt = success; $0.lastChangeAt = success.addingTimeInterval(-1) } == .notDue(.noChanges))
        #expect(decide { $0.lastChangeAt = nil } == .notDue(.noChanges))
        // An empty library only matters before the first backup (deleting every book is a change).
        #expect(decide { $0.libraryIsEmpty = true } == .due)
    }

    @Test func backsOffForAnHourAfterAFailure() {
        let attempt = now.addingTimeInterval(-59 * 60)
        #expect(decide { $0.lastAttemptAt = attempt; $0.lastAttemptFailed = true }
                == .notDue(.backingOff(until: attempt.addingTimeInterval(hour))))
        // Expired exactly an hour after the attempt.
        #expect(decide { $0.lastAttemptAt = now.addingTimeInterval(-hour); $0.lastAttemptFailed = true } == .due)
        // Never backed up: the back-off still applies.
        #expect(decide { $0.lastSuccessAt = nil; $0.lastAttemptAt = attempt; $0.lastAttemptFailed = true }
                == .notDue(.backingOff(until: attempt.addingTimeInterval(hour))))
        // A recent attempt that succeeded does not back off.
        #expect(decide { $0.lastAttemptAt = now.addingTimeInterval(-60); $0.lastAttemptFailed = false } == .due)
    }

    @Test func datesInTheFutureAreIgnored() {
        #expect(decide { $0.lastSuccessAt = now.addingTimeInterval(hour) } == .due)
        #expect(decide { $0.lastAttemptAt = now.addingTimeInterval(hour); $0.lastAttemptFailed = true } == .due)
    }

    @Test func nextDueDate() {
        func next(_ change: (inout Rule.Inputs) -> Void) -> Date? {
            var inputs = due
            change(&inputs)
            return Rule.nextDueDate(inputs, now: now)
        }
        #expect(next { _ in } == now)
        #expect(next { $0.lastSuccessAt = nil } == now)
        let success = now.addingTimeInterval(-10 * hour)
        #expect(next { $0.lastSuccessAt = success } == success.addingTimeInterval(24 * hour))
        let attempt = now.addingTimeInterval(-10 * 60)
        #expect(next { $0.lastSuccessAt = nil; $0.lastAttemptAt = attempt; $0.lastAttemptFailed = true }
                == attempt.addingTimeInterval(hour))
        // The later of the two waits.
        #expect(next { $0.lastSuccessAt = success; $0.lastAttemptAt = attempt; $0.lastAttemptFailed = true }
                == success.addingTimeInterval(24 * hour))
        // Availability and a busy service are checked when the task runs, not when it is scheduled.
        #expect(next { $0.destination = .unavailable; $0.serviceIsBusy = true } == now)
        #expect(next { $0.lastChangeAt = nil } == nil)
        #expect(next { $0.lastSuccessAt = nil; $0.libraryIsEmpty = true } == nil)
        #expect(next { $0.isEnabled = false } == nil)
        #expect(next { $0.destinationID = nil } == nil)
        #expect(next { $0.destination = .notRegistered } == nil)
    }

    @Test func onlyNetworkDestinationsRequireTheNetwork() {
        #expect(!BackupScheduler.requiresNetwork(destinationID: PickedFolderBackupDestination.destinationID))
        #expect(!BackupScheduler.requiresNetwork(destinationID: ICloudBackupDestination.destinationID))
        #expect(!BackupScheduler.requiresNetwork(destinationID: "folder:/tmp/Backups"))
        #expect(BackupScheduler.requiresNetwork(destinationID: GoogleDriveBackupDestination.destinationID))
        #expect(BackupScheduler.requiresNetwork(destinationID: S3BackupDestination.destinationID))
        #expect(BackupScheduler.requiresNetwork(destinationID: "something-new"))
    }
}
