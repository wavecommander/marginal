import Foundation
import ReaderBackup
import Testing
@testable import Marginal

/// Tactile Texts Cloud's screens: their plain decisions (`CloudBackupUILogic.swift`).
struct CloudBackupUILogicTests {
    private let fixedDate: (Date) -> String = { _ in "DATE" }
    private static let day = Date(timeIntervalSince1970: 1_800_000_000)
    private static let product = BackupStoreProduct(id: "p.standard", displayName: "Cloud Backup", displayPrice: "£2.99",
                                                    subscriptionGroupID: "g", period: .init(value: 1, unit: .month))
    private static let usage = BackupServiceUsage(bytes: 10_400_000_000, allowanceBytes: 10_000_000_000, overAllowance: true,
                                                  countedAt: nil)

    // MARK: Which page

    @Test func pageFollowsTheStatus() {
        #expect(CloudBackupPage.make(.unknown, hasError: false) == .checking)
        #expect(CloudBackupPage.make(.unknown, hasError: true) == .status)
        #expect(CloudBackupPage.make(.notSubscribed, hasError: false) == .offer)
        #expect(CloudBackupPage.make(.storeUnavailable(reason: "x"), hasError: false) == .offer)
        for status: CloudBackupAccount.Status in [.active, .overAllowance, .readOnly(readOnlyUntil: nil, deleteAfter: nil),
                                                   .lapsed(deleteAfter: nil), .revoked(deleteAfter: nil), .dataDeleted,
                                                   .needsRecoveryKey(.noKeyOnThisDevice), .needsRecoveryKey(.differentKey)] {
            #expect(CloudBackupPage.make(status, hasError: false) == .status, "\(status)")
        }
    }

    // MARK: What the reader can do

    @Test func onlyActiveBacksUp() {
        #expect(CloudBackupCapabilities.make(.active).canBackUp)
        #expect(!CloudBackupCapabilities.make(.overAllowance).canBackUp)
        #expect(!CloudBackupCapabilities.make(.readOnly(readOnlyUntil: Self.day, deleteAfter: nil)).canBackUp)
        #expect(!CloudBackupCapabilities.make(.needsRecoveryKey(.differentKey)).canBackUp)
    }

    @Test func overAllowanceRestoresAndDeletesReadOnlyOnlyRestores() {
        let over = CloudBackupCapabilities.make(.overAllowance)
        #expect(over.listsBackups && over.canDeleteBackups && over.canDeleteEverything)
        let readOnly = CloudBackupCapabilities.make(.readOnly(readOnlyUntil: nil, deleteAfter: nil))
        #expect(readOnly.listsBackups && !readOnly.canDeleteBackups && readOnly.canDeleteEverything)
    }

    @Test func noAccessListsNothingButCanStillDeleteEverything() {
        for status: CloudBackupAccount.Status in [.lapsed(deleteAfter: Self.day), .revoked(deleteAfter: nil)] {
            let capabilities = CloudBackupCapabilities.make(status)
            #expect(!capabilities.listsBackups && !capabilities.canBackUp && capabilities.canDeleteEverything, "\(status)")
        }
        let deleted = CloudBackupCapabilities.make(.dataDeleted)
        #expect(!deleted.listsBackups && !deleted.canDeleteEverything)
        // Starting over without the key is on the Enter Recovery Key page, with its own warning.
        #expect(!CloudBackupCapabilities.make(.needsRecoveryKey(.noKeyOnThisDevice)).canDeleteEverything)
    }

    // MARK: The banner

    @Test func activeHasNoBannerUnlessTheLastCheckFailed() {
        #expect(CloudBackupBanner.make(.active, errorMessage: nil, usage: nil) == nil)
        let banner = CloudBackupBanner.make(.active, errorMessage: "No network.", usage: nil)
        #expect(banner?.message == "No network.")
        #expect(banner?.actions == [.tryAgain])
    }

    @Test func unknownWithAnErrorOffersTryAgain() {
        #expect(CloudBackupBanner.make(.unknown, errorMessage: nil, usage: nil) == nil)
        let banner = CloudBackupBanner.make(.unknown, errorMessage: "Couldn’t reach it.", usage: nil)
        #expect(banner?.tone == .problem)
        #expect(banner?.message == "Couldn’t reach it.")
        #expect(banner?.actions == [.tryAgain])
    }

    @Test func overAllowanceSaysTheFiguresAndWhatStillWorks() throws {
        let banner = try #require(CloudBackupBanner.make(.overAllowance, errorMessage: nil, usage: Self.usage))
        #expect(banner.message.contains(BackupUIText.bytes(10_400_000_000)))
        #expect(banner.message.contains(BackupUIText.bytes(10_000_000_000)))
        #expect(banner.message.contains("can’t be made"))
        #expect(banner.message.contains("You can still restore, and delete old backups"))
        let withoutFigures = try #require(CloudBackupBanner.make(.overAllowance, errorMessage: nil, usage: nil))
        #expect(withoutFigures.message.contains("over your plan’s storage allowance"))
    }

    @Test func readOnlyGivesBothDatesAndOffersResubscribe() throws {
        let until = Self.day
        let after = Self.day.addingTimeInterval(30 * 86_400)
        let banner = try #require(CloudBackupBanner.make(.readOnly(readOnlyUntil: until, deleteAfter: after), errorMessage: nil,
                                                         usage: nil, dateText: { $0 == until ? "UNTIL" : "AFTER" }))
        #expect(banner.message == "New backups can’t be made. You can restore from your backups until UNTIL. They will be deleted after AFTER unless you resubscribe.")
        #expect(banner.actions == [.resubscribe])
        let undated = try #require(CloudBackupBanner.make(.readOnly(readOnlyUntil: nil, deleteAfter: nil), errorMessage: nil, usage: nil))
        #expect(undated.message.contains("for now"))
        #expect(!undated.message.contains("DATE"))
    }

    @Test func lapsedRevokedAndDeletedSayWhatHappensAndWhen() throws {
        let lapsed = try #require(CloudBackupBanner.make(.lapsed(deleteAfter: Self.day), errorMessage: nil, usage: nil, dateText: fixedDate))
        #expect(lapsed.message.contains("kept until DATE"))
        #expect(lapsed.message.contains("Resubscribe before then"))
        #expect(lapsed.actions == [.resubscribe])

        let revoked = try #require(CloudBackupBanner.make(.revoked(deleteAfter: Self.day), errorMessage: nil, usage: nil, dateText: fixedDate))
        #expect(revoked.message.contains("deleted on DATE"))
        #expect(revoked.actions.isEmpty)

        let deleted = try #require(CloudBackupBanner.make(.dataDeleted, errorMessage: nil, usage: nil))
        #expect(deleted.message.contains("have been deleted"))
        #expect(CloudBackupBanner.title(of: .resubscribe, status: .dataDeleted) == "Subscribe…")
        #expect(CloudBackupBanner.title(of: .resubscribe, status: .lapsed(deleteAfter: nil)) == "Resubscribe…")
    }

    @Test func noKeyOnThisDeviceSaysTheKeyMayBeArrivingFirst() throws {
        let banner = try #require(CloudBackupBanner.make(.needsRecoveryKey(.noKeyOnThisDevice), errorMessage: nil, usage: nil))
        #expect(banner.message.contains("iCloud Keychain"))
        #expect(banner.actions == [.tryAgain, .enterRecoveryKey])
        let different = try #require(CloudBackupBanner.make(.needsRecoveryKey(.differentKey), errorMessage: nil, usage: nil))
        #expect(different.actions == [.enterRecoveryKey])
    }

    @Test func bannerTextHasNoCryptographyJargon() {
        let statuses: [CloudBackupAccount.Status] = [
            .active, .overAllowance, .readOnly(readOnlyUntil: Self.day, deleteAfter: Self.day), .lapsed(deleteAfter: Self.day),
            .revoked(deleteAfter: Self.day), .dataDeleted, .needsRecoveryKey(.noKeyOnThisDevice), .needsRecoveryKey(.differentKey),
            .unknown, .storeUnavailable(reason: "Offline."), .notInThisBuild,
        ]
        let texts = statuses.compactMap { CloudBackupBanner.make($0, errorMessage: "x", usage: Self.usage) }.flatMap { [$0.title, $0.message] }
            + [CloudBackupOfferText.intro, CloudBackupOfferText.encrypted, CloudBackupOfferText.recoveryKey, CloudBackupOfferText.ending,
               CloudBackupRecoveryKeyText.explanation, CloudBackupRecoveryKeyText.startOverMessage, CloudBackupRecoveryKeyText.deleteMessage]
        for text in texts {
            for word in ["AES", "HKDF", "GCM", "R2", "Worker", "Keychain item", "iPhone"] {
                #expect(!text.contains(word), "\(word) in “\(text)”")
            }
        }
    }

    // MARK: The account's details

    @Test func periodsAndPricesReadNaturally() {
        #expect(CloudBackupStatusText.period(.init(value: 1, unit: .month)) == "a month")
        #expect(CloudBackupStatusText.period(.init(value: 1, unit: .year)) == "a year")
        #expect(CloudBackupStatusText.period(.init(value: 3, unit: .month)) == "every 3 months")
        #expect(CloudBackupStatusText.price(Self.product) == "£2.99 a month")
        let lifetime = BackupStoreProduct(id: "x", displayName: "X", displayPrice: "£9.99", subscriptionGroupID: nil, period: nil)
        #expect(CloudBackupStatusText.price(lifetime) == "£9.99")
    }

    @Test func planNameFallsBackToTheServiceName() {
        #expect(CloudBackupStatusText.planName(BackupSubscription.Plan(productID: "p", product: Self.product)) == "Cloud Backup")
        #expect(CloudBackupStatusText.planName(BackupSubscription.Plan(productID: "p", product: nil)) == "Tactile Texts Cloud")
        #expect(CloudBackupStatusText.planName(nil) == "Tactile Texts Cloud")
    }

    @Test func renewalLineSaysRenewsEndsOrEnded() {
        let plan = BackupSubscription.Plan(productID: "p", product: Self.product)
        #expect(CloudBackupStatusText.renewalLine(.subscribed(plan, renewsOrExpires: Self.day, willRenew: true), dateText: fixedDate) == "Renews on DATE")
        #expect(CloudBackupStatusText.renewalLine(.subscribed(plan, renewsOrExpires: Self.day, willRenew: false), dateText: fixedDate) == "Ends on DATE")
        #expect(CloudBackupStatusText.renewalLine(.ended(plan, endedAt: Self.day), dateText: fixedDate) == "Ended on DATE")
        #expect(CloudBackupStatusText.renewalLine(.subscribed(plan, renewsOrExpires: nil, willRenew: true)) == nil)
        #expect(CloudBackupStatusText.renewalLine(.notSubscribed) == nil)
    }

    @Test func usageLineAndFraction() {
        let half = BackupServiceUsage(bytes: 5_000_000_000, allowanceBytes: 10_000_000_000, overAllowance: false, countedAt: nil)
        #expect(CloudBackupStatusText.usageLine(half) == "\(BackupUIText.bytes(5_000_000_000)) of \(BackupUIText.bytes(10_000_000_000)) used")
        #expect(CloudBackupStatusText.usageFraction(half) == 0.5)
        #expect(CloudBackupStatusText.usageFraction(Self.usage) == 1, "capped")
        #expect(CloudBackupStatusText.usageFraction(.init(bytes: 0, allowanceBytes: 0, overAllowance: false, countedAt: nil)) == 0)
    }

    @Test func backUpFooterSaysWhyItIsOff() {
        #expect(CloudBackupStatusText.backUpRefusedFooter(.active) == nil)
        #expect(CloudBackupStatusText.backUpRefusedFooter(.overAllowance)?.contains("storage allowance") == true)
        #expect(CloudBackupStatusText.backUpRefusedFooter(.readOnly(readOnlyUntil: nil, deleteAfter: nil))?.contains("ended") == true)
    }

    // MARK: Subscribing

    @Test func subscribeButtonShowsPriceAndPeriod() {
        #expect(CloudBackupOfferText.subscribeTitle(Self.product, isOnlyOne: true) == "Subscribe for £2.99 a month")
        #expect(CloudBackupOfferText.subscribeTitle(Self.product, isOnlyOne: false) == "Cloud Backup: £2.99 a month")
    }

    @Test func onlyAPendingPurchaseNeedsExplaining() {
        #expect(CloudBackupOfferText.message(after: .purchased) == nil)
        #expect(CloudBackupOfferText.message(after: .cancelled) == nil, "a cancellation is silent")
        #expect(CloudBackupOfferText.message(after: .pending)?.contains("waiting for approval") == true)
    }

    @MainActor @Test func restorePurchasesSaysWhenNothingWasFound() {
        #expect(CloudBackupOfferText.messageAfterRestore(.notSubscribed)?.contains("No Tactile Texts Cloud subscription") == true)
        #expect(CloudBackupOfferText.messageAfterRestore(.unavailable(.productsNotFound)) != nil)
        let plan = BackupSubscription.Plan(productID: "p", product: nil)
        #expect(CloudBackupOfferText.messageAfterRestore(.subscribed(plan, renewsOrExpires: nil, willRenew: true)) == nil)
    }

    @Test func offerStatesThePolicyWithoutAccountDates() {
        #expect(CloudBackupOfferText.ending.contains("\(CloudBackupOfferText.readOnlyDays) days"))
        #expect(CloudBackupOfferText.ending.contains("\(CloudBackupOfferText.deleteAfterDays) days"))
        #expect(CloudBackupOfferText.encrypted.contains("encrypted on this iPad"))
        #expect(CloudBackupOfferText.renewalTerms.contains("renews automatically"))
    }

    // MARK: Links

    @Test func linksComeFromTheBuildSettingsAndEmptyOnesAreLeftOut() {
        let info: [String: Any] = ["BackupService": ["TermsURL": "example.com/terms", "PrivacyURL": ""]]
        let links = CloudBackupLinks.fromInfoDictionary(info)
        #expect(links.terms == URL(string: "https://example.com/terms"))
        #expect(links.privacy == nil)
        #expect(CloudBackupLinks.fromInfoDictionary(nil) == CloudBackupLinks(terms: nil, privacy: nil))
        #expect(CloudBackupLinks.fromInfoDictionary(["BackupService": ["TermsURL": "$(BACKUP_TERMS_URL)"]]).terms == nil)
    }

    @Test func linkURLsMustBeHTTPS() {
        #expect(CloudBackupLinks.url("https://example.com/p") == URL(string: "https://example.com/p"))
        #expect(CloudBackupLinks.url("  example.com/p  ") == URL(string: "https://example.com/p"))
        #expect(CloudBackupLinks.url("http://example.com/p") == nil)
        #expect(CloudBackupLinks.url("javascript://x") == nil)
        #expect(CloudBackupLinks.url("example .com") == nil)
        #expect(CloudBackupLinks.url("") == nil)
    }

    // MARK: The recovery key

    private static let formatted = "0C51-260Z-4RPK-8ET2-9585-EQK5-DHSQ-N0C8-HYB9-V95B-PAWW-1HYE-TQE0-045G"

    @Test func keyIsShownInItsGroups() {
        let groups = CloudBackupRecoveryKeyText.groups(Self.formatted)
        #expect(groups.count == 14)
        #expect(groups.allSatisfy { $0.count == 4 })
        #expect(CloudBackupRecoveryKeyText.lines(groups, perLine: 7).split(separator: "\n").count == 2)
        #expect(CloudBackupRecoveryKeyText.lines(groups, perLine: 4).split(separator: "\n").count == 4)
        #expect(CloudBackupRecoveryKeyText.lines(groups, perLine: 7).hasPrefix("0C51  260Z  4RPK"))
        #expect(CloudBackupRecoveryKeyText.lines(groups, perLine: 0).split(separator: "\n").count == 14)
    }

    @Test func voiceOverSpellsEachGroup() {
        let spoken = CloudBackupRecoveryKeyText.spoken(["0C51", "260Z"])
        #expect(spoken == "Group 1: 0 C 5 1. Group 2: 2 6 0 Z")
    }

    @Test func typedCountIgnoresSpacesAndDashes() {
        #expect(CloudBackupRecoveryKeyText.typedCount("0c51 260z-4rpk\n8et2") == 16)
        #expect(CloudBackupRecoveryKeyText.typedCount(" - ") == 0)
        #expect(CloudBackupRecoveryKeyText.progress("0C51-260Z") == "8 of 56 characters")
    }

    @Test func normalizedIgnoresCaseSpacesAndDashes() {
        #expect(CloudBackupRecoveryKeyText.normalized("0c51 260z-4RPK\n") == "0C51260Z4RPK")
        #expect(CloudBackupRecoveryKeyText.normalized("0C51-260Z") == CloudBackupRecoveryKeyText.normalized("0c51 260z"))
    }

    @Test func entryErrorsSayWhatWasWrong() {
        let short = "0C51-260Z"
        #expect(CloudBackupRecoveryKeyText.entryError(BackupError.recoveryKeyWrongLength, typed: short)
                == "That recovery key has 8 characters; a recovery key has 56. Check it and try again.")
        #expect(CloudBackupRecoveryKeyText.entryError(BackupError.recoveryKeyInvalidCharacter(position: 3), typed: "")
                .contains("Character 3"))
        #expect(CloudBackupRecoveryKeyText.entryError(BackupError.recoveryKeyTypo, typed: "").contains("typing mistake"))
        #expect(CloudBackupRecoveryKeyText.entryError(TactileCloudError.recoveryKeyDoesNotMatch, typed: "").contains("isn’t the one"))
    }

    @Test func savedDocumentHoldsTheFormattedKey() {
        let document = CloudBackupRecoveryKeyText.document(Self.formatted)
        #expect(document.contains(Self.formatted))
        #expect(document.contains("Tactile Texts Cloud recovery key"))
    }

    // MARK: Prompting for the recovery key

    @Test func promptsOnceAfterTheBackupThatMadeTheKey() {
        #expect(CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: true, shown: false, isBusy: false, status: .active))
        #expect(!CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: true, shown: false, isBusy: true, status: .active),
                "not while the backup is still running")
        #expect(!CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: true, shown: true, isBusy: false, status: .active))
        #expect(!CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: false, shown: false, isBusy: false, status: .active))
        #expect(!CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: nil, shown: false, isBusy: false, status: .active))
        #expect(!CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: true, shown: false, isBusy: false,
                                                          status: .needsRecoveryKey(.differentKey)))
    }

    @Test func remindsUntilSaved() {
        #expect(CloudBackupRecoveryKeyLogic.showsReminder(hasKey: true, saved: false, status: .active))
        #expect(CloudBackupRecoveryKeyLogic.showsReminder(hasKey: true, saved: false, status: .readOnly(readOnlyUntil: nil, deleteAfter: nil)))
        #expect(!CloudBackupRecoveryKeyLogic.showsReminder(hasKey: true, saved: true, status: .active))
        #expect(!CloudBackupRecoveryKeyLogic.showsReminder(hasKey: false, saved: false, status: .active))
        #expect(CloudBackupRecoveryKeyLogic.showsKey(hasKey: true, status: .overAllowance))
        #expect(!CloudBackupRecoveryKeyLogic.showsKey(hasKey: true, status: .lapsed(deleteAfter: nil)))
    }

    // MARK: The Backup screen's footnote

    @Test func footnoteIsHonestAboutEncryption() {
        #expect(BackupUIText.footnote(hasEncryptedDestination: false) == BackupUIText.footnote)
        #expect(BackupUIText.footnote.contains("doesn’t encrypt"))
        let withCloud = BackupUIText.footnote(hasEncryptedDestination: true)
        #expect(withCloud.contains("Tactile Texts Cloud are encrypted on this iPad"))
        #expect(withCloud.contains("Other backups aren’t encrypted"))
        #expect(!withCloud.contains("doesn’t encrypt backups"))
    }

    // MARK: The UI-test mode

    #if DEBUG
    @Test func uiTestModeKeysAreValidAndDifferent() throws {
        let right = try BackupRecoveryKey(CloudBackupUITestMode.recoveryKey)
        let other = try BackupRecoveryKey(CloudBackupUITestMode.otherRecoveryKey)
        #expect(right.formatted == CloudBackupUITestMode.recoveryKey)
        #expect(right != other)
        #expect(right.encryptionKey != other.encryptionKey)
    }
    #endif
}
