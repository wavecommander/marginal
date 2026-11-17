import Foundation
import Observation
import UIKit

/// The signed App Store transaction that identifies the reader's subscription to the backup
/// service. The JWS never appears in a description, debug description or mirror.
nonisolated struct BackupSignedTransaction: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The compact JWS the App Store signed, to send to the service as is.
    let jws: String
    let productID: String
    let transactionID: UInt64
    let originalTransactionID: UInt64
    /// When it expires (or expired); the service decides what an expired one still allows.
    let expirationDate: Date?
    /// The subscription's renewal info as the App Store signed it, when StoreKit has it verified
    /// (it lets the service count Apple's grace and billing-retry periods). Never described.
    var signedRenewalInfo: String? = nil

    var description: String {
        "BackupSignedTransaction(product: \(productID), transaction: \(transactionID), "
            + "expires: \(expirationDate.map { "\($0)" } ?? "never"), jws: <redacted>, "
            + "renewalInfo: \(signedRenewalInfo == nil ? "none" : "<redacted>"))"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["productID": productID, "transactionID": transactionID,
                                "expirationDate": expirationDate as Any, "jws": "<redacted>",
                                "signedRenewalInfo": signedRenewalInfo == nil ? "none" : "<redacted>"], displayStyle: .struct)
    }
}

/// The reader's subscription to Tactile Texts Cloud Backup, through StoreKit: the products on
/// offer, buying and restoring, and a small state for the UI and the backup service client.
///
/// - Listens for transaction updates (renewals, purchases on other devices, refunds, and those
///   left unfinished at the last launch) from creation until it is released, finishing verified
///   ones for its products and refreshing the state.
/// - Unverified transactions are never trusted: they do not make the reader subscribed, are not
///   handed to the service, and are not finished.
/// - `signedTransaction()` is the newest verified transaction for a backup product, **expired
///   ones included**: the service lets an ended subscription restore (read only) for a while,
///   so an ended subscriber still needs to say who they are.
@MainActor @Observable
final class BackupSubscription {
    /// Who the subscription is with: the product ID, and the product when the App Store
    /// described it.
    struct Plan: Hashable, Sendable {
        let productID: String
        let product: BackupStoreProduct?
    }

    enum UnavailableReason: Hashable, Sendable {
        /// This build sells no backup subscription (no product IDs configured).
        case notConfigured
        /// The App Store does not know the configured products.
        case productsNotFound
        /// The products could not be loaded (`error` says why: network, store failure).
        case storeUnavailable(BackupSubscriptionError)

        /// Reader-facing.
        var message: String {
            switch self {
            case .notConfigured: BackupSubscriptionError.notConfigured.localizedDescription
            case .productsNotFound: BackupSubscriptionError.productNotFound.localizedDescription
            case .storeUnavailable(let error): error.localizedDescription
            }
        }
    }

    enum State: Hashable, Sendable {
        /// The first load has not finished.
        case loading
        /// Nothing can be bought or shown (see the reason).
        case unavailable(UnavailableReason)
        /// The products are on offer and the reader has never subscribed (on this Apple ID).
        case notSubscribed
        /// Active (including a grace or billing-retry period). `renewsOrExpires` is the end of
        /// the current period; `willRenew` says whether it renews then.
        case subscribed(Plan, renewsOrExpires: Date?, willRenew: Bool)
        /// The reader subscribed once and it has ended (expired or refunded) at `endedAt`.
        case ended(Plan, endedAt: Date?)
    }

    /// What `purchase` did.
    enum PurchaseOutcome: Hashable, Sendable {
        case purchased
        case cancelled
        /// Waiting for approval (Ask to Buy); the state changes when it arrives.
        case pending
    }

    private(set) var state: State = .loading
    /// The configured products the App Store offers, in the configured order.
    private(set) var products: [BackupStoreProduct] = []

    /// The configured product IDs (empty: not configured).
    let productIDs: [String]
    @ObservationIgnored private let store: any BackupStoreKit
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var productsError: BackupSubscriptionError?
    @ObservationIgnored private var productsLoaded = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private nonisolated(unsafe) var listener: Task<Void, Never>?

    /// - Parameters:
    ///   - productIDs: the backup products (`BackupServiceConfiguration.productIDs`); empty when
    ///     the build has none, and the state is then `unavailable(.notConfigured)`.
    ///   - store: StoreKit, or a fake in tests.
    ///   - now: the clock expiry is judged by.
    init(productIDs: [String], store: any BackupStoreKit, now: @escaping () -> Date = { Date() }) {
        self.productIDs = productIDs
        self.store = store
        self.now = now
        if productIDs.isEmpty {
            state = .unavailable(.notConfigured)
        } else {
            startListening()
        }
    }

    /// The model for this build: the configured products, through the App Store.
    convenience init(configuration: BackupServiceConfiguration?) {
        self.init(productIDs: configuration?.productIDs ?? [], store: AppStoreBackupStore())
    }

    deinit {
        listener?.cancel()
    }

    // MARK: Loading

    /// Loads the products and works out the state. Call when the backup screens first need it;
    /// calling again reloads.
    func load() async {
        guard !productIDs.isEmpty else { return }
        do {
            let loaded = try await store.products(for: productIDs)
            products = productIDs.compactMap { id in loaded.first { $0.id == id } }
            productsError = nil
        } catch {
            productsError = error as? BackupSubscriptionError ?? .storeFailed(code: "products")
        }
        productsLoaded = true
        await refresh()
    }

    /// Works the state out again from the App Store's transactions and statuses (the products
    /// as last loaded).
    func refresh() async {
        guard !productIDs.isEmpty else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let ids = Set(productIDs)
        let transactions = await store.transactions(for: ids)
        var statuses: [BackupStoreSubscriptionStatus] = []
        var statusesKnown = false
        for groupID in Set(products.compactMap(\.subscriptionGroupID)) {
            if let found = try? await store.subscriptionStatuses(groupID: groupID) {
                statuses += found
                statusesKnown = true
            }
        }
        guard generation == refreshGeneration else { return } // a newer refresh is under way
        let entitlement = Self.entitlement(productIDs: ids, transactions: transactions,
                                           statuses: statusesKnown ? statuses : nil, now: now())
        state = resolve(entitlement)
    }

    // MARK: Buying

    /// Buys `productID`, showing the confirmation in `scene` when given (pass the window scene
    /// the request came from; the app has several).
    ///
    /// - Returns: `.purchased` (the state is then subscribed), `.cancelled`, or `.pending`.
    /// - Throws: `BackupSubscriptionError` (`verificationFailed` when the App Store's signature
    ///   did not verify: nothing is unlocked and the transaction is not finished).
    func purchase(_ productID: String, appAccountToken: UUID? = nil, confirmIn scene: UIScene? = nil) async throws -> PurchaseOutcome {
        guard productIDs.contains(productID) else {
            throw productIDs.isEmpty ? BackupSubscriptionError.notConfigured : BackupSubscriptionError.productNotFound
        }
        let result: BackupStorePurchaseResult
        do {
            result = try await store.purchase(productID: productID, appAccountToken: appAccountToken, confirmIn: scene)
        } catch is CancellationError {
            return .cancelled
        }
        switch result {
        case .success(let transaction):
            guard transaction.isVerified else {
                await refresh()
                throw BackupSubscriptionError.verificationFailed
            }
            await store.finish(transaction)
            await refresh()
            return .purchased
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        }
    }

    /// Restore Purchases: asks the App Store for the reader's transactions (it may ask them to
    /// sign in), then refreshes the state.
    func restore() async throws {
        do {
            try await store.sync()
        } catch is CancellationError {
            // The reader cancelled the sign-in.
        }
        await refresh()
    }

    // MARK: For the backup service

    /// The newest verified transaction for a backup product, expired or not, to identify the
    /// reader to the backup service; `nil` when there is none (never subscribed, or only
    /// unverified transactions). Carries the subscription's verified renewal info when StoreKit
    /// reports a status for it (the products must have been loaded for their group).
    func signedTransaction() async -> BackupSignedTransaction? {
        guard !productIDs.isEmpty else { return nil }
        let transactions = await store.transactions(for: Set(productIDs))
        guard let newest = Self.newestVerified(transactions, productIDs: Set(productIDs)) else { return nil }
        var signed = BackupSignedTransaction(jws: newest.jwsRepresentation, productID: newest.productID, transactionID: newest.id,
                                             originalTransactionID: newest.originalID, expirationDate: newest.expirationDate)
        for groupID in Set(products.compactMap(\.subscriptionGroupID)) {
            guard let statuses = try? await store.subscriptionStatuses(groupID: groupID) else { continue }
            if let renewal = statuses.first(where: {
                $0.transaction.originalID == newest.originalID && $0.transaction.isVerified && $0.renewalInfoJWS != nil
            })?.renewalInfoJWS {
                signed.signedRenewalInfo = renewal
                break
            }
        }
        return signed
    }

    // MARK: - Internals

    private func startListening() {
        let updates = store.transactionUpdates()
        listener = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.handle(transaction)
            }
        }
    }

    private func handle(_ transaction: BackupStoreTransaction) async {
        guard productIDs.contains(transaction.productID) else { return }
        if transaction.isVerified { await store.finish(transaction) }
        await refresh()
    }

    private func resolve(_ entitlement: Entitlement) -> State {
        switch entitlement {
        case .active(let productID, let date, let willRenew):
            return .subscribed(plan(productID), renewsOrExpires: date, willRenew: willRenew)
        case .ended(let productID, let date):
            return .ended(plan(productID), endedAt: date)
        case .none:
            if !productsLoaded { return .loading }
            if let productsError { return .unavailable(.storeUnavailable(productsError)) }
            return products.isEmpty ? .unavailable(.productsNotFound) : .notSubscribed
        }
    }

    private func plan(_ productID: String) -> Plan {
        Plan(productID: productID, product: products.first { $0.id == productID })
    }

    /// What the verified records say, before the products are taken into account.
    enum Entitlement: Hashable, Sendable {
        case active(productID: String, until: Date?, willRenew: Bool)
        case ended(productID: String, at: Date?)
        case none
    }

    /// The entitlement the records show, trusting only verified ones:
    /// 1. a verified status in an active state (subscribed, grace, billing retry) for a backup
    ///    product, the one running longest;
    /// 2. when no statuses could be read (`statuses == nil`), a verified transaction that is
    ///    unexpired, unrevoked and not upgraded away from;
    /// 3. otherwise the newest verified transaction, as ended (at its revocation or expiry);
    /// 4. otherwise none.
    nonisolated static func entitlement(productIDs: Set<String>, transactions: [BackupStoreTransaction],
                                        statuses: [BackupStoreSubscriptionStatus]?, now: Date) -> Entitlement {
        let verified = transactions.filter { $0.isVerified && productIDs.contains($0.productID) }
        func renewal(for transaction: BackupStoreTransaction) -> Bool {
            statuses?.first { $0.transaction.originalID == transaction.originalID && $0.transaction.isVerified }?
                .willAutoRenew ?? false
        }
        if let statuses {
            let active = statuses.filter {
                $0.state.isActive && $0.transaction.isVerified && productIDs.contains($0.transaction.productID)
            }
            if let best = active.max(by: { ($0.transaction.expirationDate ?? .distantFuture) < ($1.transaction.expirationDate ?? .distantFuture) }) {
                return .active(productID: best.transaction.productID, until: best.transaction.expirationDate,
                               willRenew: best.willAutoRenew ?? false)
            }
        } else if let best = verified.filter({ $0.isActive(at: now) })
            .max(by: { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }) {
            return .active(productID: best.productID, until: best.expirationDate, willRenew: renewal(for: best))
        }
        if let newest = newestVerified(verified, productIDs: productIDs) {
            return .ended(productID: newest.productID, at: newest.revocationDate ?? newest.expirationDate)
        }
        return .none
    }

    /// The newest verified transaction for these products (latest purchase date, then highest ID).
    nonisolated static func newestVerified(_ transactions: [BackupStoreTransaction], productIDs: Set<String>) -> BackupStoreTransaction? {
        transactions.filter { $0.isVerified && productIDs.contains($0.productID) }
            .max { ($0.purchaseDate, $0.id) < ($1.purchaseDate, $1.id) }
    }
}
