import Foundation

/// When an automatic backup is due. Pure: every input, including the time, is passed in, so the
/// rule is tested on its own (`BackupSchedulerDueRuleTests`).
///
/// A run is due when all of these hold:
/// - automatic backups are on and a destination is chosen;
/// - that destination is registered in this process and currently available;
/// - the backup service is not busy (a manual backup or a restore is not running);
/// - there is something to back up: the library changed after the destination's last successful
///   backup, or there has never been one and the library is not empty;
/// - the last success was at least `interval` (24 hours) ago, or there was none;
/// - the last automatic attempt did not fail within the last `failureBackoff` (one hour).
///
/// A last success or attempt dated after `now` means the clock was set back; it is ignored (as
/// if there had been none) rather than holding automatic backups back until the clock catches up.
nonisolated enum BackupDueRule {
    /// The least time between two successful automatic backups.
    static let interval: TimeInterval = 24 * 60 * 60
    /// How long after a failed automatic attempt the next one waits. Fixed, not growing: a
    /// failing destination is retried at most once an hour.
    static let failureBackoff: TimeInterval = 60 * 60

    /// The chosen destination as this process sees it.
    enum DestinationState: Equatable, Sendable {
        /// No destination with the chosen ID is registered (for example a test folder from a
        /// launch argument that this launch did not pass).
        case notRegistered
        case unavailable
        case available
    }

    struct Inputs: Equatable, Sendable {
        var isEnabled: Bool
        var destinationID: String?
        var destination: DestinationState
        var serviceIsBusy: Bool
        /// When the library last changed (`BackupAutomaticSettings.lastChangeAt`).
        var lastChangeAt: Date?
        /// The destination's last successful backup, manual or automatic
        /// (`BackupService.lastSuccessfulBackup(destinationID:)`).
        var lastSuccessAt: Date?
        var libraryIsEmpty: Bool
        /// When the last automatic run started (`BackupAutomaticSettings.lastAttemptAt`).
        var lastAttemptAt: Date?
        /// Whether that run failed (`BackupAutomaticSettings.lastFailureMessage != nil`).
        var lastAttemptFailed: Bool
    }

    enum Reason: Equatable, Sendable {
        case disabled
        case noDestination
        case destinationNotRegistered
        case serviceBusy
        /// Nothing changed since the last successful backup.
        case noChanges
        /// Never backed up, and there is nothing to back up yet.
        case emptyLibrary
        /// The last success is less than `interval` ago.
        case tooSoon(until: Date)
        /// The last attempt failed less than `failureBackoff` ago.
        case backingOff(until: Date)
        case destinationUnavailable
    }

    enum Decision: Equatable, Sendable {
        case due
        case notDue(Reason)
    }

    static func decide(_ inputs: Inputs, now: Date) -> Decision {
        guard inputs.isEnabled else { return .notDue(.disabled) }
        guard inputs.destinationID != nil else { return .notDue(.noDestination) }
        guard inputs.destination != .notRegistered else { return .notDue(.destinationNotRegistered) }
        guard !inputs.serviceIsBusy else { return .notDue(.serviceBusy) }
        let inputs = ignoringFutureDates(inputs, now: now)
        if let pending = pendingReason(inputs) { return .notDue(pending) }
        if let until = intervalEnd(inputs), until > now { return .notDue(.tooSoon(until: until)) }
        if let until = backoffEnd(inputs), until > now { return .notDue(.backingOff(until: until)) }
        guard inputs.destination == .available else { return .notDue(.destinationUnavailable) }
        return .due
    }

    /// When a run would become due if the destination is available and the service idle then,
    /// or `nil` when there is nothing to back up (or automatic backups are off, or the
    /// destination is unknown). The date may be in the past: the run is due already. The
    /// background task's earliest begin date.
    static func nextDueDate(_ inputs: Inputs, now: Date) -> Date? {
        let inputs = ignoringFutureDates(inputs, now: now)
        guard inputs.isEnabled, inputs.destinationID != nil, inputs.destination != .notRegistered,
              pendingReason(inputs) == nil else { return nil }
        return [now, intervalEnd(inputs), backoffEnd(inputs)].compactMap { $0 }.max()
    }

    private static func ignoringFutureDates(_ inputs: Inputs, now: Date) -> Inputs {
        var inputs = inputs
        if let success = inputs.lastSuccessAt, success > now { inputs.lastSuccessAt = nil }
        if let attempt = inputs.lastAttemptAt, attempt > now { inputs.lastAttemptAt = nil }
        return inputs
    }

    /// `nil` when there is something to back up, else why not.
    private static func pendingReason(_ inputs: Inputs) -> Reason? {
        guard let lastSuccess = inputs.lastSuccessAt else {
            return inputs.libraryIsEmpty ? .emptyLibrary : nil
        }
        guard let lastChange = inputs.lastChangeAt, lastChange > lastSuccess else { return .noChanges }
        return nil
    }

    /// The end of the 24-hour wait after the last success (`nil`: no wait).
    private static func intervalEnd(_ inputs: Inputs) -> Date? {
        inputs.lastSuccessAt.map { $0.addingTimeInterval(interval) }
    }

    /// The end of the back-off after a failed attempt (`nil`: no back-off).
    private static func backoffEnd(_ inputs: Inputs) -> Date? {
        guard inputs.lastAttemptFailed, let attempt = inputs.lastAttemptAt else { return nil }
        return attempt.addingTimeInterval(failureBackoff)
    }
}
