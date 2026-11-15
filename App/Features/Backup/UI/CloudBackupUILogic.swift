import Foundation
import ReaderBackup

// Tactile Texts Cloud's screens: their plain decisions and strings, with no views and no store
// access, so they are unit-tested directly (`Tests/CloudBackupUILogicTests.swift`), like
// `BackupUILogic`. Dates are shown as the service gave them ("15 December 2026"); nothing here
// counts days itself, except the offer, which describes the policy before there is an account.

// MARK: - Which page

nonisolated enum CloudBackupPage: Equatable, Sendable {
    /// Nothing known yet: a spinner.
    case checking
    /// Not subscribed (or the App Store can't be asked): what the service is, and Subscribe.
    case offer
    /// Subscribed, or subscribed once: the account, its banner, and the backups.
    case status

    static func make(_ status: CloudBackupAccount.Status, hasError: Bool) -> CloudBackupPage {
        switch status {
        case .unknown: hasError ? .status : .checking
        case .notSubscribed, .storeUnavailable: .offer
        case .notInThisBuild, .needsRecoveryKey, .active, .overAllowance, .readOnly, .lapsed, .revoked, .dataDeleted: .status
        }
    }
}

// MARK: - What the reader can do

/// What each account state allows on the status page.
nonisolated struct CloudBackupCapabilities: Equatable, Sendable {
    /// Back Up Now is enabled.
    var canBackUp: Bool
    /// The backups are listed (and so can be restored).
    var listsBackups: Bool
    /// A single backup can be deleted.
    var canDeleteBackups: Bool
    /// Delete My Cloud Backups is offered (the service allows it in any subscription state).
    var canDeleteEverything: Bool

    static func make(_ status: CloudBackupAccount.Status) -> CloudBackupCapabilities {
        switch status {
        case .active:
            CloudBackupCapabilities(canBackUp: true, listsBackups: true, canDeleteBackups: true, canDeleteEverything: true)
        case .overAllowance:
            CloudBackupCapabilities(canBackUp: false, listsBackups: true, canDeleteBackups: true, canDeleteEverything: true)
        case .readOnly:
            CloudBackupCapabilities(canBackUp: false, listsBackups: true, canDeleteBackups: false, canDeleteEverything: true)
        case .lapsed, .revoked:
            CloudBackupCapabilities(canBackUp: false, listsBackups: false, canDeleteBackups: false, canDeleteEverything: true)
        case .needsRecoveryKey, .notInThisBuild, .unknown, .storeUnavailable, .notSubscribed, .dataDeleted:
            // Starting over without the recovery key is offered on the Enter Recovery Key page.
            CloudBackupCapabilities(canBackUp: false, listsBackups: false, canDeleteBackups: false, canDeleteEverything: false)
        }
    }
}

// MARK: - The banner

/// The notice at the top of the status page for every state other than plain active: what
/// happened, what the reader can still do, and by when.
nonisolated struct CloudBackupBanner: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// Something to act on soon (read-only, over the allowance, the key).
        case warning
        /// Backups can't be used now.
        case problem
    }

    enum Action: Equatable, Sendable {
        case tryAgain
        case enterRecoveryKey
        case resubscribe
    }

    var tone: Tone
    var title: String
    var message: String
    var actions: [Action]

    var systemImage: String {
        switch tone {
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    /// The banner for `status`, or `nil` for an active account with nothing to report.
    /// - Parameters:
    ///   - errorMessage: `CloudBackupAccount.lastError`'s message, if any.
    ///   - usage: for the over-allowance figures.
    static func make(_ status: CloudBackupAccount.Status, errorMessage: String?, usage: BackupServiceUsage?,
                     dateText: (Date) -> String = CloudServiceError.day) -> CloudBackupBanner? {
        let name = CloudServiceError.serviceName
        switch status {
        case .active:
            guard let errorMessage else { return nil }
            return CloudBackupBanner(tone: .warning, title: "Couldn’t Check \(name)", message: errorMessage, actions: [.tryAgain])
        case .unknown:
            guard let errorMessage else { return nil }
            return CloudBackupBanner(tone: .problem, title: "Couldn’t Reach \(name)", message: errorMessage, actions: [.tryAgain])
        case .notInThisBuild:
            return CloudBackupBanner(tone: .problem, title: "Not Available",
                                     message: TactileCloudError.notInThisBuild.localizedDescription, actions: [])
        case .storeUnavailable(let reason):
            return CloudBackupBanner(tone: .problem, title: "Couldn’t Reach the App Store", message: reason, actions: [.tryAgain])
        case .notSubscribed:
            return nil
        case .overAllowance:
            let figures = usage.map { "Your backups use \(BackupUIText.bytes($0.bytes)) of your plan’s \(BackupUIText.bytes($0.allowanceBytes)), so new backups can’t be made." }
                ?? "Your backups are over your plan’s storage allowance, so new backups can’t be made."
            return CloudBackupBanner(tone: .warning, title: "Storage Full",
                                     message: figures + " You can still restore, and delete old backups to make room.",
                                     actions: [])
        case .readOnly(let until, let deleteAfter):
            var message = "New backups can’t be made. "
            message += until.map { "You can restore from your backups until \(dateText($0))." }
                ?? "You can still restore from your backups for now."
            message += deleteAfter.map { " They will be deleted after \(dateText($0)) unless you resubscribe." }
                ?? " Resubscribe to back up again and keep them."
            return CloudBackupBanner(tone: .warning, title: "Your Subscription Has Ended", message: message,
                                     actions: [.resubscribe])
        case .lapsed(let deleteAfter):
            let message = deleteAfter.map {
                "Your backups can’t be used now, but they are kept until \(dateText($0)). Resubscribe before then to get them back; after that they will be deleted."
            } ?? "Your backups can’t be used now. Resubscribe to get them back before they are deleted."
            return CloudBackupBanner(tone: .problem, title: "Your Subscription Has Ended", message: message,
                                     actions: [.resubscribe])
        case .revoked(let deleteAfter):
            let message = deleteAfter.map {
                "Your subscription was refunded or revoked, so your backups can’t be used. They will be deleted on \(dateText($0))."
            } ?? "Your subscription was refunded or revoked, so your backups can’t be used."
            return CloudBackupBanner(tone: .problem, title: "Subscription Refunded", message: message, actions: [])
        case .dataDeleted:
            return CloudBackupBanner(tone: .problem, title: "Backups Deleted",
                                     message: "Your subscription ended and the backups kept in \(name) have been deleted. Subscribe again to start new backups.",
                                     actions: [.resubscribe])
        case .needsRecoveryKey(.noKeyOnThisDevice):
            return CloudBackupBanner(tone: .warning, title: "Waiting for Your Key",
                                     message: CloudBackupRecoveryKeyText.arrivingNote, actions: [.tryAgain, .enterRecoveryKey])
        case .needsRecoveryKey(.differentKey):
            return CloudBackupBanner(tone: .warning, title: "Recovery Key Needed",
                                     message: "Your backups were made with a different key from the one on this iPad. Enter your recovery key to use them.",
                                     actions: [.enterRecoveryKey])
        }
    }

    static func title(of action: Action, status: CloudBackupAccount.Status) -> String {
        switch action {
        case .tryAgain: return "Try Again"
        case .enterRecoveryKey: return "Enter Recovery Key…"
        case .resubscribe:
            if case .dataDeleted = status { return "Subscribe…" }
            return "Resubscribe…"
        }
    }
}

// MARK: - The account's details

nonisolated enum CloudBackupStatusText {
    /// The plan's name from the App Store, or the service's name.
    static func planName(_ plan: BackupSubscription.Plan?) -> String {
        guard let name = plan?.product?.displayName, !name.isEmpty else { return CloudServiceError.serviceName }
        return name
    }

    /// "a month", "every 3 months", "a year".
    static func period(_ period: BackupStoreProduct.Period) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        }
        return period.value == 1 ? "a \(unit)" : "every \(period.value.formatted(.number)) \(unit)s"
    }

    /// "£2.99 a month", or the price alone for a product without a period.
    static func price(_ product: BackupStoreProduct) -> String {
        product.period.map { "\(product.displayPrice) \(period($0))" } ?? product.displayPrice
    }

    /// "Renews on 15 December 2026", "Ends on …", "Ended on …"; `nil` when there is no date.
    static func renewalLine(_ state: BackupSubscription.State?, dateText: (Date) -> String = CloudServiceError.day) -> String? {
        switch state {
        case .subscribed(_, let date?, let willRenew):
            return willRenew ? "Renews on \(dateText(date))" : "Ends on \(dateText(date))"
        case .ended(_, let date?):
            return "Ended on \(dateText(date))"
        default:
            return nil
        }
    }

    /// "1.2 MB of 10 GB used".
    static func usageLine(_ usage: BackupServiceUsage) -> String {
        "\(BackupUIText.bytes(usage.bytes)) of \(BackupUIText.bytes(usage.allowanceBytes)) used"
    }

    /// The share of the allowance used, 0…1.
    static func usageFraction(_ usage: BackupServiceUsage) -> Double {
        guard usage.allowanceBytes > 0 else { return usage.bytes > 0 ? 1 : 0 }
        return min(1, max(0, Double(usage.bytes) / Double(usage.allowanceBytes)))
    }

    static let backUpFooter = "Backups are encrypted on this iPad before they are sent. Each PDF is sent once; later backups send only notes and ink. The newest \(SnapshotRetention.defaultKeepCount) backups are kept."

    /// Under Back Up Now when it is off: why.
    static func backUpRefusedFooter(_ status: CloudBackupAccount.Status) -> String? {
        switch status {
        case .overAllowance: "Backing up is paused while your backups are over your plan’s storage allowance."
        case .readOnly: "Backing up is paused because your subscription has ended. Resubscribe to back up again."
        default: nil
        }
    }

    static let deleteFooter = "Removes every backup and PDF kept in \(CloudServiceError.serviceName), for good. Your subscription isn’t cancelled; use Manage Subscription for that."
}

// MARK: - Subscribing

nonisolated enum CloudBackupOfferText {
    /// The policy the service applies when a subscription ends (`READ_ONLY_DAYS` and
    /// `DELETE_AFTER_DAYS` in the Worker's settings; see DESIGN.md). Only the offer states them,
    /// before there is an account with real dates; every other page shows the service's dates.
    static let readOnlyDays = 30
    static let deleteAfterDays = 60

    static let intro = "Back up your notes, highlights, bookmarks, ink and PDFs to \(CloudServiceError.serviceName), and restore them on this iPad or a new one. Backups can run automatically once a day."

    static let encryptedTitle = "Encrypted on This iPad"
    static let encrypted = "Your backups are encrypted on this iPad before they leave it, and nobody else can read them: not Tactile Texts, and not the company that stores them. Only their sizes and dates can be seen."

    static let recoveryKeyTitle = "Your Recovery Key"
    static let recoveryKey = "Your first backup makes a recovery key. Your other devices get the key through iCloud Keychain; if it is ever lost, the recovery key is the only way to open your backups. Nobody can recover them without it, so keep it somewhere safe."

    static let endingTitle = "If Your Subscription Ends"
    static var ending: String {
        "You can still restore from your backups for \(readOnlyDays) days, but not make new ones. \(deleteAfterDays) days after the end your backups are deleted; resubscribe before then to keep them. A refunded subscription can’t be restored from."
    }

    static let renewalTerms = "Payment is charged to your Apple Account. The subscription renews automatically unless you cancel it at least 24 hours before the end of the current period. Manage or cancel it in your Apple Account settings."

    static let noProducts = "The subscription can’t be bought right now."

    /// "Subscribe for £2.99 a month".
    static func subscribeTitle(_ product: BackupStoreProduct, isOnlyOne: Bool) -> String {
        isOnlyOne ? "Subscribe for \(CloudBackupStatusText.price(product))"
            : "\(product.displayName): \(CloudBackupStatusText.price(product))"
    }

    /// What to tell the reader after `purchase` returned `outcome`; `nil` when nothing needs saying
    /// (purchased: the page changes; cancelled: they know).
    static func message(after outcome: BackupSubscription.PurchaseOutcome) -> String? {
        switch outcome {
        case .purchased, .cancelled: nil
        case .pending: "Your purchase is waiting for approval, for example by a parent through Ask to Buy. \(CloudServiceError.serviceName) starts as soon as it is approved."
        }
    }

    /// What to tell the reader after Restore Purchases, from the state it left.
    @MainActor static func messageAfterRestore(_ state: BackupSubscription.State) -> String? {
        switch state {
        case .notSubscribed: "No \(CloudServiceError.serviceName) subscription was found for this Apple Account."
        case .unavailable(let reason): reason.message
        case .loading, .subscribed, .ended: nil
        }
    }
}

/// The Terms of Use and Privacy Policy links, from the `BackupService` dictionary in
/// `Info.plist` (`BACKUP_TERMS_URL`, `BACKUP_PRIVACY_URL`; empty by default). A link whose
/// setting is empty is not shown.
nonisolated struct CloudBackupLinks: Equatable, Sendable {
    static let termsKey = "TermsURL"
    static let privacyKey = "PrivacyURL"

    var terms: URL?
    var privacy: URL?

    static func fromInfoDictionary(_ infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> CloudBackupLinks {
        let values = infoDictionary?[BackupServiceConfiguration.infoKey] as? [String: Any]
        return CloudBackupLinks(terms: url((values?[termsKey] as? String) ?? ""),
                                privacy: url((values?[privacyKey] as? String) ?? ""))
    }

    /// An `https` URL from a setting: written with or without `https://` (an xcconfig file
    /// can't hold `//`, so a value there has no scheme), or `nil` when empty, unexpanded, not
    /// `https`, or without a host.
    static func url(_ raw: String) -> URL? {
        guard let setting = BackupServiceConfiguration.setting(raw), !setting.contains(" ") else { return nil }
        let text = setting.contains("://") ? setting : "https://\(setting)"
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }
}

// MARK: - The recovery key

nonisolated enum CloudBackupRecoveryKeyText {
    /// A recovery key's groups ("0C51", "260Z", …) from its formatted text.
    static func groups(_ formatted: String) -> [String] {
        formatted.split(separator: "-").map(String.init)
    }

    /// The groups laid out `perLine` to a line, groups separated by two spaces.
    static func lines(_ groups: [String], perLine: Int) -> String {
        let size = max(1, perLine)
        return stride(from: 0, to: groups.count, by: size)
            .map { groups[$0..<min($0 + size, groups.count)].joined(separator: "  ") }
            .joined(separator: "\n")
    }

    /// What VoiceOver reads: each group, character by character, numbered.
    static func spoken(_ groups: [String]) -> String {
        groups.enumerated().map { index, group in
            "Group \(index + 1): " + group.map(String.init).joined(separator: " ")
        }.joined(separator: ". ")
    }

    /// The characters typed so far, not counting spaces, line breaks and dashes.
    static func typedCount(_ text: String) -> Int {
        text.unicodeScalars.filter { !$0.properties.isWhitespace && !"-‐‑‒–—−".unicodeScalars.contains($0) }.count
    }

    /// The characters that matter, upper-cased: what two entries are compared by.
    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.uppercased().unicodeScalars.filter {
            !$0.properties.isWhitespace && !"-‐‑‒–—−".unicodeScalars.contains($0)
        }))
    }

    /// "12 of 56 characters".
    static func progress(_ text: String) -> String {
        "\(typedCount(text).formatted(.number)) of \(BackupRecoveryKey.characterCount) characters"
    }

    /// The message for a recovery key that was refused, as `BackupError` and
    /// `TactileCloudError` word it; a wrong length says how many characters there were instead.
    static func entryError(_ error: any Error, typed text: String) -> String {
        if case .recoveryKeyWrongLength = error as? BackupError {
            return "That recovery key has \(typedCount(text).formatted(.number)) characters; a recovery key has \(BackupRecoveryKey.characterCount). Check it and try again."
        }
        return error.localizedDescription
    }

    /// The text saved or shared with the key.
    static func document(_ formatted: String) -> String {
        """
        Tactile Texts Cloud recovery key

        \(formatted)

        This key opens your Tactile Texts Cloud backups. Keep it somewhere safe and private. \
        Nobody, including Tactile Texts, can open your backups without it if the key on your devices is lost.
        """
    }

    static let explanation = "This key opens your backups if your devices lose the key they keep in iCloud Keychain. Nobody, including Tactile Texts, can open your backups without it. Keep it somewhere safe and private, away from this iPad: printed, or in a password manager."

    static let promptIntro = "Your first backup to \(CloudServiceError.serviceName) is done. Save your recovery key now: without it, nobody can open your backups if the key on your devices is lost."

    static let reminder = "You haven’t saved your recovery key yet. Without it, nobody can open your backups if the key on your devices is lost."

    static let arrivingNote = "Your backups are encrypted with a key from your other devices. It arrives through iCloud Keychain, which can take a few minutes after you sign in. Try again in a while; if it doesn’t arrive, enter your recovery key."

    static let enterIntro = "Enter the recovery key you saved when you first backed up. Upper or lower case, spaces and dashes don’t matter."

    static let startOverTitle = "Start Over Without Your Backups?"
    static let startOverMessage = "Every backup and PDF kept in \(CloudServiceError.serviceName) will be deleted for good, and nobody can recover them. Your next backup makes a new key. Do this only if you’ve lost your recovery key and no other device of yours has the key. Your subscription isn’t cancelled."

    static let deleteTitle = "Delete Your Cloud Backups?"
    static let deleteMessage = "Everything kept in \(CloudServiceError.serviceName) is removed for good: every backup and every PDF stored with them. This can’t be undone. Your subscription isn’t cancelled; to stop paying, use Manage Subscription."
}

// MARK: - Prompting for the recovery key

nonisolated enum CloudBackupRecoveryKeyLogic {
    /// Whether to ask the reader to save the recovery key now: this iPad holds a key whose
    /// recovery key hasn't been shown (the first backup just made it), the backup that made it
    /// has finished, and the account can be used.
    static func shouldPrompt(hasKey: Bool?, shown: Bool, isBusy: Bool, status: CloudBackupAccount.Status) -> Bool {
        hasKey == true && !shown && !isBusy && hasAccess(status)
    }

    /// Whether the status page keeps its quiet reminder: a key is here and the reader hasn't
    /// said they saved its recovery key.
    static func showsReminder(hasKey: Bool?, saved: Bool, status: CloudBackupAccount.Status) -> Bool {
        hasKey == true && !saved && hasAccess(status)
    }

    /// Whether "Show Recovery Key…" is offered.
    static func showsKey(hasKey: Bool?, status: CloudBackupAccount.Status) -> Bool {
        hasKey == true && hasAccess(status)
    }

    private static func hasAccess(_ status: CloudBackupAccount.Status) -> Bool {
        switch status {
        case .active, .overAllowance, .readOnly: true
        default: false
        }
    }
}

// MARK: - The Backup screen's footnote

extension BackupUIText {
    /// The footnote under the Backup screen: cloud backups are encrypted, other backups aren't.
    nonisolated static func footnote(hasEncryptedDestination: Bool) -> String {
        guard hasEncryptedDestination else { return footnote }
        return "Backups to \(CloudServiceError.serviceName) are encrypted on this iPad. Other backups aren’t encrypted: anyone who can open one can read the notes in it. A backup without PDFs is much smaller; after restoring it, link each book to its PDF with Locate PDF…."
    }
}
