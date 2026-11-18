import Foundation
import Testing
@testable import TactileTexts

/// Development sign-in (debug builds with `BACKUP_SERVICE_DEV_SIGNIN`): the named test user
/// (`DevTestUser`), and an account the `dev` Worker serves as entitled (its dev test
/// entitlement) with no App Store purchase and no App Store product on the device.
@MainActor
struct DevTestCloudSignInTests {
    typealias Rig = BackupCloudServiceRig
    typealias S = BackupCloudServiceStoreFixtures
    static let secret = "a-dev-test-secret-of-at-least-32-characters"

    private final class Suites {
        var names: [String] = []
        func make() -> UserDefaults {
            let name = "DevTestUser-\(UUID().uuidString)"
            names.append(name)
            return UserDefaults(suiteName: name)!
        }
        deinit { for name in names { UserDefaults().removePersistentDomain(forName: name) } }
    }

    /// The `sub` claim of a dev test token.
    static func subject(of token: String) throws -> String {
        let part = try #require(token.split(separator: ".").dropFirst().first.map(String.init))
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try #require(Data(base64Encoded: base64))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["sub"] as? String)
    }

    static func provider(_ user: DevTestUser) -> DevTestCloudIdentityProvider {
        DevTestCloudIdentityProvider(secret: secret, audience: "software.tactile.texts", user: user)
    }

    static func tokenSubject(_ user: DevTestUser) async throws -> String {
        try subject(of: try await provider(user).credential(.apple, nonce: "n", anchor: nil).idToken)
    }

    // MARK: The named test user

    @Test func theSameNameIsTheSameSubjectOnEveryDevice() async throws {
        let suites = Suites()
        let first = DevTestUser(buildName: "alice", defaults: suites.make())
        let second = DevTestUser(buildName: "alice", defaults: suites.make())
        #expect(first.subject == second.subject)
        #expect(try await Self.tokenSubject(first) == (try await Self.tokenSubject(second)))
        #expect(try await Self.tokenSubject(first) == "dev-user:alice")
        // Spelled differently, the same user.
        #expect(DevTestUser(buildName: " Alice ", defaults: suites.make()).subject == first.subject)
        #expect(DevTestUser(buildName: "ALICE", defaults: suites.make()).subject == first.subject)
        // Both stand-ins sign in as the same test user (the Worker keeps Apple's and Google's apart).
        let google = try await Self.provider(first).credential(.google, nonce: "n", anchor: nil)
        #expect(try Self.subject(of: google.idToken) == "dev-user:alice")
        #expect(google.email == "alice@dev-test.invalid")
    }

    @Test func anotherNameIsAnotherSubject() async throws {
        let suites = Suites()
        let alice = DevTestUser(buildName: "alice", defaults: suites.make())
        let bob = DevTestUser(buildName: "bob", defaults: suites.make())
        #expect(alice.subject != bob.subject)
        #expect(try await Self.tokenSubject(alice) != (try await Self.tokenSubject(bob)))
    }

    @Test func theBuildSettingNamesTheUserAndDefaultsToDev() throws {
        let suites = Suites()
        func user(_ values: [String: String]) throws -> DevTestUser? {
            var service = ["Host": "localhost:8787", "ProductIDs": S.productID]
            service.merge(values) { $1 }
            let configuration = try #require(BackupServiceConfiguration.fromInfoDictionary(["BackupService": service]))
            return (TactileCloudBackup.identityProvider(for: configuration, defaults: suites.make())
                as? DevTestCloudIdentityProvider)?.user
        }
        #expect(try user([:]) == nil, "no dev sign-in, no test user")
        #expect(try user(["DevUser": "reader"]) == nil, "a name alone turns nothing on")
        #expect(try user(["DevSignIn": Self.secret])?.name == "dev")
        #expect(try user(["DevSignIn": Self.secret, "DevUser": "$(BACKUP_SERVICE_DEV_USER)"])?.name == "dev")
        #expect(try user(["DevSignIn": Self.secret, "DevUser": "Reader Two"])?.name == "reader-two")
        #expect(try user(["DevSignIn": Self.secret, "DevUser": "  "])?.name == "dev")
    }

    @Test func theNameChosenAtSignInIsKeptAndResetStateClearsIt() async throws {
        let suites = Suites()
        let defaults = suites.make()
        defaults.set("simulator-0000", forKey: DevTestUser.legacySubjectKey)
        let user = DevTestUser(buildName: "dev", defaults: defaults)
        let provider = Self.provider(user)
        #expect(user.name == "dev" && user.chosenName == nil)
        user.setName("Second Sim")
        #expect(user.name == "second-sim" && user.subject == "dev-user:second-sim")
        // The provider signs in as the name at the moment of signing in.
        #expect(try Self.subject(of: try await provider.credential(.apple, nonce: "n", anchor: nil).idToken) == "dev-user:second-sim")
        // Kept across launches.
        #expect(DevTestUser(buildName: "dev", defaults: defaults).name == "second-sim")
        // Empty, unusable or the build's own name: back to the build's.
        user.setName("!!!")
        #expect(user.name == "dev" && defaults.string(forKey: DevTestUser.defaultsKey) == nil)
        user.setName("third")
        user.setName("DEV")
        #expect(user.chosenName == nil && defaults.string(forKey: DevTestUser.defaultsKey) == nil)
        // `-resetState` (AppEnvironment.makeLive) clears the choice and the old per-install subject.
        user.setName("fourth")
        DevTestUser.reset(in: defaults)
        #expect(defaults.string(forKey: DevTestUser.defaultsKey) == nil)
        #expect(defaults.string(forKey: DevTestUser.legacySubjectKey) == nil)
        #expect(DevTestUser(buildName: "dev", defaults: defaults).name == "dev")
    }

    @Test(arguments: [
        ("dev", "dev"), (" Dev ", "dev"), ("Reader  Two", "reader-two"), ("a.b_c-d@e", "a.b_c-d@e"),
        ("tab\there", "tab-here"), ("émile", "mile"),
    ])
    func namesAreNormalized(raw: String, expected: String) {
        #expect(DevTestUser.normalized(raw) == expected)
    }

    @Test func emptyAndOverlongNames() {
        #expect(DevTestUser.normalized("") == nil)
        #expect(DevTestUser.normalized(" \n ") == nil)
        #expect(DevTestUser.normalized("✓✓") == nil)
        #expect(DevTestUser.normalized(String(repeating: "a", count: 200))?.count == DevTestUser.maxLength)
    }

    @Test func theServiceExposesTheTestUserOnlyWithDevSignIn() throws {
        let suites = Suites()
        let configuration = try #require(BackupServiceConfiguration(host: "localhost:8787", productIDs: S.productID))
        let user = DevTestUser(buildName: "dev", defaults: suites.make())
        let rig = try Rig.make(signedIn: false)
        defer { rig.cleanUp() }
        #expect(rig.cloud.devTestUser == nil, "the real providers (here a fake) have no test user")
        let dev = TactileCloudBackup.make(configuration: configuration, store: rig.store, attest: rig.attest,
                                          keyStore: rig.keyStore, sessionStore: InMemoryCloudDeviceSessionStore(),
                                          identity: Self.provider(user), defaults: suites.make())
        #expect(dev.devTestUser === user)
        #expect(dev.signIn.availableProviders == [.apple, .google])
    }

    // MARK: An account the Worker says is entitled, with no purchase here

    /// The `dev` Worker's dev test entitlement, as the session describes it.
    static var devEntitlement: [String: Any] { [
        "state": "active", "environment": "Xcode", "productId": S.productID,
        "expiresAt": "2027-02-15T00:00:00.000Z", "endedAt": NSNull(), "readOnlyUntil": NSNull(), "deleteAfter": NSNull(),
    ] }

    /// Signed in, no purchase and no transaction on this device, the App Store offering nothing,
    /// and the Worker granting a session anyway.
    func entitledRig(productsError: BackupSubscriptionError? = nil) throws -> Rig {
        let rig = try Rig.make(subscribed: false)
        rig.worker.hasSubscription = true
        rig.worker.subscription = Self.devEntitlement
        rig.store.products = []
        rig.store.productsError = productsError
        return rig
    }

    @Test func anAccountTheWorkerEntitlesNeedsNoPurchaseAndNoProduct() async throws {
        let rig = try entitledRig()
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.cloud.subscription.state == .unavailable(.productsNotFound))
        #expect(await rig.cloud.subscription.signedTransaction() == nil)
        #expect(rig.account.status == .active)
        #expect(rig.account.accessMode == .readWrite)
        #expect(rig.account.subscriptionInfo?.environment == "Xcode")
        // The page shows the status, with Sync, and a plan named after the service (no product).
        #expect(CloudBackupPage.make(rig.account.status, hasError: rig.account.lastError != nil) == .status)
        #expect(SyncAvailability.showsSection(rig.account.status))
        #expect(rig.account.plan?.productID == S.productID && rig.account.plan?.product == nil)
        #expect(CloudBackupStatusText.planName(rig.account.plan) == CloudServiceError.serviceName)
        #expect(CloudBackupStatusText.renewalLine(rig.cloud.subscription.state) == nil)
        #expect(await rig.destination.availability() == .available)
        // The session was asked for with no transaction.
        let sent = try #require(rig.worker.stub.requests("POST", pathPrefix: "/v1/session").first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: String])
        #expect(body["signedTransaction"] == nil)
        // A backup goes through, and makes the key.
        let snapshot = try rig.snapshot()
        _ = try await rig.destination.uploadSnapshot(from: snapshot.url, name: snapshot.name, progress: nil)
        #expect(rig.account.hasKeyOnThisDevice == true)
        #expect(try await rig.destination.listSnapshots().map(\.name) == [snapshot.name])
    }

    @Test func anEntitledAccountIsActiveEvenWhenTheAppStoreCannotBeReached() async throws {
        let rig = try entitledRig(productsError: .networkUnavailable)
        defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.account.status == .active)
    }

    @Test func withoutTheEntitlementAndNoProductTheOfferSaysTheStoreIsUnavailable() async throws {
        let rig = try entitledRig()
        defer { rig.cleanUp() }
        rig.worker.hasSubscription = false
        await rig.start()
        let reason = BackupSubscriptionError.productNotFound.localizedDescription
        #expect(rig.account.status == .storeUnavailable(reason: reason))
        #expect(CloudBackupPage.make(rig.account.status, hasError: false) == .offer)
        #expect(!rig.account.isRefreshing)
    }
}
