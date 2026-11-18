import Foundation
import ReaderBackup
import ReaderSync
import Testing
@testable import TactileTexts

/// Sync's plain rules (C4b): the status line for every state, the join sheet's decision, the PDF
/// policy, each book's state from a report, the schedule rule and the back-off, and the sync
/// sentences in the restore and delete confirmations.
@MainActor
struct SyncUILogicTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func line(_ status: SyncStatus, isOn: Bool = true, last: Date? = nil,
                      cause: SyncPullOnlyCause = .unknown) -> SyncStatusLine {
        SyncStatusText.line(status: status, isOn: isOn, lastSyncedAt: last, pullOnlyCause: cause, now: now, calendar: calendar)
    }

    // MARK: Status line

    @Test func everyStatusHasPlainWords() {
        let today = now.addingTimeInterval(-60)
        let todayText = SyncStatusText.when(today, now: now, calendar: calendar)
        #expect(todayText.hasPrefix("today at "))
        let earlier = now.addingTimeInterval(-3 * 86_400)
        #expect(!SyncStatusText.when(earlier, now: now, calendar: calendar).hasPrefix("today"))

        // Off: says so, whatever the service last said.
        let off = line(.upToDate(today), isOn: false)
        #expect(off.text.hasPrefix("Sync is off."))
        #expect(off.action == nil)

        #expect(line(.idle).text == "Waiting to sync…")
        #expect(line(.idle).isBusy)
        #expect(line(.idle, last: today).text == "Last synced \(todayText).")
        #expect(line(.syncing).text == "Syncing…")
        #expect(line(.syncing).isBusy)
        let upToDate = line(.upToDate(today))
        #expect(upToDate.text == "Up to date. Last synced \(todayText).")
        #expect(upToDate.tone == .normal && upToDate.action == nil)

        #expect(line(.waiting(.signedOut)).text == "Sign in to Tactile Texts Cloud to sync.")
        #expect(line(.waiting(.backupOrRestore)).text.hasPrefix("Paused while a backup or restore runs."))
        #expect(line(.waiting(.offline)).text.hasPrefix("Waiting for the network."))
        #expect(line(.waiting(.offline), last: today).text.hasSuffix("Last synced \(todayText)."))
        #expect(line(.waiting(.editInProgress)).text.contains("what you’re working on"))
        #expect(line(.waiting(.needsNewerApp)).text.contains("Update the app on this device to send its changes"))
        #expect(line(.waiting(.accountNeedsNewerApp)).text.contains("Update the app on this device to keep syncing"))
        for reason: SyncWaitReason in [.signedOut, .backupOrRestore, .offline, .pullOnly, .editInProgress, .needsNewerApp,
                                       .accountNeedsNewerApp] {
            #expect(line(.waiting(reason)).tone == .waiting, "\(reason)")
        }

        // Pull-only says that changes here wait, and why.
        let ended = line(.waiting(.pullOnly), cause: .subscriptionEnded)
        #expect(ended.text.contains("subscription has ended") && ended.text.contains("changes on this device wait"))
        let full = line(.waiting(.pullOnly), cause: .storageFull)
        #expect(full.text.contains("storage is full") && full.text.contains("changes on this device wait"))
        #expect(line(.waiting(.pullOnly)).text.contains("changes on this device wait"))
        #expect(SyncPullOnlyCause.from(.readOnly(readOnlyUntil: nil, deleteAfter: nil)) == .subscriptionEnded)
        #expect(SyncPullOnlyCause.from(.overAllowance) == .storageFull)
        #expect(SyncPullOnlyCause.from(.active) == .unknown)

        let join = line(.needsJoinConfirmation)
        #expect(join.action == .reviewJoin)
        let noKey = line(.needsKey(.noKeyOnThisDevice))
        #expect(noKey.action == .enterRecoveryKey && noKey.text.contains("iCloud Keychain"))
        let otherKey = line(.needsKey(.differentKey))
        #expect(otherKey.action == .enterRecoveryKey && otherKey.text.contains("different key"))

        let failed = line(.failed("The account couldn’t be reached."))
        #expect(failed.text == "Couldn’t sync. The account couldn’t be reached.")
        #expect(failed.tone == .problem && failed.action == .tryAgain)
    }

    @Test func theStatusValueNamesEachState() {
        #expect(SyncSectionView.statusValue(.upToDate(now), isOn: false) == "off")
        #expect(SyncSectionView.statusValue(.upToDate(now), isOn: true) == "upToDate")
        #expect(SyncSectionView.statusValue(.waiting(.offline), isOn: true) == "waiting.offline")
        #expect(SyncSectionView.statusValue(.needsJoinConfirmation, isOn: true) == "needsJoin")
    }

    @Test func theSectionShowsOnlyForASubscribersAccount() {
        #expect(SyncAvailability.showsSection(.active))
        #expect(SyncAvailability.showsSection(.overAllowance))
        #expect(SyncAvailability.showsSection(.readOnly(readOnlyUntil: nil, deleteAfter: nil)))
        #expect(SyncAvailability.showsSection(.needsRecoveryKey(.noKeyOnThisDevice)))
        for status: CloudBackupAccount.Status in [.notInThisBuild, .unknown, .signedOut, .notSubscribed, .lapsed(deleteAfter: nil),
                                                  .revoked(deleteAfter: nil), .dataDeleted, .storeUnavailable(reason: "x")] {
            #expect(!SyncAvailability.showsSection(status), "\(status)")
        }
    }

    // MARK: Join

    @Test func theJoinSheetIsNeededOnlyWhenBothSidesHaveBooks() {
        #expect(SyncJoinLogic.needsSheet(SyncJoinPreview(onlyHere: 1, onlyInAccount: 1, inBoth: 0)))
        #expect(SyncJoinLogic.needsSheet(SyncJoinPreview(onlyHere: 0, onlyInAccount: 0, inBoth: 1)), "the same book on both")
        #expect(SyncJoinLogic.needsSheet(SyncJoinPreview(onlyHere: 2, onlyInAccount: 0, inBoth: 1)))
        #expect(!SyncJoinLogic.needsSheet(SyncJoinPreview(onlyHere: 0, onlyInAccount: 3, inBoth: 0)), "a device with no books")
        #expect(!SyncJoinLogic.needsSheet(SyncJoinPreview(onlyHere: 3, onlyInAccount: 0, inBoth: 0)), "an empty account")
        #expect(!SyncJoinLogic.needsSheet(SyncJoinPreview(onlyHere: 0, onlyInAccount: 0, inBoth: 0)))
        #expect(SyncJoinLogic.explanation.contains("Nothing is removed"))
    }

    // MARK: PDFs

    @Test func automaticDownloadsNeedWiFiWithoutLowDataMode() {
        #expect(SyncPDFRule.allowsAutomatic(.automaticOnWiFi, path: .wifi))
        #expect(!SyncPDFRule.allowsAutomatic(.automaticOnWiFi, path: .cellular), "expensive")
        #expect(!SyncPDFRule.allowsAutomatic(.automaticOnWiFi, path: SyncNetworkPath(isSatisfied: true, isExpensive: false, isConstrained: true)),
                "Low Data Mode")
        #expect(!SyncPDFRule.allowsAutomatic(.automaticOnWiFi, path: .offline))
        #expect(!SyncPDFRule.allowsAutomatic(.automaticOnWiFi, path: nil), "the path isn't known yet")
        #expect(!SyncPDFRule.allowsAutomatic(.onOpen, path: .wifi))
    }

    @Test func thePDFPolicyIsStoredAndTheSwitchIsPerAccount() throws {
        let suite = "SyncSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SyncSettings(defaults: defaults)
        #expect(settings.pdfPolicy == .automaticOnWiFi, "automatic by default")
        #expect(!settings.isEnabled)
        settings.isEnabled = true
        #expect(!settings.isEnabled, "signed out: the switch reads as off and can't be turned on")
        settings.setAccount("a")
        #expect(!settings.isEnabled, "off by default")
        settings.isEnabled = true
        settings.pdfPolicy = .onOpen
        settings.setAccount("b")
        #expect(!settings.isEnabled, "another account starts off")
        settings.setAccount(nil)
        #expect(!settings.isEnabled)
        settings.setAccount("a")
        #expect(settings.isEnabled, "signing back in resumes as it was")

        let reread = SyncSettings(defaults: defaults)
        reread.setAccount("a")
        #expect(reread.isEnabled && reread.pdfPolicy == .onOpen)
        SyncSettings.reset(in: defaults)
        let reset = SyncSettings(defaults: defaults)
        reset.setAccount("a")
        #expect(!reset.isEnabled && reset.pdfPolicy == .automaticOnWiFi)
    }

    // MARK: Each book's state

    @Test func eachBooksStateComesFromTheReport() {
        let edited = UUID(), pullOnly = UUID(), newer = UUID(), failed = UUID(), fine = UUID(), duplicate = UUID()
        struct Failure: LocalizedError { var errorDescription: String? { "The head couldn’t be read." } }
        let report = SyncReport(mode: .full, books: [
            SyncBookReport(bookKey: "k1", bookID: edited, action: .merged, skipped: [.busy([.page(2)])]),
            SyncBookReport(bookKey: "k2", bookID: pullOnly, skipped: [.pullOnly]),
            SyncBookReport(bookKey: "k3", bookID: newer, action: .pulled, skipped: [.readOnly(requiredLevel: 9)]),
            SyncBookReport(bookKey: "k4", bookID: failed, skipped: [.pullOnly], failure: SyncBookFailure(Failure())),
            SyncBookReport(bookKey: "k5", bookID: fine, action: .pushed),
            SyncBookReport(bookKey: "k6", bookID: duplicate, skipped: [.duplicatePDF(of: fine)]),
        ], upToDate: 4)
        #expect(SyncBookState.make(report, bookID: edited) == .waitingForEdit)
        #expect(SyncBookState.make(report, bookID: pullOnly) == .waitingToSend)
        #expect(SyncBookState.make(report, bookID: newer) == .needsNewerApp)
        #expect(SyncBookState.make(report, bookID: failed) == .failed("The head couldn’t be read."), "a failure comes first")
        #expect(SyncBookState.make(report, bookID: duplicate) == .duplicate)
        #expect(SyncBookState.make(report, bookID: fine) == nil, "up to date: nothing shown")
        #expect(SyncBookState.make(report, bookID: UUID()) == nil, "skipped as up to date")
        #expect(SyncBookState.make(nil, bookID: edited) == nil)
        let all = SyncBookState.all(report)
        #expect(all.count == 5 && all[fine] == nil)
        #expect(SyncBookState.failed("x").isFailure && !SyncBookState.waitingToSend.isFailure)
        #expect(SyncBookState.failed("It broke.").reason.contains("It broke."))
    }

    // MARK: Scheduling rules

    @Test func theScheduleRuleAndTheBackOff() {
        typealias R = SyncScheduleRule
        #expect(R.skip(isOn: false, backupRunning: false, trigger: .manual, backoffUntil: nil, now: now) == .off)
        #expect(R.skip(isOn: true, backupRunning: true, trigger: .manual, backoffUntil: nil, now: now) == .backupRunning)
        let until = now.addingTimeInterval(60)
        #expect(R.skip(isOn: true, backupRunning: false, trigger: .foregroundTick, backoffUntil: until, now: now) == .backingOff(until: until))
        #expect(R.skip(isOn: true, backupRunning: false, trigger: .manual, backoffUntil: until, now: now) == nil, "Sync Now goes through")
        #expect(R.skip(isOn: true, backupRunning: false, trigger: .switchedOn, backoffUntil: until, now: now) == nil)
        #expect(R.skip(isOn: true, backupRunning: false, trigger: .networkReturned, backoffUntil: until, now: now) == nil)
        #expect(R.skip(isOn: true, backupRunning: false, trigger: .foregroundTick, backoffUntil: now.addingTimeInterval(-1), now: now) == nil)

        let backoff = SyncBackoff.standard
        #expect(backoff.delay(afterFailures: 0) == 0)
        #expect(backoff.delay(afterFailures: 1) == 30)
        #expect(backoff.delay(afterFailures: 2) == 60)
        #expect(backoff.delay(afterFailures: 3) == 120)
        #expect(backoff.delay(afterFailures: 6) == 900, "the ceiling")
        #expect(backoff.delay(afterFailures: 500) == 900)
        #expect(SyncBackoff.counts(.failed("x")) == true)
        #expect(SyncBackoff.counts(.waiting(.offline)) == true)
        #expect(SyncBackoff.counts(.upToDate(now)) == false)
        #expect(SyncBackoff.counts(.waiting(.pullOnly)) == false)
        #expect(SyncBackoff.counts(.needsJoinConfirmation) == nil)
        #expect(SyncBackoff.counts(.needsKey(.noKeyOnThisDevice)) == nil)
    }

    // MARK: Restore and delete

    @Test func confirmationsSayWhenSyncCarriesTheChange() {
        let record = RestoreSafetyRecord(id: UUID(), createdAt: now, sourceName: "Test", changed: [],
                                         added: [.init(id: UUID(), title: "Added")])
        #expect(!UndoRestoreLogic.confirmation(record).message.contains("Sync is on"))
        #expect(UndoRestoreLogic.confirmation(record, syncOn: true).message.contains(SyncNoticeText.restoreCarried))
        #expect(SyncNoticeText.restoreCarried.contains("other devices"))
        #expect(SyncNoticeText.deleteCarried.contains("removed from your other devices"))
        // C5: Recently Deleted is built, so the confirmation may now promise the way back.
        #expect(SyncNoticeText.deleteCarried.contains("Recently Deleted") && SyncNoticeText.deleteCarried.contains("30 days"))
    }
}
