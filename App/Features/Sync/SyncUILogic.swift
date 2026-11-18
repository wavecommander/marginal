import Foundation
import ReaderBackup
import ReaderSync

// Sync's plain decisions and words, with no views, store or clock of their own, so they are
// unit-tested directly (`Tests/SyncUILogicTests.swift`): the status line, the join sheet's
// decision, the PDF download policy and each book's state in the Library.
//
// Reader-facing text says "this device" (the account's devices may be iPads and iPhones).

// MARK: - The status line

/// The line under the Sync switch on the Tactile Texts Cloud page, for every `SyncStatus`.
nonisolated struct SyncStatusLine: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// Up to date, syncing, or off.
        case normal
        /// Waiting for something that clears on its own or with the reader's help.
        case waiting
        /// The last round failed.
        case problem
    }

    /// A button under the line.
    enum Action: Equatable, Sendable {
        case tryAgain
        case enterRecoveryKey
        /// The join was not confirmed: show the join sheet again.
        case reviewJoin
    }

    var text: String
    var tone: Tone
    var action: Action?
    /// A round is running (the line shows a spinner).
    var isBusy = false

    var systemImage: String {
        switch tone {
        case .normal: isBusy ? "arrow.triangle.2.circlepath" : "checkmark.icloud"
        case .waiting: "clock.arrow.circlepath"
        case .problem: "exclamationmark.icloud"
        }
    }
}

/// Why a pull-only session cannot send (`SyncWaitReason.pullOnly`), from the account's state.
nonisolated enum SyncPullOnlyCause: Equatable, Sendable {
    /// The subscription has ended (read-only).
    case subscriptionEnded
    /// Over the plan's storage allowance.
    case storageFull
    case unknown

    static func from(_ status: CloudBackupAccount.Status?) -> SyncPullOnlyCause {
        switch status {
        case .readOnly: .subscriptionEnded
        case .overAllowance: .storageFull
        default: .unknown
        }
    }
}

nonisolated enum SyncStatusText {
    /// "today at 10:02", or "14 Nov 2026 at 10:02".
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: "today at \(time)", comment: "Sync status: when sync last finished, today. The argument is a time.")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The line for `status`.
    /// - Parameters:
    ///   - isOn: the Sync switch.
    ///   - lastSyncedAt: `SyncService.lastSyncedAt`.
    ///   - pullOnlyCause: why a pull-only session can't send, from the account's state.
    static func line(status: SyncStatus, isOn: Bool, lastSyncedAt: Date?, pullOnlyCause: SyncPullOnlyCause = .unknown,
                     now: Date = Date(), calendar: Calendar = .current) -> SyncStatusLine {
        guard isOn else {
            return SyncStatusLine(text: String(localized: "Sync is off. Turn it on to keep your books, notes, highlights and ink the same on every device signed in to this account.",
                                               comment: "Tactile Texts Cloud ▸ Sync: status line while the switch is off."),
                                  tone: .normal)
        }
        let last = lastSyncedAt.map { when($0, now: now, calendar: calendar) }
        switch status {
        case .idle:
            if let last {
                return SyncStatusLine(text: String(localized: "Last synced \(last).", comment: "Sync status line between rounds. The argument is a date and time, such as 'today at 10:02'."),
                                      tone: .normal)
            }
            return SyncStatusLine(text: String(localized: "Waiting to sync…", comment: "Sync status line before the first round has run."),
                                  tone: .normal, isBusy: true)
        case .syncing:
            return SyncStatusLine(text: String(localized: "Syncing…", comment: "Sync status line while a round runs."), tone: .normal, isBusy: true)
        case .upToDate(let date):
            let at = when(date, now: now, calendar: calendar)
            return SyncStatusLine(text: String(localized: "Up to date. Last synced \(at).", comment: "Sync status line after a round that agreed with the account. The argument is a date and time, such as 'today at 10:02'."),
                                  tone: .normal)
        case .waiting(let reason):
            return waiting(reason, last: last, pullOnlyCause: pullOnlyCause)
        case .needsJoinConfirmation:
            return SyncStatusLine(text: String(localized: "Sync is waiting for you to confirm how the books on this device join your synced library.",
                                               comment: "Sync status line: the join sheet was not answered."),
                                  tone: .waiting, action: .reviewJoin)
        case .needsKey(.noKeyOnThisDevice):
            return SyncStatusLine(text: String(localized: "Waiting for your key. It arrives from your other devices through iCloud Keychain, which can take a few minutes; if it doesn’t, enter your recovery key.",
                                               comment: "Sync status line: this device has no key for the account's data."),
                                  tone: .waiting, action: .enterRecoveryKey)
        case .needsKey(.differentKey):
            return SyncStatusLine(text: String(localized: "Your synced library was encrypted with a different key from the one on this device. Enter your recovery key to sync.",
                                               comment: "Sync status line: this device's key is not the account's."),
                                  tone: .waiting, action: .enterRecoveryKey)
        case .failed(let message):
            return SyncStatusLine(text: String(localized: "Couldn’t sync. \(message)", comment: "Sync status line after a failed round. The argument is the reason, a sentence."),
                                  tone: .problem, action: .tryAgain)
        }
    }

    private static func waiting(_ reason: SyncWaitReason, last: String?, pullOnlyCause: SyncPullOnlyCause) -> SyncStatusLine {
        let text: String
        switch reason {
        case .signedOut:
            text = String(localized: "Sign in to Tactile Texts Cloud to sync.", comment: "Sync status line while signed out.")
        case .backupOrRestore:
            text = String(localized: "Paused while a backup or restore runs. Sync carries on when it finishes.",
                          comment: "Sync status line while a backup or restore runs.")
        case .offline:
            if let last {
                text = String(localized: "Waiting for the network. Changes on this device are kept and sync when it’s back. Last synced \(last).",
                              comment: "Sync status line while offline. The argument is a date and time, such as 'today at 10:02'.")
            } else {
                text = String(localized: "Waiting for the network. Changes on this device are kept and sync when it’s back.",
                              comment: "Sync status line while offline, never synced yet.")
            }
        case .pullOnly:
            switch pullOnlyCause {
            case .subscriptionEnded:
                text = String(localized: "Your subscription has ended, so changes from your other devices still arrive, but changes on this device wait here. Resubscribe to send them.",
                              comment: "Sync status line: read-only session (subscription ended).")
            case .storageFull:
                text = String(localized: "Your storage is full, so changes from your other devices still arrive, but changes on this device wait here until there’s room.",
                              comment: "Sync status line: over the storage allowance.")
            case .unknown:
                text = String(localized: "Changes from your other devices arrive, but changes on this device wait here for now.",
                              comment: "Sync status line: pull-only session for another reason.")
            }
        case .editInProgress:
            text = String(localized: "Up to date except what you’re working on now, which syncs shortly after you finish.",
                          comment: "Sync status line: a page or note being edited was left for the next round.")
        case .needsNewerApp:
            text = String(localized: "Some books were synced by a newer version of Tactile Texts. Update the app on this device to send its changes to them; changes from your other devices still arrive.",
                          comment: "Sync status line: books written by a newer app are pulled but not pushed.")
        case .accountNeedsNewerApp:
            text = String(localized: "Your synced library was updated by a newer version of Tactile Texts. Update the app on this device to keep syncing; nothing here has changed.",
                          comment: "Sync status line: the account's format is newer than this app reads.")
        }
        return SyncStatusLine(text: text, tone: .waiting)
    }
}

// MARK: - The join

nonisolated enum SyncJoinLogic {
    /// Whether the join needs the reader's confirmation: this device has books and so does the
    /// account. A device with no books, or an empty account, joins without a sheet (nothing on
    /// either side can be surprised).
    static func needsSheet(_ preview: SyncJoinPreview) -> Bool {
        let here = preview.onlyHere + preview.inBoth
        let inAccount = preview.onlyInAccount + preview.inBoth
        return here > 0 && inAccount > 0
    }

    static let title = String(localized: "Join Your Synced Library?", comment: "Join sheet title, shown before this device first syncs with an account that already has books.")
    static let onlyHereLabel = String(localized: "Only on this device", comment: "Join sheet: label of the count of books only on this device.")
    static let onlyInAccountLabel = String(localized: "Only in your account", comment: "Join sheet: label of the count of books only in the account.")
    static let inBothLabel = String(localized: "On both", comment: "Join sheet: label of the count of books on this device and in the account.")
    static let explanation = String(localized: "Books on both are merged: the notes, highlights, bookmarks and ink from each side are kept. Books only on one side are added to the other. Nothing is removed from this device or from your account.",
                                    comment: "Join sheet: what joining does.")
    static let pdfNote = String(localized: "Books added from your account arrive with their notes and ink; their PDFs download as your Download PDFs setting says.",
                                comment: "Join sheet: a note on PDFs.")
    static let joinButton = String(localized: "Join", comment: "Join sheet: confirms the join and starts syncing.")
    static let notNowButton = String(localized: "Not Now", comment: "Join sheet: leaves the Sync switch off.")
}

// MARK: - PDFs

/// The network path as the PDF policy sees it (`NWPath`).
nonisolated struct SyncNetworkPath: Equatable, Sendable {
    var isSatisfied: Bool
    /// Cellular or a personal hotspot.
    var isExpensive: Bool
    /// Low Data Mode.
    var isConstrained: Bool

    static let wifi = SyncNetworkPath(isSatisfied: true, isExpensive: false, isConstrained: false)
    static let cellular = SyncNetworkPath(isSatisfied: true, isExpensive: true, isConstrained: false)
    static let offline = SyncNetworkPath(isSatisfied: false, isExpensive: false, isConstrained: false)
}

nonisolated enum SyncPDFRule {
    /// Whether missing PDFs of synced books may be downloaded without the reader asking: the
    /// policy is automatic and the path is known, up, not expensive and not in Low Data Mode.
    static func allowsAutomatic(_ policy: SyncPDFPolicy, path: SyncNetworkPath?) -> Bool {
        guard policy == .automaticOnWiFi, let path else { return false }
        return path.isSatisfied && !path.isExpensive && !path.isConstrained
    }
}

/// A synced book without its PDF, as its Library cell shows it (in place of "PDF missing").
nonisolated enum SyncPDFBadge: Equatable, Sendable {
    /// The policy is "only when I open a book", or the path does not allow it now.
    case notDownloaded
    /// Queued for an automatic download.
    case waiting
    case downloading
    case failed(String)

    var text: String {
        switch self {
        case .notDownloaded: String(localized: "Not downloaded", comment: "Library: badge on a synced book whose PDF is not on this device yet.")
        case .waiting: String(localized: "Waiting to download", comment: "Library: badge on a synced book whose PDF is queued to download.")
        case .downloading: String(localized: "Downloading…", comment: "Library: badge on a synced book whose PDF is downloading.")
        case .failed: String(localized: "Download failed", comment: "Library: badge on a synced book whose PDF failed to download.")
        }
    }

    var systemImage: String {
        switch self {
        case .notDownloaded, .waiting, .downloading: "icloud.and.arrow.down"
        case .failed: "exclamationmark.icloud"
        }
    }

    /// For UI tests: a stable word per state.
    var identifierValue: String {
        switch self {
        case .notDownloaded: "notDownloaded"
        case .waiting: "waiting"
        case .downloading: "downloading"
        case .failed: "failed"
        }
    }
}

// MARK: - Each book's state

/// A synced book that is not yet up to date after the last round (`SyncReport`). Up-to-date books
/// have none, and nothing is shown on them.
nonisolated enum SyncBookState: Equatable, Sendable {
    /// The reader was working in it; its changes go in a later round.
    case waitingForEdit
    /// The session is pull-only: changes here wait until it can send.
    case waitingToSend
    /// A newer version of the app wrote it: pulled, not pushed.
    case needsNewerApp
    /// Another book here has the same PDF (a state one book per PDF should prevent).
    case duplicate
    /// The round failed for this book (the message is reader-facing).
    case failed(String)

    /// The state of `bookID` after `report`, or `nil` when it is up to date. A failure comes
    /// before any skipped work.
    static func make(_ report: SyncReport?, bookID: UUID) -> SyncBookState? {
        guard let report else { return nil }
        let entries = report.books.filter { $0.bookID == bookID }
        if let failure = entries.lazy.compactMap(\.failure).first { return .failed(failure.description) }
        let skipped = entries.flatMap(\.skipped)
        if skipped.contains(where: { if case .readOnly = $0 { true } else { false } }) { return .needsNewerApp }
        if skipped.contains(.pullOnly) { return .waitingToSend }
        if skipped.contains(where: { if case .busy = $0 { true } else { false } }) { return .waitingForEdit }
        if skipped.contains(where: { if case .duplicatePDF = $0 { true } else { false } }) { return .duplicate }
        return nil
    }

    /// Every book with a state after `report`.
    static func all(_ report: SyncReport?) -> [UUID: SyncBookState] {
        guard let report else { return [:] }
        var states: [UUID: SyncBookState] = [:]
        for id in Set(report.books.compactMap(\.bookID)) {
            if let state = make(report, bookID: id) { states[id] = state }
        }
        return states
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }

    var systemImage: String { isFailure ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath" }

    /// The short label (VoiceOver, the context menu's heading).
    var title: String {
        isFailure ? String(localized: "Not synced", comment: "Library: a synced book that failed to sync this round.")
            : String(localized: "Not yet synced", comment: "Library: a synced book with changes waiting for a later round.")
    }

    /// Why, in a sentence (the book's context menu).
    var reason: String {
        switch self {
        case .waitingForEdit:
            String(localized: "You were working in this book, so its latest changes sync in the next round.", comment: "Library: why a book is not yet synced.")
        case .waitingToSend:
            String(localized: "Changes made to this book on this device wait here until sync can send them.", comment: "Library: why a book is not yet synced (pull-only).")
        case .needsNewerApp:
            String(localized: "A newer version of Tactile Texts synced this book. Update the app to send changes made here.", comment: "Library: why a book is not yet synced (newer app).")
        case .duplicate:
            String(localized: "Another book on this device has the same PDF, so only that one syncs.", comment: "Library: why a book is not synced (duplicate PDF).")
        case .failed(let message):
            String(localized: "Sync couldn’t finish this book: \(message) It tries again in the next round.", comment: "Library: why a book failed to sync. The argument is the reason, a sentence.")
        }
    }
}

// MARK: - Restore and delete

nonisolated enum SyncNoticeText {
    /// Added to the restore confirmations (Replace with Backup, Undo Last Restore) while sync is on.
    static let restoreCarried = String(localized: "Sync is on, so this change is also carried to your other devices.",
                                       comment: "Restore confirmation, added while Sync is on.")
    /// Added to the Delete Book confirmation while sync is on. (Recently Deleted is not built yet,
    /// so nothing promises the book can come back from the account.)
    static let deleteCarried = String(localized: "Sync is on, so it’s also removed from your other devices.",
                                      comment: "Delete Book confirmation, added while Sync is on.")
}

// MARK: - Where the Sync section shows

nonisolated enum SyncAvailability {
    /// Whether the Tactile Texts Cloud page shows the Sync section for the account's state: a
    /// subscriber's account (active, over the allowance, read-only, or waiting for the recovery
    /// key). Signed out, never subscribed, lapsed, refunded or deleted: no section (the switch
    /// keeps its stored value for when the account can sync again).
    static func showsSection(_ status: CloudBackupAccount.Status) -> Bool {
        switch status {
        case .active, .overAllowance, .readOnly, .needsRecoveryKey: true
        case .notInThisBuild, .unknown, .signedOut, .storeUnavailable, .notSubscribed, .subscriptionElsewhere, .lapsed,
             .revoked, .dataDeleted: false
        }
    }
}
