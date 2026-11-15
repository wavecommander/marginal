import Foundation
import Observation

/// Automatic-backup preferences and the outcome of the last automatic run, kept in
/// `UserDefaults`. The Backup screen edits the preferences; the scheduler reads them, decides
/// when a run is due, and records how each run went. One instance per app (`AppEnvironment`).
///
/// Automatic backups are off until the reader turns them on and picks a destination.
@Observable
@MainActor
final class BackupAutomaticSettings {
    nonisolated enum Key {
        static let isEnabled = "backup.automatic.enabled"
        static let destinationID = "backup.automatic.destinationID"
        static let includesPDFs = "backup.automatic.includesPDFs"
        static let lastChangeAt = "backup.automatic.lastChangeAt"
        static let lastAttemptAt = "backup.automatic.lastAttemptAt"
        static let lastFailureMessage = "backup.automatic.lastFailureMessage"
        static let all = [isEnabled, destinationID, includesPDFs, lastChangeAt, lastAttemptAt, lastFailureMessage]
    }

    /// Whether automatic backups run at all.
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    /// `BackupDestination.id` of the destination automatic backups go to; `nil` until chosen.
    var destinationID: String? { didSet { defaults.set(destinationID, forKey: Key.destinationID) } }
    /// Whether automatic backups also send PDFs the destination does not have yet.
    var includesPDFs: Bool { didSet { defaults.set(includesPDFs, forKey: Key.includesPDFs) } }

    /// When the library last changed (any record or ink write). A run is due only when this is
    /// later than the destination's last successful backup.
    private(set) var lastChangeAt: Date?
    /// When the last automatic run started, successful or not.
    private(set) var lastAttemptAt: Date?
    /// The reader-facing message of the last automatic run's failure; `nil` after a success.
    private(set) var lastFailureMessage: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        destinationID = defaults.string(forKey: Key.destinationID)
        includesPDFs = defaults.object(forKey: Key.includesPDFs) as? Bool ?? true
        lastChangeAt = defaults.object(forKey: Key.lastChangeAt) as? Date
        lastAttemptAt = defaults.object(forKey: Key.lastAttemptAt) as? Date
        lastFailureMessage = defaults.string(forKey: Key.lastFailureMessage)
    }

    /// The scheduler notes that the library changed.
    func recordChange(at date: Date = Date()) {
        lastChangeAt = date
        defaults.set(date, forKey: Key.lastChangeAt)
    }

    /// The scheduler records an automatic run: `failureMessage` is `nil` for a success.
    func recordAttempt(at date: Date = Date(), failureMessage: String?) {
        lastAttemptAt = date
        lastFailureMessage = failureMessage
        defaults.set(date, forKey: Key.lastAttemptAt)
        if let failureMessage {
            defaults.set(failureMessage, forKey: Key.lastFailureMessage)
        } else {
            defaults.removeObject(forKey: Key.lastFailureMessage)
        }
    }

    /// Removes every stored value (`-resetState`).
    nonisolated static func reset(in defaults: UserDefaults) {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }
}
