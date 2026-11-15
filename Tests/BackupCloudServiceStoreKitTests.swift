import Foundation
import StoreKit
import StoreKitTest
import Testing
import UIKit
@testable import Marginal

private final class BundleMarker {}

/// `BackupSubscription` over the real StoreKit (`AppStoreBackupStore`), with a StoreKit test
/// session reading `Config/Marginal.storekit` (copied into the test bundle): no App Store
/// account, no network. Serialized: the test session is shared by the whole process.
@MainActor
@Suite(.serialized)
struct BackupCloudServiceStoreKitTests {
    static let productID = "software.tactile.marginal.backup.standard"

    func session() throws -> SKTestSession {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "Marginal", withExtension: "storekit"),
                               "Marginal.storekit is not in the test bundle")
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    var scene: UIScene? { UIApplication.shared.connectedScenes.first }

    /// Waits until `condition` holds.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func productsLoadFromTheConfigurationFile() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let model = BackupSubscription(productIDs: [Self.productID], store: AppStoreBackupStore())
        await model.load()
        #expect(model.state == .notSubscribed)
        let product = try #require(model.products.first)
        #expect(product.id == Self.productID)
        #expect(product.displayName == "Cloud Backup (placeholder)")
        #expect(product.subscriptionGroupID != nil)
        #expect(product.period == .init(value: 1, unit: .month))
        #expect(!product.displayPrice.isEmpty)
        #expect(await model.signedTransaction() == nil)
    }

    /// The in-app purchase path (`Product.purchase`). In this setup (app-hosted unit tests, an
    /// unsigned simulator build) the system answers it with the App Store sign-in sheet instead of
    /// the test session, so the test only runs when `MARGINAL_STOREKIT_PURCHASE_TEST` is set and
    /// someone is there to watch; it records what happened.
    /// (`TEST_RUNNER_MARGINAL_STOREKIT_PURCHASE_TEST=1 scripts/test.sh …` passes it through.)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGINAL_STOREKIT_PURCHASE_TEST"] != nil))
    func purchaseThroughTheApp() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let model = BackupSubscription(productIDs: [Self.productID], store: AppStoreBackupStore())
        await model.load()
        do {
            let withScene = ProcessInfo.processInfo.environment["MARGINAL_STOREKIT_PURCHASE_TEST"] == "scene"
            let outcome = try await model.purchase(Self.productID, confirmIn: withScene ? scene : nil)
            #expect(outcome == .purchased, "purchase outcome: \(outcome)")
        } catch {
            Issue.record("purchase threw \(String(reflecting: error))")
        }
    }

    @Test func aSubscriptionYieldsASignedTransactionThatOutlivesExpiry() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let model = BackupSubscription(productIDs: [Self.productID], store: AppStoreBackupStore())
        await model.load()
        #expect(model.state == .notSubscribed)

        // Bought through the test session (the in-app path needs an App Store sign-in here).
        _ = try await session.buyProduct(identifier: Self.productID)
        await eventually {
            if case .subscribed = model.state { return true }
            return false
        }
        guard case .subscribed(let plan, let renews, let willRenew) = model.state else {
            Issue.record("not subscribed after the purchase: \(model.state)")
            return
        }
        #expect(plan.productID == Self.productID && plan.product != nil)
        #expect(willRenew)
        #expect((renews ?? .distantPast) > Date())
        let signed = try #require(await model.signedTransaction())
        #expect(signed.jws.split(separator: ".").count == 3, "a compact JWS")
        #expect(signed.productID == Self.productID)

        // Expire it through the test session. Measured here (Xcode 27.2, iOS 27 simulator,
        // app-hosted tests): `expireSubscription` returns without error, but six seconds later
        // StoreKit 2 in this process still reports the status as subscribed and the transaction's
        // expiry unchanged, so the state stays subscribed. Recorded as a known issue with what
        // StoreKit reports; the next test makes an ended subscription another way.
        try session.expireSubscription(productIdentifier: Self.productID)
        await eventually {
            if case .ended = model.state { return true }
            Task { await model.refresh() }
            return false
        }
        if case .ended(let endedPlan, let endedAt) = model.state {
            #expect(endedPlan.productID == Self.productID)
            #expect((endedAt ?? .distantFuture) <= Date())
        } else {
            let report = await Self.diagnose()
            let state = model.state
            withKnownIssue("SKTestSession.expireSubscription has no effect StoreKit 2 reports in an app-hosted test",
                           isIntermittent: true) {
                Issue.record("not ended after expireSubscription: \(state); StoreKit: \(report)")
            }
        }
        let afterExpiry = try #require(await model.signedTransaction())
        #expect(afterExpiry.jws.split(separator: ".").count == 3)
        #expect(afterExpiry.originalTransactionID == signed.originalTransactionID)
    }

    /// A subscription bought 40 days ago through the test session that did not renew: the state
    /// is ended and the signed transaction is still handed out.
    @Test func anExpiredSubscriptionIsEndedAndStillYieldsASignedTransaction() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let model = BackupSubscription(productIDs: [Self.productID], store: AppStoreBackupStore())
        await model.load()
        let started = Date().addingTimeInterval(-40 * 86_400)
        _ = try await session.buyProduct(identifier: Self.productID,
                                         options: [.purchaseDate(started, renewalBehavior: .cancelImmediately)])
        await eventually {
            if case .ended = model.state { return true }
            Task { await model.refresh() }
            return false
        }
        guard case .ended(let plan, let endedAt) = model.state else {
            Issue.record("not ended: \(model.state); StoreKit: \(await Self.diagnose())")
            return
        }
        #expect(plan.productID == Self.productID)
        #expect((endedAt ?? .distantFuture) <= Date())
        let signed = try #require(await model.signedTransaction())
        #expect(signed.jws.split(separator: ".").count == 3, "a compact JWS")
        #expect((signed.expirationDate ?? .distantFuture) <= Date())
    }

    @Test func aPurchaseMadeOutsideTheAppArrivesThroughUpdates() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let model = BackupSubscription(productIDs: [Self.productID], store: AppStoreBackupStore())
        await model.load()
        #expect(model.state == .notSubscribed)
        _ = try await session.buyProduct(identifier: Self.productID)
        await eventually {
            if case .subscribed = model.state { return true }
            return false
        }
        guard case .subscribed = model.state else {
            Issue.record("the update did not arrive: \(model.state)")
            return
        }
        #expect(await model.signedTransaction() != nil)
    }

    /// What StoreKit itself reports, for a failure message.
    static func diagnose() async -> String {
        var lines: [String] = []
        do {
            let statuses = try await Product.SubscriptionInfo.status(for: "21800001")
            for status in statuses {
                let transaction = status.transaction.unsafePayloadValue
                lines.append("status \(status.state.rawValue) tx \(transaction.id) expires \(String(describing: transaction.expirationDate))")
            }
            if statuses.isEmpty { lines.append("no statuses") }
        } catch {
            lines.append("status threw \(String(reflecting: error))")
        }
        for await verification in Transaction.all {
            let transaction = verification.unsafePayloadValue
            lines.append("all: tx \(transaction.id) expires \(String(describing: transaction.expirationDate)) revoked \(String(describing: transaction.revocationDate))")
        }
        if let latest = await Transaction.latest(for: productID) {
            lines.append("latest: tx \(latest.unsafePayloadValue.id) expires \(String(describing: latest.unsafePayloadValue.expirationDate))")
        }
        lines.append("now \(Date())")
        return lines.joined(separator: " | ")
    }
}
