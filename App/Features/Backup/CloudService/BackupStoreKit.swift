import Foundation
import StoreKit
import UIKit

// The narrow slice of StoreKit 2 that `BackupSubscription` uses, as plain values, so the model
// can be tested with a fake. `AppStoreBackupStore` is the real thing. Everything here is
// available at iOS 17.0.

/// A subscription product as the App Store describes it.
nonisolated struct BackupStoreProduct: Hashable, Sendable, Identifiable {
    /// A billing period: `value` × `unit`.
    struct Period: Hashable, Sendable {
        enum Unit: Hashable, Sendable { case day, week, month, year }
        let value: Int
        let unit: Unit
    }

    let id: String
    /// Localised name and description from the App Store (or the StoreKit configuration file).
    let displayName: String
    let summary: String
    /// Localised price, for example "£2.99".
    let displayPrice: String
    /// `nil` for a product that is not an auto-renewable subscription.
    let subscriptionGroupID: String?
    let period: Period?

    init(id: String, displayName: String, summary: String = "", displayPrice: String,
         subscriptionGroupID: String?, period: Period?) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.displayPrice = displayPrice
        self.subscriptionGroupID = subscriptionGroupID
        self.period = period
    }
}

/// One App Store transaction, with whether StoreKit verified its signature and its signed form.
///
/// The signed form (`jwsRepresentation`) identifies the reader's subscription to the backup
/// service; it never appears in a description, debug description or mirror.
nonisolated struct BackupStoreTransaction: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    let id: UInt64
    let originalID: UInt64
    let productID: String
    let purchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    /// The subscriber moved to a higher product in the same group; this one no longer counts.
    let isUpgraded: Bool
    /// `true` only when StoreKit verified the App Store's signature (`VerificationResult.verified`).
    let isVerified: Bool
    /// The transaction as the App Store signed it (a compact JWS).
    let jwsRepresentation: String

    init(id: UInt64, originalID: UInt64, productID: String, purchaseDate: Date, expirationDate: Date?,
         revocationDate: Date? = nil, isUpgraded: Bool = false, isVerified: Bool, jwsRepresentation: String) {
        self.id = id
        self.originalID = originalID
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.isVerified = isVerified
        self.jwsRepresentation = jwsRepresentation
    }

    /// Not revoked, not upgraded away from, and not expired at `now`.
    func isActive(at now: Date) -> Bool {
        revocationDate == nil && !isUpgraded && (expirationDate.map { $0 > now } ?? true)
    }

    var description: String {
        "BackupStoreTransaction(id: \(id), product: \(productID), verified: \(isVerified), "
            + "expires: \(expirationDate.map { "\($0)" } ?? "never"), jws: <redacted>)"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["id": id, "productID": productID, "isVerified": isVerified,
                                "expirationDate": expirationDate as Any, "jwsRepresentation": "<redacted>"],
               displayStyle: .struct)
    }
}

/// A subscription's status in its group (`Product.SubscriptionInfo.Status`).
///
/// The renewal info's signed form never appears in a description, debug description or mirror.
nonisolated struct BackupStoreSubscriptionStatus: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    enum State: Hashable, Sendable {
        case subscribed, inGracePeriod, inBillingRetryPeriod, expired, revoked
        case other(Int)

        /// Subscribed, or in a grace or billing-retry period (the backup service treats both as
        /// active).
        var isActive: Bool {
            switch self {
            case .subscribed, .inGracePeriod, .inBillingRetryPeriod: true
            case .expired, .revoked, .other: false
            }
        }
    }

    let state: State
    /// The latest transaction of the subscription (verified or not).
    let transaction: BackupStoreTransaction
    /// From the renewal info, `nil` when that was not verified.
    let willAutoRenew: Bool?
    /// The renewal info as the App Store signed it (a compact JWS), only when StoreKit verified
    /// it. The backup service uses it to count Apple's grace and billing-retry periods.
    let renewalInfoJWS: String?

    init(state: State, transaction: BackupStoreTransaction, willAutoRenew: Bool?, renewalInfoJWS: String? = nil) {
        self.state = state
        self.transaction = transaction
        self.willAutoRenew = willAutoRenew
        self.renewalInfoJWS = renewalInfoJWS
    }

    var description: String {
        "BackupStoreSubscriptionStatus(state: \(state), transaction: \(transaction), "
            + "willAutoRenew: \(willAutoRenew.map(String.init) ?? "unknown"), renewalInfo: \(renewalInfoJWS == nil ? "none" : "<redacted>"))"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["state": state, "transaction": transaction, "willAutoRenew": willAutoRenew as Any,
                                "renewalInfoJWS": renewalInfoJWS == nil ? "none" : "<redacted>"], displayStyle: .struct)
    }
}

/// What `BackupStoreKit.purchase` returns.
nonisolated enum BackupStorePurchaseResult: Hashable, Sendable {
    /// The App Store completed the purchase. The transaction may be unverified.
    case success(BackupStoreTransaction)
    case userCancelled
    /// Waiting for approval (Ask to Buy) or for the reader to act; the result arrives later
    /// through the transaction updates.
    case pending
}

/// The StoreKit calls `BackupSubscription` makes. Errors are `BackupSubscriptionError`.
@MainActor
protocol BackupStoreKit: AnyObject {
    /// The products with these IDs that the App Store knows (any it does not are left out).
    func products(for ids: [String]) async throws -> [BackupStoreProduct]
    /// Buys the product with the account's `appAccountToken` (when given), showing the system's
    /// confirmation in `scene` when given.
    func purchase(productID: String, appAccountToken: UUID?, confirmIn scene: UIScene?) async throws -> BackupStorePurchaseResult
    /// `AppStore.sync()`: asks the App Store for the reader's transactions (may ask them to sign
    /// in). Cancelling that sign-in is not an error.
    func sync() async throws
    /// Every transaction for these products (`Transaction.all`), verified or not, expired ones
    /// included.
    func transactions(for productIDs: Set<String>) async -> [BackupStoreTransaction]
    /// The statuses of the subscriptions in a group.
    func subscriptionStatuses(groupID: String) async throws -> [BackupStoreSubscriptionStatus]
    /// Transactions as they arrive (`Transaction.updates`: renewals, purchases made elsewhere,
    /// refunds, and once after launch any left unfinished). Ends when the iteration is cancelled.
    func transactionUpdates() -> AsyncStream<BackupStoreTransaction>
    /// Tells the App Store the transaction has been dealt with.
    func finish(_ transaction: BackupStoreTransaction) async
}

/// Failures of buying, restoring or loading subscriptions, as the reader can be told.
nonisolated enum BackupSubscriptionError: LocalizedError, Hashable, Sendable {
    /// This build has no subscription products configured.
    case notConfigured
    /// The App Store does not offer this product (here, or at all).
    case productNotFound
    /// The App Store's signature on the purchase could not be verified; it is not used.
    case verificationFailed
    /// The App Store could not be reached.
    case networkUnavailable
    /// This device or account is not allowed to make purchases (Screen Time, for example).
    case purchasesNotAllowed
    /// Anything else the App Store reported. `code` is for diagnostics.
    case storeFailed(code: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Tactile Texts Cloud Backup isn’t available in this version of the app."
        case .productNotFound:
            "That subscription isn’t available from the App Store right now."
        case .verificationFailed:
            "The App Store’s confirmation of your purchase couldn’t be verified. Try Restore Purchases, or try again later."
        case .networkUnavailable:
            "Couldn’t reach the App Store. Check your internet connection and try again."
        case .purchasesNotAllowed:
            DeviceKind.current.pick(
                iPad: "Purchases aren’t allowed on this iPad. Check Screen Time settings, or ask the person who manages it.",
                iPhone: "Purchases aren’t allowed on this iPhone. Check Screen Time settings, or ask the person who manages it.")
        case .storeFailed:
            "The App Store couldn’t complete that. Try again later."
        }
    }

    /// Maps an error from StoreKit.
    static func mapping(_ error: any Error) -> any Error {
        if error is BackupSubscriptionError || error is CancellationError { return error }
        if let store = error as? StoreKitError {
            switch store {
            case .networkError: return BackupSubscriptionError.networkUnavailable
            case .notAvailableInStorefront: return BackupSubscriptionError.productNotFound
            case .userCancelled: return CancellationError()
            case .notEntitled: return BackupSubscriptionError.storeFailed(code: "notEntitled")
            case .systemError: return BackupSubscriptionError.storeFailed(code: "systemError")
            case .unknown: return BackupSubscriptionError.storeFailed(code: "unknown")
            default: return BackupSubscriptionError.storeFailed(code: "StoreKitError")
            }
        }
        if let purchase = error as? Product.PurchaseError {
            switch purchase {
            case .purchaseNotAllowed: return BackupSubscriptionError.purchasesNotAllowed
            case .productUnavailable: return BackupSubscriptionError.productNotFound
            default: return BackupSubscriptionError.storeFailed(code: "PurchaseError")
            }
        }
        if error is URLError { return BackupSubscriptionError.networkUnavailable }
        return BackupSubscriptionError.storeFailed(code: "\((error as NSError).domain) \((error as NSError).code)")
    }
}

// MARK: - The App Store

/// `BackupStoreKit` over StoreKit 2.
@MainActor
final class AppStoreBackupStore: BackupStoreKit {
    private var products: [String: Product] = [:]
    /// Verified transactions handed out and not yet finished, by ID.
    private var unfinished: [UInt64: Transaction] = [:]

    init() {}

    func products(for ids: [String]) async throws -> [BackupStoreProduct] {
        let loaded: [Product]
        do { loaded = try await Product.products(for: ids) } catch { throw BackupSubscriptionError.mapping(error) }
        for product in loaded { products[product.id] = product }
        return loaded.map(Self.value)
    }

    func purchase(productID: String, appAccountToken: UUID?, confirmIn scene: UIScene?) async throws -> BackupStorePurchaseResult {
        let product: Product
        if let cached = products[productID] {
            product = cached
        } else {
            guard let loaded = try await self.products(for: [productID]).first, let fresh = products[loaded.id] else {
                throw BackupSubscriptionError.productNotFound
            }
            product = fresh
        }
        let result: Product.PurchaseResult
        // The account's token, so the signed transaction names the account it pays for.
        let options: Set<Product.PurchaseOption> = appAccountToken.map { [.appAccountToken($0)] } ?? []
        do {
            if let scene {
                result = try await product.purchase(confirmIn: scene, options: options)
            } else {
                result = try await product.purchase(options: options)
            }
        } catch StoreKitError.userCancelled {
            return .userCancelled
        } catch {
            throw BackupSubscriptionError.mapping(error)
        }
        switch result {
        case .success(let verification): return .success(record(verification, keepForFinishing: true))
        case .userCancelled: return .userCancelled
        case .pending: return .pending
        @unknown default: throw BackupSubscriptionError.storeFailed(code: "PurchaseResult")
        }
    }

    func sync() async throws {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            throw BackupSubscriptionError.mapping(error)
        }
    }

    func transactions(for productIDs: Set<String>) async -> [BackupStoreTransaction] {
        var result: [BackupStoreTransaction] = []
        for await verification in Transaction.all where productIDs.contains(verification.unsafePayloadValue.productID) {
            result.append(record(verification))
        }
        return result
    }

    func subscriptionStatuses(groupID: String) async throws -> [BackupStoreSubscriptionStatus] {
        let statuses: [Product.SubscriptionInfo.Status]
        do { statuses = try await Product.SubscriptionInfo.status(for: groupID) } catch {
            throw BackupSubscriptionError.mapping(error)
        }
        return statuses.map { status in
            var willAutoRenew: Bool?
            var renewalJWS: String?
            if case .verified(let renewal) = status.renewalInfo {
                willAutoRenew = renewal.willAutoRenew
                renewalJWS = status.renewalInfo.jwsRepresentation
            }
            return BackupStoreSubscriptionStatus(state: Self.state(status.state), transaction: record(status.transaction),
                                                 willAutoRenew: willAutoRenew, renewalInfoJWS: renewalJWS)
        }
    }

    func transactionUpdates() -> AsyncStream<BackupStoreTransaction> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await verification in Transaction.updates {
                    guard let self else { break }
                    continuation.yield(self.record(verification, keepForFinishing: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(_ transaction: BackupStoreTransaction) async {
        guard transaction.isVerified else { return }
        if let stored = unfinished.removeValue(forKey: transaction.id) {
            await stored.finish()
            return
        }
        for await verification in Transaction.unfinished {
            if case .verified(let unfinishedTransaction) = verification, unfinishedTransaction.id == transaction.id {
                await unfinishedTransaction.finish()
                return
            }
        }
    }

    // MARK: Values

    /// The value of a transaction; a verified one from a purchase or an update is kept until
    /// `finish` is called for it.
    private func record(_ verification: VerificationResult<Transaction>, keepForFinishing: Bool = false) -> BackupStoreTransaction {
        let transaction = verification.unsafePayloadValue
        var verified = false
        if case .verified(let checked) = verification {
            verified = true
            if keepForFinishing { unfinished[checked.id] = checked }
        }
        return BackupStoreTransaction(id: transaction.id, originalID: transaction.originalID, productID: transaction.productID,
                                      purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate,
                                      revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded,
                                      isVerified: verified, jwsRepresentation: verification.jwsRepresentation)
    }

    private static func value(_ product: Product) -> BackupStoreProduct {
        var period: BackupStoreProduct.Period?
        if let subscriptionPeriod = product.subscription?.subscriptionPeriod {
            let unit: BackupStoreProduct.Period.Unit
            switch subscriptionPeriod.unit {
            case .day: unit = .day
            case .week: unit = .week
            case .month: unit = .month
            case .year: unit = .year
            @unknown default: unit = .month
            }
            period = BackupStoreProduct.Period(value: subscriptionPeriod.value, unit: unit)
        }
        return BackupStoreProduct(id: product.id, displayName: product.displayName, summary: product.description,
                                  displayPrice: product.displayPrice,
                                  subscriptionGroupID: product.subscription?.subscriptionGroupID, period: period)
    }

    private static func state(_ state: Product.SubscriptionInfo.RenewalState) -> BackupStoreSubscriptionStatus.State {
        switch state {
        case .subscribed: .subscribed
        case .inGracePeriod: .inGracePeriod
        case .inBillingRetryPeriod: .inBillingRetryPeriod
        case .expired: .expired
        case .revoked: .revoked
        default: .other(state.rawValue)
        }
    }
}
