import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import S3Kit
import Testing
@testable import TactileTexts

/// `CloudBackupAccount`, the Worker-backed credentials and the `tactile-cloud` destination, on
/// fakes (`BackupCloudServiceRig`): each account state, the key rules, the mode refusals,
/// delete-everything, and that a default build creates nothing.
@MainActor
struct BackupCloudServiceAccountTests {
    typealias Rig = BackupCloudServiceRig
    typealias W = BackupCloudServiceFakeWorker

    // MARK: StoreKit first

    @Test func neverSubscribedNeverAsksTheService() async throws {
        let rig = try Rig.make(subscribed: false)
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .notSubscribed)
        #expect(await rig.destination.availability() == .unavailable(reason: CloudServiceError.notSubscribed.localizedDescription))
        await #expect(throws: CloudServiceError.notSubscribed) { try await rig.destination.listSnapshots() }
        await #expect(throws: CloudServiceError.notSubscribed) { try await rig.account.deleteEverything() }
        #expect(rig.worker.stub.requests.isEmpty)
        #expect(rig.r2.stub.requests.isEmpty)
    }

    @Test func aStoreThatCannotBeReachedSaysSo() async throws {
        let rig = try Rig.make(subscribed: false)
        defer { rig.cleanUp() }
        rig.store.productsError = .networkUnavailable
        await rig.start()
        #expect(rig.account.status == .storeUnavailable(reason: BackupSubscriptionError.networkUnavailable.localizedDescription))
        #expect(rig.worker.stub.requests.isEmpty)
    }

    @Test func aPurchaseIsNoticedByTheNextAvailabilityCheck() async throws {
        let rig = try Rig.make(subscribed: false)
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .notSubscribed)
        let transaction = BackupCloudServiceStoreFixtures.transaction(21, original: 21, purchased: -10, expires: 86_400)
        rig.store.statuses = [BackupStoreSubscriptionStatus(state: .subscribed, transaction: transaction, willAutoRenew: true)]
        rig.store.send(transaction)
        for _ in 0..<200 where !rig.account.needsRefresh { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await rig.destination.availability() == .available)
        #expect(rig.account.status == .active)
        #expect(rig.worker.sessions == 1)
    }

    // MARK: Active

    @Test func anEmptyFolderIsActiveAndTheFirstUploadMakesTheKey() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .active)
        #expect(rig.account.accessMode == .readWrite)
        #expect(rig.account.usage?.bytes == 1234 && rig.account.usage?.allowanceBytes == 10_000_000)
        #expect(rig.account.subscriptionInfo?.state == .active)
        #expect(rig.account.plan?.productID == BackupCloudServiceStoreFixtures.productID)
        #expect(rig.account.hasKeyOnThisDevice == false)
        #expect(try await rig.keyStore.load() == nil, "no key until there is something to encrypt")
        #expect(try await rig.destination.listSnapshots().isEmpty)
        #expect(try await rig.keyStore.load() == nil, "reading an empty folder makes no key")

        // The renewal info is sent with the session.
        let sent = try #require(rig.worker.sessionBodies.first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: String])
        #expect(body["signedRenewalInfo"] == Rig.renewalJWS)

        let pdf = try rig.pdf()
        try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        #expect(try await rig.keyStore.load() != nil)
        #expect(rig.account.hasKeyOnThisDevice == true)
        #expect(rig.account.recoveryKeyShown == false && rig.account.recoveryKeySaved == false)
        #expect(try await rig.destination.hasPDF(sha256: pdf.sha256, size: pdf.size))
        #expect(rig.r2.keys.contains(BackupCloudServiceFixtures.key("key-check")))

        let recovery = try await rig.account.recoveryKey()
        #expect(recovery.encryptionKey == (try await rig.keyStore.load()))
        #expect(rig.account.recoveryKeyShown && !rig.account.recoveryKeySaved)
        rig.account.markRecoveryKeySaved()
        #expect(rig.account.recoveryKeySaved)
        #expect(rig.defaults.bool(forKey: CloudBackupAccount.recoveryKeySavedKey))
    }

    @Test func aRoundTripThroughTheBackupEngine() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for store in [source, target] { try? FileManager.default.removeItem(at: store.rootDirectory) } }
        let seeded = try await BackupTestSupport.seedLibrary(source)
        let service = BackupTestSupport.makeService(source, scratch: rig.scratch)
        let result = try await service.backUp(to: rig.destination, includePDFs: true)
        #expect(result.uploadedPDFs == 2)
        for key in rig.r2.keys {
            #expect(!key.contains(".pdf") && !key.contains(".ttbackup") && !key.contains("Test iPad"), "\(key)")
        }
        #expect(!rig.r2.allBytes.starts(with: Data("PK".utf8)))

        let restoring = BackupTestSupport.makeService(target, scratch: rig.scratch)
        let snapshot = try #require(try await rig.destination.listSnapshots().first)
        let session = try await restoring.openBackup(snapshot, from: rig.destination)
        let summary = try await restoring.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(summary.restored.count == 2)
        #expect(try BackupTestSupport.archive(target, seeded.small.id) == (try BackupTestSupport.archive(source, seeded.small.id)))
        #expect(rig.worker.sessions == 1, "one session served the whole backup and restore")
    }

    // MARK: Credentials

    @Test func credentialsNearExpiryAskForANewSessionAndEverySessionUpdatesTheState() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.worker.sessions == 1)
        _ = try await rig.destination.listSnapshots()
        #expect(rig.worker.sessions == 1, "fresh credentials are reused")

        rig.worker.mode = "read-only"
        rig.worker.subscription = W.endedSubscription
        rig.clock.advance(800) // within two minutes of the 15-minute expiry
        _ = try await rig.destination.listSnapshots()
        #expect(rig.worker.sessions == 2)
        #expect(rig.account.status == .readOnly(readOnlyUntil: W.readOnlyUntil, deleteAfter: W.deleteAfter),
                "the session the store asked for updated the account")
        #expect(rig.r2.stub.requests.allSatisfy { $0.headers["x-amz-security-token"] != nil })
        #expect(rig.r2.stub.requests.last?.headers["x-amz-security-token"] == "token-2")
    }

    @Test func concurrentCallersShareOneSessionRequest() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.cloud.subscription.load()
        let destination = rig.destination
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await destination.listSnapshots() }
            }
            try await group.waitForAll()
        }
        #expect(rig.worker.sessions == 1)
    }

    @Test func availabilityAsksNothingOnceTheStateIsKnown() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        let before = rig.worker.stub.requests.count + rig.r2.stub.requests.count
        #expect(await rig.destination.availability() == .available)
        #expect(rig.worker.stub.requests.count + rig.r2.stub.requests.count == before)
    }

    @Test func aFailureBeforeAnythingIsKnownLeavesTheStateUnknownWithTheError() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.worker.sessionFailure = .init(status: 401, code: "transaction-invalid", subscription: nil)
        await rig.start()
        #expect(rig.account.status == .unknown)
        #expect(rig.account.lastError as? CloudServiceError == .transactionInvalid)
        #expect(await rig.destination.availability()
                == .unavailable(reason: CloudServiceError.transactionInvalid.localizedDescription))
        // The service's error reaches the store's caller unchanged.
        await #expect(throws: CloudServiceError.transactionInvalid) { try await rig.destination.listSnapshots() }
        rig.worker.sessionFailure = nil
        await rig.account.refresh()
        #expect(rig.account.status == .active && rig.account.lastError == nil)
    }

    // MARK: Ended subscriptions

    @Test func readOnlyRestoresButRefusesABackupBeforeSendingAnything() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        let pdf = try rig.pdf()
        let snapshot = try rig.snapshot()
        try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        let stored = try await rig.destination.uploadSnapshot(from: snapshot.url, name: snapshot.name, progress: nil)

        rig.worker.mode = "read-only"
        rig.worker.subscription = W.endedSubscription
        await rig.account.refresh()
        #expect(rig.account.status == .readOnly(readOnlyUntil: W.readOnlyUntil, deleteAfter: W.deleteAfter))
        #expect(await rig.destination.availability() == .available, "restores must stay reachable")
        let writes = rig.bucketWrites
        let other = try rig.pdf(seed: 8)
        await #expect(throws: TactileCloudError.readOnly(readOnlyUntil: W.readOnlyUntil, deleteAfter: W.deleteAfter)) {
            try await rig.destination.uploadPDF(from: other.url, sha256: other.sha256, size: other.size, progress: nil)
        }
        await #expect(throws: TactileCloudError.readOnly(readOnlyUntil: W.readOnlyUntil, deleteAfter: W.deleteAfter)) {
            try await rig.destination.uploadSnapshot(from: snapshot.url, name: snapshot.name, progress: nil)
        }
        await #expect(throws: TactileCloudError.readOnly(readOnlyUntil: W.readOnlyUntil, deleteAfter: W.deleteAfter)) {
            try await rig.destination.deleteSnapshot(stored)
        }
        #expect(rig.bucketWrites == writes, "nothing was sent")
        #expect(TactileCloudError.readOnly(readOnlyUntil: W.readOnlyUntil, deleteAfter: nil).localizedDescription
            .contains(CloudServiceError.day(W.readOnlyUntil)))

        let restored = rig.scratch.appendingPathComponent("restored.pdf")
        try await rig.destination.downloadPDF(sha256: pdf.sha256, to: restored, progress: nil)
        #expect(try Data(contentsOf: restored) == Data(contentsOf: pdf.url))
        #expect(try await rig.destination.listSnapshots().map(\.name) == [snapshot.name])
    }

    @Test func overTheAllowanceDeletesButRefusesABackup() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        let snapshot = try rig.snapshot()
        let stored = try await rig.destination.uploadSnapshot(from: snapshot.url, name: snapshot.name, progress: nil)

        rig.worker.mode = "read-delete"
        rig.worker.usage = (12_000_000, 10_000_000)
        await rig.account.refresh()
        #expect(rig.account.status == .overAllowance)
        #expect(rig.account.usage?.overAllowance == true)
        let writes = rig.bucketWrites
        let pdf = try rig.pdf()
        await #expect(throws: TactileCloudError.overAllowance(usedBytes: 12_000_000, allowanceBytes: 10_000_000)) {
            try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        }
        #expect(rig.bucketWrites == writes)
        try await rig.destination.deleteSnapshot(stored)
        #expect(try await rig.destination.listSnapshots().isEmpty)
        #expect(TactileCloudError.overAllowance(usedBytes: 12_000_000, allowanceBytes: 10_000_000).localizedDescription
            .contains("Delete some backups"))
    }

    @Test(arguments: ["subscription-lapsed", "subscription-revoked", "data-deleted"])
    func refusalsBecomeStates(code: String) async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.worker.sessionFailure = .init(status: 403, code: code, subscription: W.endedSubscription)
        await rig.start()
        let expected: CloudBackupAccount.Status = switch code {
        case "subscription-lapsed": .lapsed(deleteAfter: W.deleteAfter)
        case "subscription-revoked": .revoked(deleteAfter: W.deleteAfter)
        default: .dataDeleted
        }
        #expect(rig.account.status == expected)
        #expect(rig.account.lastError == nil && rig.account.accessMode == nil)
        #expect(rig.account.subscriptionInfo?.deleteAfter == W.deleteAfter)
        guard case .unavailable(let reason) = await rig.destination.availability() else {
            Issue.record("available while \(code)")
            return
        }
        if code != "data-deleted" { #expect(reason.contains(CloudServiceError.day(W.deleteAfter))) }
        let thrown = await #expect(throws: CloudServiceError.self) { try await rig.destination.listSnapshots() }
        #expect(thrown?.code == code, "passed through unchanged")
    }

    // MARK: The key

    @Test(arguments: ["key-check", "Backups/x.ttenc", "PDFs/y.ttenc"])
    func aKeyIsNeverMadeWhenTheFolderHoldsAnything(object: String) async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.r2.put(BackupCloudServiceFixtures.key(object), Data([7, 7, 7]))
        await rig.start()
        #expect(rig.account.status == .needsRecoveryKey(.noKeyOnThisDevice))
        #expect(rig.account.accessMode == .readWrite, "the mode is still known")
        #expect(rig.account.hasKeyOnThisDevice == false)
        let pdf = try rig.pdf()
        await #expect(throws: TactileCloudError.needsRecoveryKey(.noKeyOnThisDevice)) {
            try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        }
        await #expect(throws: TactileCloudError.needsRecoveryKey(.noKeyOnThisDevice)) {
            try await rig.destination.listSnapshots()
        }
        #expect(try await rig.keyStore.load() == nil, "no key was created")
        #expect(await rig.destination.availability()
                == .unavailable(reason: TactileCloudError.needsRecoveryKey(.noKeyOnThisDevice).localizedDescription))
    }

    @Test func aDifferentKeyNeedsTheRecoveryKeyAndOnlyTheRightOneIsTaken() async throws {
        let original = BackupEncryptionKey.generate()
        let rig = try Rig.make(key: original)
        defer { rig.cleanUp() }
        await rig.start()
        let pdf = try rig.pdf()
        try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)

        // This device ends up with another key (say, a fresh install made one before the
        // original arrived).
        let other = BackupEncryptionKey.generate()
        _ = try await rig.keyStore.adoptKey(recoveryKey: other.recoveryKey.formatted)
        await rig.account.refresh()
        #expect(rig.account.status == .needsRecoveryKey(.differentKey))
        #expect(rig.account.hasKeyOnThisDevice == true)
        await #expect(throws: BackupError.wrongEncryptionKey) {
            try await rig.destination.hasPDF(sha256: pdf.sha256, size: pdf.size)
        }

        await #expect(throws: TactileCloudError.recoveryKeyDoesNotMatch) {
            try await rig.account.adoptRecoveryKey(BackupEncryptionKey.generate().recoveryKey.formatted)
        }
        #expect(try await rig.keyStore.load() == other, "a wrong key is not stored")
        await #expect(throws: (any Error).self) { try await rig.account.adoptRecoveryKey("not a recovery key") }

        try await rig.account.adoptRecoveryKey(original.recoveryKey.formatted)
        #expect(try await rig.keyStore.load() == original)
        #expect(rig.account.status == .active)
        #expect(rig.account.recoveryKeySaved)
        #expect(try await rig.destination.hasPDF(sha256: pdf.sha256, size: pdf.size))
    }

    @Test func theRecoveryKeyFixesANewDeviceWithoutAKey() async throws {
        let original = BackupEncryptionKey.generate()
        let first = try Rig.make(key: original)
        defer { first.cleanUp() }
        await first.start()
        let pdf = try first.pdf()
        try await first.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)

        // A second device on the same folder, with no key.
        try await first.keyStore.removeKey()
        first.connection.invalidateDestinations()
        await first.account.refresh()
        #expect(first.account.status == .needsRecoveryKey(.noKeyOnThisDevice))
        try await first.account.adoptRecoveryKey(original.recoveryKey.formatted)
        #expect(first.account.status == .active)
        #expect(try await first.destination.hasPDF(sha256: pdf.sha256, size: pdf.size))
    }

    // MARK: Deleting everything

    @Test func deleteEverythingRepeatsUntilDoneThenRemovesTheKey() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        for seed in UInt8(1)...UInt8(4) {
            let pdf = try rig.pdf(seed: seed)
            try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        }
        rig.account.markRecoveryKeySaved()
        #expect(rig.r2.keys.count == 5) // the key check and four PDFs
        rig.worker.deleteBatch = 2

        try await rig.account.deleteEverything()
        #expect(rig.worker.deleteCalls == 3)
        #expect(rig.r2.keys.isEmpty)
        #expect(try await rig.keyStore.load() == nil)
        #expect(rig.account.hasKeyOnThisDevice == false)
        #expect(!rig.account.recoveryKeyShown && !rig.account.recoveryKeySaved)
        #expect(rig.account.status == .active, "refreshed: an empty folder, a fresh key at the next backup")

        let pdf = try rig.pdf(seed: 30)
        try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        #expect(try await rig.keyStore.load() != nil)
    }

    @Test func aFailedDeletionKeepsTheKey() async throws {
        let rig = try Rig.make(key: .generate())
        defer { rig.cleanUp() }
        await rig.start()
        rig.r2.put(BackupCloudServiceFixtures.key("PDFs/a.ttenc"), Data([1]))
        rig.worker.deleteBatch = 0 // never makes progress
        await #expect(throws: TactileCloudError.deletionUnfinished) { try await rig.account.deleteEverything() }
        #expect(try await rig.keyStore.load() != nil)
        #expect(rig.account.lastError as? TactileCloudError == .deletionUnfinished)
    }

    // MARK: The default build

    @Test func aDefaultBuildCreatesAndRegistersNothing() throws {
        #expect(BackupServiceConfiguration.fromInfoDictionary(Bundle.main.infoDictionary) == nil,
                "the test host is built with the settings empty")
        #expect(TactileCloudBackup.make(infoDictionary: Bundle.main.infoDictionary) == nil)
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let environment = AppEnvironment(store: store, launchOptions: LaunchOptions(arguments: ["app"]))
        #expect(environment.cloudBackup == nil)
        #expect(!environment.backupDestinations.entries.contains { $0.id == TactileCloudBackupDestination.destinationID })
        #expect(environment.backupDestinations.destination(id: TactileCloudBackupDestination.destinationID) == nil)
    }

    @Test func aConfiguredBuildRegistersTheDestinationLast() throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let info: [String: Any] = ["BackupService": ["Host": "localhost:8787", "ProductIDs": BackupCloudServiceStoreFixtures.productID]]
        let environment = AppEnvironment(store: store, launchOptions: LaunchOptions(arguments: ["app"]), infoDictionary: info)
        let cloud = try #require(environment.cloudBackup)
        let last = try #require(environment.backupDestinations.entries.last)
        #expect(last.id == "tactile-cloud" && last.displayName == "Tactile Texts Cloud")
        #expect(cloud.configuration.baseURL.absoluteString == "http://localhost:8787")
        #expect(BackupDestinationKind(id: last.id) == .tactileCloud)
        #expect(BackupDestinationKind.tactileCloud.systemImage == "lock.icloud")
    }

    @Test func statusesMapToAvailability() {
        typealias A = CloudBackupAccount
        let info = BackupCloudServiceClientTests.lapsedInfo
        #expect(A.availability(status: .active, info: nil, lastError: nil) == .available)
        #expect(A.availability(status: .overAllowance, info: nil, lastError: nil) == .available)
        #expect(A.availability(status: .readOnly(readOnlyUntil: nil, deleteAfter: nil), info: nil, lastError: nil) == .available)
        for status: A.Status in [.notInThisBuild, .unknown, .storeUnavailable(reason: "x"), .notSubscribed,
                                 .needsRecoveryKey(.differentKey), .lapsed(deleteAfter: nil), .revoked(deleteAfter: nil), .dataDeleted] {
            #expect(!A.availability(status: status, info: info, lastError: nil).isAvailable, "\(status)")
        }
        #expect(A.availability(status: .notInThisBuild, info: nil, lastError: nil)
                == .unavailable(reason: "Tactile Texts Cloud isn’t available in this version of Tactile Texts."))
        let account = CloudBackupAccount(subscription: nil, connection: nil)
        #expect(account.status == .notInThisBuild && !account.needsRefresh)
    }
}
