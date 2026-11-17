import Foundation
import ReaderBackup
import ReaderSync
import Testing
@testable import TactileTexts

/// Signing in to Tactile Texts Cloud (`CloudBackupSignIn` with `CloudBackupAccount`) on fakes:
/// sign-in both ways with the challenge's nonce, changing the sign-in, signing out here and
/// everywhere, a session that ended, Apple's revocation, deleting the account step by step, the
/// key kept per account, the purchase's `appAccountToken`, the device label, and automatic
/// backup on by default for a signed-in subscriber.
@MainActor
struct CloudAccountSignInTests {
    typealias Rig = BackupCloudServiceRig
    typealias W = BackupCloudServiceFakeWorker

    /// The JSON body of the last request to `path`.
    private func lastBody(_ rig: Rig, _ path: String) throws -> [String: String] {
        let request = try #require(rig.worker.stub.requests("POST", pathPrefix: path).last)
        return try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
    }

    /// Nothing the service received holds an email address.
    private func noEmailSent(_ rig: Rig) -> Bool {
        rig.worker.stub.requests.allSatisfy { !String(decoding: $0.body, as: UTF8.self).contains("@") }
    }

    // MARK: Signing in

    @Test(arguments: CloudSignInProvider.allCases)
    func signingInBindsTheTokenToTheChallengeAndKeepsTheSessionOnThisDevice(provider: CloudSignInProvider) async throws {
        let rig = try Rig.make(signedIn: false)
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .signedOut)

        try await rig.signIn.signIn(with: provider, anchor: nil)
        let body = try lastBody(rig, "/v1/auth/\(provider.rawValue)")
        #expect(body["action"] == "auth-\(provider.rawValue)")
        let challenge = try #require(body["challenge"].flatMap { Data(base64Encoded: $0) })
        #expect(rig.identity.requests.last?.nonce == W.hex(challenge), "the ID token's nonce is the challenge's SHA-256")
        #expect(body["idToken"]?.hasSuffix(W.hex(challenge)) == true)
        #expect((body["authorizationCode"] != nil) == (provider == .apple))
        #expect(noEmailSent(rig), "the email stays on the iPad")

        let session = try #require(try rig.sessionStore.load())
        #expect(session.provider == provider && session.deviceSessionToken.hasPrefix("SESSION-"))
        #expect(session.email == "reader@\(provider.rawValue).example")
        #expect(rig.signIn.isSignedIn && rig.signIn.signedOutReason == nil)
        #expect(rig.signIn.accountInfo?.devices.contains { $0.isCurrent } == true)
        // Apple's identity reaches the account the rig's other device uses; Google's is new.
        #expect((session.accountID == W.account(1)) == (provider == .apple))

        // The account is checked again with the new session.
        for _ in 0..<200 where rig.account.status != .active { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.account.status == .active)
        #expect(try lastBody(rig, "/v1/session")["deviceSessionToken"] == session.deviceSessionToken)
        #expect(String(describing: session).contains(session.deviceSessionToken) == false)
    }

    @Test func aCancelledSignInChangesNothing() async throws {
        let rig = try Rig.make(signedIn: false)
        defer { rig.cleanUp() }
        rig.identity.cancelNext = true
        await #expect(throws: CloudSignInError.cancelled) { try await rig.signIn.signIn(with: .google, anchor: nil) }
        #expect(!rig.signIn.isSignedIn && rig.signIn.activity == nil)
        #expect(try rig.sessionStore.load() == nil)
        #expect(rig.worker.stub.requests("POST", pathPrefix: "/v1/auth").isEmpty)
    }

    // MARK: Changing the sign-in

    @Test func changingToGoogleKeepsTheAccountFolderAndKey() async throws {
        let key = BackupEncryptionKey.generate()
        let rig = try Rig.make(key: key)
        defer { rig.cleanUp() }
        await rig.start()
        try await rig.signIn.changeSignIn(anchor: nil)

        let body = try lastBody(rig, "/v1/auth/change")
        let nonce = W.hex(try #require(body["challenge"].flatMap { Data(base64Encoded: $0) }))
        #expect(body["newProvider"] == "google" && body["currentAuthorizationCode"] == "fake-code")
        #expect(body["currentIdToken"]?.hasPrefix("fake-id-token.apple.") == true && body["currentIdToken"]?.hasSuffix(nonce) == true)
        #expect(body["newIdToken"]?.hasPrefix("fake-id-token.google.") == true && body["newIdToken"]?.hasSuffix(nonce) == true)
        #expect(rig.identity.requests.suffix(2).map(\.provider) == [.apple, .google], "the current sign-in first, then the new one")

        let session = try #require(rig.signIn.session)
        #expect(session.provider == .google && session.accountID == W.account(1))
        #expect(session.deviceSessionToken == W.liveToken, "this device stays signed in")
        #expect(session.email == "reader@google.example")
        #expect(rig.worker.accountsByIdentity["google:reader"]?.id == W.account(1))
        #expect(rig.worker.accountsByIdentity["apple:reader"] == nil)
        #expect(try await rig.keyStore.load() == key, "the key is the same before and after")
        #expect(noEmailSent(rig))

        // And back.
        try await rig.signIn.changeSignIn(anchor: nil)
        #expect(rig.signIn.session?.provider == .apple && rig.signIn.session?.accountID == W.account(1))
        #expect(try lastBody(rig, "/v1/auth/change")["currentAuthorizationCode"] == nil, "leaving Google needs no code")
    }

    @Test func aChangeToAnIdentityWithItsOwnAccountIsRefusedAndNothingChanges() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.worker.addAccount(identity: "google:reader")
        await #expect(throws: CloudServiceError.identityInUse) { try await rig.signIn.changeSignIn(anchor: nil) }
        #expect(rig.signIn.session == Rig.liveSession, "still signed in with Apple, as before")
        #expect(rig.worker.accountsByIdentity["apple:reader"]?.id == W.account(1))
        #expect(rig.signIn.activity == nil)
        #expect(CloudServiceError.identityInUse.localizedDescription.contains("account of its own"))
    }

    @Test func aCancelledChangeChangesNothing() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.identity.cancelNext = true
        await #expect(throws: CloudSignInError.cancelled) { try await rig.signIn.changeSignIn(anchor: nil) }
        #expect(rig.signIn.session == Rig.liveSession)
        #expect(rig.worker.stub.requests("POST", pathPrefix: "/v1/auth/change").isEmpty)
    }

    // MARK: Signing out

    @Test func signingOutEndsThisSessionOnlyAndKeepsTheKey() async throws {
        let key = BackupEncryptionKey.generate()
        let rig = try Rig.make(key: key)
        defer { rig.cleanUp() }
        let other = rig.worker.addSession()
        await rig.start()
        #expect(rig.account.status == .active)

        await rig.signIn.signOut()
        #expect(!rig.worker.liveTokens.contains(W.liveToken) && rig.worker.liveTokens.contains(other))
        #expect(try rig.sessionStore.load() == nil && !rig.signIn.isSignedIn)
        #expect(rig.signIn.signedOutReason == nil, "the reader asked")
        #expect(rig.account.status == .signedOut)
        #expect(try await rig.keyStore.load() == key, "the key stays for signing back in")
        await #expect(throws: CloudServiceError.notSignedIn) { try await rig.destination.listSnapshots() }
        #expect(await rig.destination.availability() == .unavailable(reason: CloudServiceError.notSignedIn.localizedDescription))

        // Signing back in to the same account carries on.
        try await rig.signIn.signIn(with: .apple, anchor: nil)
        #expect(rig.signIn.accountID == W.account(1))
        for _ in 0..<200 where rig.account.hasKeyOnThisDevice == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.account.status == .active && rig.account.hasKeyOnThisDevice == true)
    }

    @Test func signingOutWorksEvenWhenTheServiceCantBeReached() async throws {
        let rig = try Rig.make(attestSupported: false) // no bypass: every request fails before it is sent
        defer { rig.cleanUp() }
        await rig.signIn.signOut()
        #expect(!rig.signIn.isSignedIn && rig.account.status == .signedOut)
    }

    @Test func signingOutEverywhereEndsEveryDevice() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        let other = rig.worker.addSession()
        try await rig.signIn.signOutEverywhere()
        #expect(rig.worker.liveTokens.isEmpty, "\(other) ended too")
        #expect(!rig.signIn.isSignedIn && rig.account.status == .signedOut)
    }

    @Test func signingOutEverywhereThatCantReachTheServiceChangesNothing() async throws {
        let rig = try Rig.make(attestSupported: false)
        defer { rig.cleanUp() }
        await #expect(throws: CloudServiceError.appAttestUnavailable) { try await rig.signIn.signOutEverywhere() }
        #expect(rig.signIn.isSignedIn, "still signed in, so the reader can try again")
    }

    @Test func aSessionEndedElsewhereSignsOutHereEverywhereItIsMet() async throws {
        let rig = try Rig.make(key: .generate())
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .active)

        rig.worker.endAllSessions()
        await rig.account.refresh()
        #expect(rig.account.status == .signedOut)
        #expect(rig.signIn.signedOutReason == .sessionEnded)
        #expect(try rig.sessionStore.load() == nil)

        // The account screen meets it too.
        try await rig.signIn.signIn(with: .apple, anchor: nil)
        rig.worker.endAllSessions()
        await rig.signIn.refreshAccount()
        #expect(!rig.signIn.isSignedIn && rig.signIn.signedOutReason == .sessionEnded)

        // And a backup that was about to start.
        try await rig.signIn.signIn(with: .apple, anchor: nil)
        for _ in 0..<200 where rig.account.status != .active { try await Task.sleep(for: .milliseconds(10)) }
        rig.worker.endAllSessions()
        let snapshot = try rig.snapshot()
        await #expect(throws: (any Error).self) {
            _ = try await rig.connection.currentSession(forceNew: true)
            try await rig.destination.uploadSnapshot(from: snapshot.url, name: snapshot.name, progress: nil)
        }
        #expect(!rig.signIn.isSignedIn && rig.account.status == .signedOut)
    }

    @Test func appleRevocationSignsOutAtLaunch() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.identity.appleEnded = true
        await rig.signIn.checkAppleAuthorization()
        #expect(!rig.signIn.isSignedIn && rig.signIn.signedOutReason == .appleRevoked)
        #expect(!rig.worker.liveTokens.contains(W.liveToken), "the service is told")

        // Google sessions are not Apple's to end.
        try await rig.signIn.signIn(with: .google, anchor: nil)
        await rig.signIn.checkAppleAuthorization()
        #expect(rig.signIn.isSignedIn)
    }

    // MARK: Deleting the account

    @Test func deletingTheAccountProvesTheSignInOnceThenRepeatsUntilDone() async throws {
        let key = BackupEncryptionKey.generate()
        let rig = try Rig.make(key: key)
        defer { rig.cleanUp() }
        for index in 0..<5 { rig.r2.put(BackupCloudServiceFixtures.key("Backups/\(index).ttenc"), Data([1])) }
        let other = rig.worker.addSession()
        var progress: [Int] = []
        try await rig.cloud.deleteAccount(anchor: nil) { progress.append($0) }

        #expect(rig.worker.accountDeleteCalls == 3, "batches of two until done")
        let calls = rig.worker.stub.requests("POST", pathPrefix: "/v1/account/delete")
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: String] }
        #expect(calls.count == 3)
        #expect(calls[0]["idToken"]?.hasPrefix("fake-id-token.apple.") == true && calls[0]["authorizationCode"] == "fake-code")
        #expect(calls.dropFirst().allSatisfy { $0["idToken"] == nil && $0["authorizationCode"] == nil },
                "later calls carry no sign-in")
        #expect(progress == [2, 4, 5])
        #expect(rig.r2.keys.isEmpty)
        #expect(!rig.worker.liveTokens.contains(other))
        #expect(rig.worker.accountsByIdentity["apple:reader"] == nil)
        #expect(!rig.signIn.isSignedIn && rig.signIn.signedOutReason == .accountDeleted)
        #expect(rig.account.status == .signedOut)
        #expect(try await rig.keyStore.load() == nil, "the account's key goes with it")
    }

    @Test func aCancelledConfirmationDeletesNothing() async throws {
        let key = BackupEncryptionKey.generate()
        let rig = try Rig.make(key: key)
        defer { rig.cleanUp() }
        rig.identity.cancelNext = true
        await #expect(throws: CloudSignInError.cancelled) { try await rig.cloud.deleteAccount(anchor: nil) }
        #expect(rig.worker.accountDeleteCalls == 0 && rig.signIn.isSignedIn)
        #expect(try await rig.keyStore.load() == key)
    }

    @Test func anInterruptedDeletionCarriesOnWithoutAnotherSignIn() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        for index in 0..<5 { rig.r2.put(BackupCloudServiceFixtures.key("PDFs/\(index).ttenc"), Data([1])) }
        rig.worker.deleteBatch = 0 // never finishes
        await #expect(throws: TactileCloudError.deletionUnfinished) { try await rig.cloud.deleteAccount(anchor: nil) }
        #expect(rig.signIn.isSignedIn)
        let signIns = rig.identity.requests.count
        rig.worker.deleteBatch = 10
        try await rig.cloud.deleteAccount(anchor: nil)
        #expect(rig.identity.requests.count == signIns, "the deletion had started: no second confirmation")
        #expect(!rig.signIn.isSignedIn)
    }

    // MARK: The key, per account

    @Test func theKeychainItemNamesTheAccount() {
        #expect(KeychainBackupKeyStore(service: "s", accountID: "0123abcd").account == "backup-encryption-key.0123abcd")
        let stores = KeychainBackupKeyStores(service: "s")
        #expect((stores.keyStore(forAccount: "a") as? KeychainBackupKeyStore)?.account
                != (stores.keyStore(forAccount: "b") as? KeychainBackupKeyStore)?.account)
    }

    @Test func anotherAccountOnThisIPadNeverUsesTheFirstAccountsKey() async throws {
        let first = BackupEncryptionKey.generate()
        let stores = InMemoryBackupKeyStores([W.account(1): first])
        let rig = try Rig.make(keyStores: stores)
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .active && rig.account.hasKeyOnThisDevice == true)
        let pdf = try rig.pdf()
        try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)

        // Out, and in to a different account (Google, another person) on the same iPad. The fake
        // keeps every account in one folder, so the new account sees the first one's data.
        await rig.signIn.signOut()
        rig.identity.subjects[.google] = "someone-else"
        try await rig.signIn.signIn(with: .google, anchor: nil)
        let second = try #require(rig.signIn.accountID)
        #expect(second != W.account(1))
        for _ in 0..<200 where rig.account.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.account.status == .needsRecoveryKey(.noKeyOnThisDevice), "the first account's key is not offered")
        #expect(try await stores.keyStore(forAccount: second).load() == nil, "and no new key is made over data")
        await #expect(throws: TactileCloudError.needsRecoveryKey(.noKeyOnThisDevice)) {
            try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil)
        }
        #expect(try await stores.keyStore(forAccount: W.account(1)).load() == first, "the first account's key is untouched")
    }

    // MARK: The purchase and the device label

    @Test func aPurchaseCarriesTheAccountsToken() async throws {
        let rig = try Rig.make(subscribed: false)
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .notSubscribed)
        let token = try #require(rig.signIn.appAccountToken)
        #expect(token == UUID(uuidString: W.appAccountToken))
        let transaction = BackupCloudServiceStoreFixtures.transaction(31, original: 31, purchased: -10, expires: 86_400)
        rig.store.nextPurchase = .success(.success(transaction))
        _ = try await rig.cloud.subscription.purchase(BackupCloudServiceStoreFixtures.productID, appAccountToken: token)
        #expect(rig.store.purchaseTokens == [token])
    }

    @Test(arguments: ["subscription-other-account", "subscription-in-use"])
    func aSubscriptionPayingForAnotherAccountIsExplained(code: String) async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        rig.worker.sessionFailure = .init(status: 403, code: code, subscription: nil)
        await rig.start()
        guard case .subscriptionElsewhere(let error) = rig.account.status else {
            Issue.record("status \(rig.account.status)")
            return
        }
        #expect(error.code == code)
        #expect(error.localizedDescription.contains("different Tactile Texts Cloud account"))
        #expect(CloudBackupPage.make(rig.account.status, hasError: false) == .status)
        #expect(CloudBackupBanner.make(rig.account.status, errorMessage: nil, usage: nil)?.message == error.localizedDescription)
    }

    @Test func theDeviceIsNamedOnlyOnceTheKeyExistsAndOnlyTheKeyOpensIt() async throws {
        let rig = try Rig.make()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.signIn.refreshAccount()
        #expect(rig.worker.label(of: W.liveToken) == nil, "no key yet, so no name sent")
        let current = try #require(rig.signIn.accountInfo?.devices.first { $0.isCurrent })
        #expect(rig.signIn.name(of: current) == "This iPad")

        let pdf = try rig.pdf()
        try await rig.destination.uploadPDF(from: pdf.url, sha256: pdf.sha256, size: pdf.size, progress: nil) // makes the key
        await rig.signIn.refreshAccount()
        let label = try #require(rig.worker.label(of: W.liveToken))
        #expect(!label.contains("Rig iPad"), "the service can't read it")
        let key = try #require(try await rig.keyStore.load())
        #expect(SyncKeys(key: key).openDeviceLabel(label) == "Rig iPad")
        let named = try #require(rig.signIn.accountInfo?.devices.first { $0.isCurrent })
        #expect(rig.signIn.name(of: named) == "Rig iPad")
        let other = BackupServiceDevice(sessionID: "x", createdAt: nil, lastUsedAt: nil, label: "junk", isCurrent: false)
        #expect(rig.signIn.name(of: other) == "Another device")
    }

    // MARK: Automatic backup's default

    @Test func automaticBackupIsOnByDefaultForASignedInSubscriberOnly() async throws {
        let suite = "CloudDefault-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BackupAutomaticSettings(defaults: defaults)
        let rig = try Rig.make(subscribed: false)
        defer { rig.cleanUp() }
        rig.account.onActiveSubscriber = { settings.applyDefault(destinationID: TactileCloudBackupDestination.destinationID) }

        await rig.start()
        #expect(rig.account.status == .notSubscribed && !settings.isEnabled, "not for an account without a subscription")
        rig.worker.hasSubscription = true
        await rig.account.refresh()
        #expect(rig.account.status == .active)
        #expect(settings.isEnabled && settings.destinationID == TactileCloudBackupDestination.destinationID)

        // A reader who turns it off is left alone.
        settings.isEnabled = false
        await rig.account.refresh()
        #expect(!settings.isEnabled)
    }

    @Test func theDefaultLeavesAReaderWhoSetUpAutomaticBackups() throws {
        func settings(_ setUp: (BackupAutomaticSettings) -> Void) throws -> BackupAutomaticSettings {
            let suite = "CloudDefault-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let made = BackupAutomaticSettings(defaults: defaults)
            setUp(made)
            return BackupAutomaticSettings(defaults: defaults)
        }
        let fresh = try settings { _ in }
        #expect(fresh.applyDefault(destinationID: "tactile-cloud") && fresh.isEnabled)
        let turnedOff = try settings { $0.isEnabled = false }
        #expect(!turnedOff.applyDefault(destinationID: "tactile-cloud") && !turnedOff.isEnabled)
        let elsewhere = try settings { $0.destinationID = "folder"; $0.isEnabled = true }
        #expect(!elsewhere.applyDefault(destinationID: "tactile-cloud") && elsewhere.destinationID == "folder")
    }
}
