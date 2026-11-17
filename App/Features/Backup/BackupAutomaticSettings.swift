import Foundation
import Observation

/// Backup preferences and the outcome of the last automatic run, kept in `UserDefaults`: the
/// automatic-backup settings, and the Include PDFs choice that every backup shares. The Backup
/// screens edit the preferences; the scheduler reads them, decides when a run is due, and
/// records how each run went. One instance per app (`AppEnvironment`), observed by every window,
/// so a change made in one screen shows in the others at once.
///
/// Automatic backups are off until the reader turns them on and picks a destination.
@Observable
@MainActor
final class BackupAutomaticSettings {
    nonisolated enum Key {
        static let isEnabled = "backup.automatic.enabled"
        static let destinationID = "backup.automatic.destinationID"
        /// One key for every backup's Include PDFs choice (not only automatic ones).
        static let includesPDFs = "backup.includesPDFs"
        static let lastChangeAt = "backup.automatic.lastChangeAt"
        static let lastAttemptAt = "backup.automatic.lastAttemptAt"
        static let lastFailureMessage = "backup.automatic.lastFailureMessage"
        static let all = [isEnabled, destinationID, includesPDFs, lastChangeAt, lastAttemptAt, lastFailureMessage]
    }

    /// Whether automatic backups run at all.
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    /// `BackupDestination.id` of the destination automatic backups go to; `nil` until chosen.
    var destinationID: String? { didSet { defaults.set(destinationID, forKey: Key.destinationID) } }
    /// Whether backups include the PDFs. **One choice for every backup** (owner decision,
    /// 15 November 2026): the backup-file switch, each destination's switch and the automatic
    /// backup's switch all show and change this one value, so a reader who has decided once is
    /// never caught out by another switch still set the other way. On by default.
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

    /// Automatic backup to `destinationID` becomes on, **only when the reader never set automatic
    /// backups up**: never switched them on or off, and no destination chosen (owner decision,
    /// 17 November 2026: on by default for a signed-in Tactile Texts Cloud subscriber). A
    /// reader who turned it off, or who backs up automatically elsewhere, is left as they are.
    /// Returns whether it changed anything.
    @discardableResult
    func applyDefault(destinationID id: String) -> Bool {
        guard defaults.object(forKey: Key.isEnabled) == nil, destinationID == nil else { return false }
        destinationID = id
        isEnabled = true
        return true
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
