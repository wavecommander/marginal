import Foundation
import Testing
@testable import TactileTexts

/// `BackupSubscription` with a scripted StoreKit: every state and transition, and the signed
/// transaction handed to the backup service.
@MainActor
struct BackupCloudServiceSubscriptionTests {
    typealias S = BackupCloudServiceStoreFixtures

    static let day: TimeInterval = 86_400

    func make(_ store: BackupCloudServiceFakeStore, ids: [String] = [S.productID]) -> BackupSubscription {
        BackupSubscription(productIDs: ids, store: store, now: { S.now })
    }

    func storeWithProduct() -> BackupCloudServiceFakeStore {
        let store = BackupCloudServiceFakeStore()
        store.products = [S.product]
        return store
    }

    var plan: BackupSubscription.Plan { .init(productID: S.productID, product: S.product) }

    /// Waits until `condition` holds (the update listener runs on its own task).
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Loading and unavailable

    @Test func notConfigured() async {
        let store = BackupCloudServiceFakeStore()
        let model = make(store, ids: [])
        #expect(model.state == .unavailable(.notConfigured))
        await model.load()
        #expect(model.state == .unavailable(.notConfigured))
        #expect(!store.isListening)
        await #expect(throws: BackupSubscriptionError.notConfigured) { _ = try await model.purchase(S.productID) }
        #expect(await model.signedTransaction() == nil)
        let unconfigured = BackupSubscription(configuration: nil)
        #expect(unconfigured.state == .unavailable(.notConfigured))
        #expect(unconfigured.productIDs.isEmpty)
    }

    @Test func loadingThenNotSubscribed() async {
        let store = storeWithProduct()
        let model = make(store)
        #expect(model.state == .loading)
        #expect(store.isListening)
        await model.load()
        #expect(model.state == .notSubscribed)
        #expect(model.products == [S.product])
    }

    @Test func productsTheStoreDoesNotKnowAreUnavailable() async {
        let store = BackupCloudServiceFakeStore()
        let model = make(store)
        await model.load()
        #expect(model.state == .unavailable(.productsNotFound))
        #expect(!BackupSubscription.UnavailableReason.productsNotFound.message.isEmpty)
    }

    @Test func productsThatFailToLoadAreUnavailableUnlessTheHistoryShowsASubscription() async {
        let store = storeWithProduct()
        store.productsError = .networkUnavailable
        let model = make(store)
        await model.load()
        #expect(model.state == .unavailable(.storeUnavailable(.networkUnavailable)))
        #expect(BackupSubscription.UnavailableReason.storeUnavailable(.networkUnavailable).message
                    == BackupSubscriptionError.networkUnavailable.localizedDescription)

        // Offline but subscribed: the cached transactions still say so (no statuses without a group).
        store.history = [S.transaction(1, purchased: -5 * Self.day, expires: 25 * Self.day)]
        await model.load()
        #expect(model.state == .subscribed(.init(productID: S.productID, product: nil),
                                           renewsOrExpires: S.now.addingTimeInterval(25 * Self.day), willRenew: false))
    }

    @Test func productsKeepTheConfiguredOrder() async {
        let store = BackupCloudServiceFakeStore()
        let other = BackupStoreProduct(id: S.otherProductID, displayName: "Large", displayPrice: "£5.99",
                                       subscriptionGroupID: S.groupID, period: .init(value: 1, unit: .year))
        store.products = [other, S.product]
        let model = make(store, ids: [S.productID, S.otherProductID])
        await model.load()
        #expect(model.products.map(\.id) == [S.productID, S.otherProductID])
    }

    // MARK: Purchase

    @Test func purchaseSuccessMakesTheStateSubscribed() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        let transaction = S.transaction(10, original: 10, purchased: 0, expires: 30 * Self.day)
        store.nextPurchase = .success(.success(transaction))
        store.statuses = [S.status(.subscribed, transaction, willRenew: true)]
        #expect(try await model.purchase(S.productID) == .purchased)
        #expect(store.purchases == [S.productID])
        #expect(store.finished == [10])
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(30 * Self.day), willRenew: true))
    }

    @Test func purchaseCancelledChangesNothing() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        store.nextPurchase = .success(.userCancelled)
        #expect(try await model.purchase(S.productID) == .cancelled)
        store.nextPurchase = .failure(CancellationError())
        #expect(try await model.purchase(S.productID) == .cancelled)
        #expect(model.state == .notSubscribed)
        #expect(store.finished.isEmpty)
    }

    @Test func purchasePendingThenApprovedThroughUpdates() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        store.nextPurchase = .success(.pending)
        #expect(try await model.purchase(S.productID) == .pending)
        #expect(model.state == .notSubscribed)
        // Ask to Buy approved later: the transaction arrives through the updates.
        let approved = S.transaction(11, original: 11, purchased: 60, expires: 30 * Self.day)
        store.statuses = [S.status(.subscribed, approved, willRenew: true)]
        store.send(approved)
        await eventually { model.state != .notSubscribed }
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(30 * Self.day), willRenew: true))
        #expect(store.finished == [11])
    }

    @Test func purchaseFailingVerificationUnlocksNothing() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        let forged = S.transaction(12, original: 12, purchased: 0, expires: 30 * Self.day, verified: false)
        store.nextPurchase = .success(.success(forged))
        store.statuses = [S.status(.subscribed, forged, willRenew: true)]
        await #expect(throws: BackupSubscriptionError.verificationFailed) { _ = try await model.purchase(S.productID) }
        #expect(model.state == .notSubscribed)
        #expect(store.finished.isEmpty)
        #expect(await model.signedTransaction() == nil)
    }

    @Test func purchaseErrorsAndUnknownProducts() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        store.nextPurchase = .failure(BackupSubscriptionError.purchasesNotAllowed)
        await #expect(throws: BackupSubscriptionError.purchasesNotAllowed) { _ = try await model.purchase(S.productID) }
        await #expect(throws: BackupSubscriptionError.productNotFound) { _ = try await model.purchase("com.example.other") }
        #expect(store.purchases == [S.productID])
    }

    // MARK: Updates, renewal, expiry

    @Test func renewalArrivesThroughUpdates() async throws {
        let store = storeWithProduct()
        let first = S.transaction(20, original: 20, purchased: -29 * Self.day, expires: Self.day)
        store.history = [first]
        store.statuses = [S.status(.subscribed, first, willRenew: true)]
        let model = make(store)
        await model.load()
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(Self.day), willRenew: true))

        let renewal = S.transaction(21, original: 20, purchased: Self.day, expires: 31 * Self.day)
        store.statuses = [S.status(.subscribed, renewal, willRenew: true)]
        store.send(renewal)
        await eventually { store.finished == [21] }
        await eventually { model.state != .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(Self.day), willRenew: true) }
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(31 * Self.day), willRenew: true))
        #expect(await model.signedTransaction()?.transactionID == 21)
    }

    @Test func turningOffRenewalShowsWillNotRenew() async {
        let store = storeWithProduct()
        let current = S.transaction(30, original: 30, purchased: -Self.day, expires: 29 * Self.day)
        store.history = [current]
        store.statuses = [S.status(.subscribed, current, willRenew: false)]
        let model = make(store)
        await model.load()
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(29 * Self.day), willRenew: false))
        // Unverified renewal info: not trusted to say it renews.
        store.statuses = [S.status(.subscribed, current, willRenew: nil)]
        await model.refresh()
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(29 * Self.day), willRenew: false))
    }

    @Test func graceAndBillingRetryCountAsSubscribed() async {
        for state in [BackupStoreSubscriptionStatus.State.inGracePeriod, .inBillingRetryPeriod] {
            let store = storeWithProduct()
            let lapsed = S.transaction(40, original: 40, purchased: -31 * Self.day, expires: -Self.day)
            store.history = [lapsed]
            store.statuses = [S.status(state, lapsed, willRenew: true)]
            let model = make(store)
            await model.load()
            #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(-Self.day), willRenew: true), "\(state)")
        }
    }

    @Test func expiryMakesTheStateEndedAndTheSignedTransactionStaysAvailable() async throws {
        let store = storeWithProduct()
        let first = S.transaction(50, original: 50, purchased: -60 * Self.day, expires: -30 * Self.day)
        let last = S.transaction(51, original: 50, purchased: -30 * Self.day, expires: -Self.day)
        store.history = [first, last]
        store.statuses = [S.status(.expired, last, willRenew: false)]
        let model = make(store)
        await model.load()
        #expect(model.state == .ended(plan, endedAt: S.now.addingTimeInterval(-Self.day)))
        let signed = try #require(await model.signedTransaction())
        #expect(signed.jws == S.jws(51))
        #expect(signed.transactionID == 51 && signed.originalTransactionID == 50 && signed.productID == S.productID)
        #expect(signed.expirationDate == S.now.addingTimeInterval(-Self.day))
    }

    @Test func expiryWhileRunningMovesFromSubscribedToEnded() async {
        let store = storeWithProduct()
        let current = S.transaction(52, original: 52, purchased: -29 * Self.day, expires: Self.day)
        store.history = [current]
        store.statuses = [S.status(.subscribed, current, willRenew: false)]
        let model = make(store)
        await model.load()
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(Self.day), willRenew: false))
        store.statuses = [S.status(.expired, current, willRenew: false)]
        await model.refresh()
        #expect(model.state == .ended(plan, endedAt: S.now.addingTimeInterval(Self.day)))
    }

    @Test func aRefundEndsItAtTheRevocation() async {
        let store = storeWithProduct()
        let refunded = S.transaction(60, original: 60, purchased: -2 * Self.day, expires: 28 * Self.day, revoked: -Self.day)
        store.history = [refunded]
        store.statuses = [S.status(.revoked, refunded, willRenew: false)]
        let model = make(store)
        await model.load()
        #expect(model.state == .ended(plan, endedAt: S.now.addingTimeInterval(-Self.day)))
        // Without statuses, the dates decide the same.
        store.statuses = nil
        await model.refresh()
        #expect(model.state == .ended(plan, endedAt: S.now.addingTimeInterval(-Self.day)))
    }

    @Test func unverifiedTransactionsAreIgnoredAndNotFinished() async {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        let forged = S.transaction(70, original: 70, purchased: 0, expires: 30 * Self.day, verified: false)
        store.statuses = nil
        store.send(forged)
        try? await Task.sleep(for: .milliseconds(300)) // give the listener time
        #expect(model.state == .notSubscribed)
        #expect(store.finished.isEmpty)
        #expect(await model.signedTransaction() == nil)
    }

    @Test func updatesForOtherProductsAreLeftAlone() async {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        store.send(S.transaction(80, original: 80, product: "software.tactile.texts.tip", purchased: 0, expires: nil))
        store.send(S.transaction(81, original: 81, purchased: 0, expires: 30 * Self.day))
        await eventually { store.finished == [81] }
        #expect(store.finished == [81])
    }

    // MARK: Restore

    @Test func restoreFindsAPurchaseMadeElsewhere() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        #expect(model.state == .notSubscribed)
        let elsewhere = S.transaction(90, original: 90, purchased: -3 * Self.day, expires: 27 * Self.day)
        store.syncResult = .success([elsewhere])
        store.statuses = [S.status(.subscribed, elsewhere, willRenew: true)]
        try await model.restore()
        #expect(store.syncs == 1)
        #expect(model.state == .subscribed(plan, renewsOrExpires: S.now.addingTimeInterval(27 * Self.day), willRenew: true))
    }

    @Test func restoreCancelledOrFailing() async throws {
        let store = storeWithProduct()
        let model = make(store)
        await model.load()
        store.syncResult = .failure(CancellationError())
        try await model.restore()
        #expect(model.state == .notSubscribed)
        store.syncResult = .failure(BackupSubscriptionError.networkUnavailable)
        await #expect(throws: BackupSubscriptionError.networkUnavailable) { try await model.restore() }
    }

    // MARK: The signed transaction

    @Test func theSignedTransactionIsTheNewestVerifiedOneEvenWhenExpired() async throws {
        let store = storeWithProduct()
        let model = make(store)
        store.history = [
            S.transaction(100, original: 100, purchased: -90 * Self.day, expires: -60 * Self.day),
            S.transaction(102, original: 100, purchased: -30 * Self.day, expires: -2 * Self.day),
            S.transaction(101, original: 100, purchased: -60 * Self.day, expires: -30 * Self.day),
            // Newer, but unverified: never used.
            S.transaction(103, original: 100, purchased: -Self.day, expires: 29 * Self.day, verified: false),
            // Another app's product: not ours.
            S.transaction(104, original: 104, product: "software.tactile.texts.tip", purchased: 0, expires: nil),
        ]
        await model.load()
        #expect(model.state == .ended(plan, endedAt: S.now.addingTimeInterval(-2 * Self.day)))
        let signed = try #require(await model.signedTransaction())
        #expect(signed.transactionID == 102)
        #expect(signed.jws == S.jws(102))
        // Same purchase date: the higher ID wins.
        store.history.append(S.transaction(105, original: 100, purchased: -30 * Self.day, expires: -2 * Self.day))
        #expect(await model.signedTransaction()?.transactionID == 105)
    }

    @Test func entitlementRules() {
        let ids: Set = [S.productID]
        let active = S.transaction(1, purchased: -Self.day, expires: 29 * Self.day)
        let upgraded = BackupStoreTransaction(id: 2, originalID: 1, productID: S.productID, purchaseDate: S.now,
                                              expirationDate: S.now.addingTimeInterval(Self.day), isUpgraded: true,
                                              isVerified: true, jwsRepresentation: "x")
        #expect(BackupSubscription.entitlement(productIDs: ids, transactions: [active], statuses: nil, now: S.now)
                    == .active(productID: S.productID, until: S.now.addingTimeInterval(29 * Self.day), willRenew: false))
        #expect(BackupSubscription.entitlement(productIDs: ids, transactions: [upgraded], statuses: nil, now: S.now)
                    == .ended(productID: S.productID, at: S.now.addingTimeInterval(Self.day)))
        #expect(BackupSubscription.entitlement(productIDs: ids, transactions: [], statuses: [], now: S.now) == .none)
        // Statuses known and none active: the dates are not consulted.
        #expect(BackupSubscription.entitlement(productIDs: ids, transactions: [active],
                                               statuses: [S.status(.expired, active)], now: S.now)
                    == .ended(productID: S.productID, at: S.now.addingTimeInterval(29 * Self.day)))
        // An unverified status is not trusted.
        let forged = S.transaction(3, purchased: 0, expires: 30 * Self.day, verified: false)
        #expect(BackupSubscription.entitlement(productIDs: ids, transactions: [forged],
                                               statuses: [S.status(.subscribed, forged)], now: S.now) == .none)
    }

    // MARK: Secrets

    @Test func noSignedTransactionInDescriptions() async throws {
        let transaction = S.transaction(7, purchased: 0, expires: Self.day)
        let signed = BackupSignedTransaction(jws: transaction.jwsRepresentation, productID: S.productID, transactionID: 7,
                                             originalTransactionID: 7, expirationDate: nil)
        var texts = [String(describing: transaction), String(reflecting: transaction), String(describing: signed),
                     String(reflecting: signed), "\(BackupStorePurchaseResult.success(transaction))",
                     "\(S.status(.subscribed, transaction))", "\(BackupSubscription.State.subscribed(plan, renewsOrExpires: nil, willRenew: true))"]
        for value in [transaction, signed] as [Any] {
            var dumped = ""
            dump(value, to: &dumped)
            texts.append(dumped)
        }
        let errors: [BackupSubscriptionError] = [.notConfigured, .productNotFound, .verificationFailed, .networkUnavailable,
                                                 .purchasesNotAllowed, .storeFailed(code: "x")]
        texts += errors.map(\.localizedDescription)
        for text in texts {
            #expect(!text.contains("must-not-leak"), "shows the JWS: \(text)")
            #expect(!text.contains("eyJ"), "shows the JWS: \(text)")
        }
    }
}
