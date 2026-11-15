import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import S3Kit
import StoreKit
import StoreKitTest
import Testing
@testable import Marginal

private final class EndToEndBundleMarker {}

/// Tactile Texts Cloud end to end, opt-in: the app's own client against `wrangler dev` of
/// `Backend/backup-worker`, which mints real temporary credentials for the real development
/// bucket. Skipped unless both are set (`TEST_RUNNER_` passes them through `xcodebuild`):
///
///     TEST_RUNNER_MARGINAL_BACKUP_SERVICE=localhost:<port>
///     TEST_RUNNER_MARGINAL_BACKUP_SERVICE_BYPASS=<the Worker's APP_ATTEST_BYPASS_SECRET>
///
/// The Worker needs `XCODE_STOREKIT_CERT` (the certificate this simulator's StoreKit test
/// session signs with): `TEST_RUNNER_MARGINAL_STOREKIT_CERT_OUT=<file>` runs
/// `writeStoreKitTestCertificate`, which writes it there (see the Worker's README).
///
/// Nothing secret is printed: not the JWS, the credentials or the bypass secret.
@MainActor
@Suite(.serialized)
struct BackupCloudServiceEndToEndTests {
    static let productID = "software.tactile.marginal.backup.standard"
    nonisolated static let serviceHost = ProcessInfo.processInfo.environment["MARGINAL_BACKUP_SERVICE"]
    nonisolated static let bypassSecret = ProcessInfo.processInfo.environment["MARGINAL_BACKUP_SERVICE_BYPASS"]
    nonisolated static let certificateOut = ProcessInfo.processInfo.environment["MARGINAL_STOREKIT_CERT_OUT"]

    func storeKitSession() throws -> SKTestSession {
        let url = try #require(Bundle(for: EndToEndBundleMarker.self).url(forResource: "Marginal", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Buys the subscription through the test session and waits until the model sees it.
    func subscribe(_ subscription: BackupSubscription, session: SKTestSession) async throws -> BackupSignedTransaction {
        await subscription.load()
        _ = try await session.buyProduct(identifier: Self.productID)
        await eventually {
            if case .subscribed = subscription.state { return true }
            return false
        }
        guard case .subscribed = subscription.state else {
            Issue.record("not subscribed after the purchase: \(subscription.state)")
            throw CancellationError()
        }
        return try #require(await subscription.signedTransaction())
    }

    // MARK: The StoreKit test certificate

    /// Writes the base64 DER of the certificate in the `x5c` header of a test-session
    /// transaction (the single, self-signed certificate StoreKit Testing signs with) to
    /// `MARGINAL_STOREKIT_CERT_OUT`, for the Worker's `XCODE_STOREKIT_CERT`. A public
    /// certificate, not a secret; the transaction itself is not written anywhere.
    @Test(.enabled(if: certificateOut != nil))
    func writeStoreKitTestCertificate() async throws {
        let session = try storeKitSession()
        defer { session.clearTransactions() }
        let subscription = BackupSubscription(productIDs: [Self.productID], store: AppStoreBackupStore())
        let signed = try await subscribe(subscription, session: session)
        let header = try #require(signed.jws.split(separator: ".").first.flatMap { Self.base64URLDecoded(String($0)) })
        let object = try #require(try JSONSerialization.jsonObject(with: header) as? [String: Any])
        let chain = try #require(object["x5c"] as? [String])
        #expect(chain.count == 1, "StoreKit Testing signs with one self-signed certificate")
        let certificate = try #require(chain.first)
        let out = try #require(Self.certificateOut)
        try Data((certificate + "\n").utf8).write(to: URL(fileURLWithPath: out))
        if let renewal = signed.signedRenewalInfo,
           let renewalHeader = renewal.split(separator: ".").first.flatMap({ Self.base64URLDecoded(String($0)) }),
           let renewalObject = try JSONSerialization.jsonObject(with: renewalHeader) as? [String: Any] {
            #expect((renewalObject["x5c"] as? [String])?.first == certificate, "renewal info is signed by the same certificate")
        }
    }

    // MARK: Back up, restore, delete

    @Test(.enabled(if: serviceHost != nil && bypassSecret != nil))
    func backUpRestoreAndDeleteEverythingThroughTheService() async throws {
        let storeKit = try storeKitSession()
        defer { storeKit.clearTransactions() }
        let host = try #require(Self.serviceHost)
        let bypass = try #require(Self.bypassSecret)
        let configuration = try #require(BackupServiceConfiguration(host: host, productIDs: Self.productID, attestBypass: bypass))
        let scratch = try BackupTestSupport.scratch("CloudEndToEnd")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let suite = "CloudEndToEnd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = InMemoryBackupKeyStore()
        let attest = DeviceAppAttestClient(defaultsSuiteName: suite)
        #expect(!attest.isSupported, "the simulator has no App Attest, so the bypass is used")
        let cloud = TactileCloudBackup.make(configuration: configuration, store: AppStoreBackupStore(), attest: attest,
                                            keyStore: keyStore, temporaryDirectory: scratch.appendingPathComponent("enc"),
                                            defaults: defaults)
        let account = cloud.account
        let connection = try #require(account.connection)
        #expect(try await connection.client.health() == "dev")

        _ = try await subscribe(cloud.subscription, session: storeKit)
        await account.refresh()
        let session = try #require(connection.latestSession, "no session: \(String(describing: account.lastError))")
        #expect(session.storage.prefix.hasPrefix("sandbox/"), "a StoreKit test purchase lives under sandbox/")
        #expect(session.subscription.environment == "Xcode")
        #expect(session.mode == .readWrite)
        // `wrangler dev` counts usage through its *local* bucket binding, so it reads 0 here
        // whatever the real bucket holds.
        #expect(session.usage.bytes == 0)
        let endpoint = try #require(session.storage.s3Endpoint)
        let raw = S3Client(endpoint: endpoint, credentialsProvider: connection.credentials)

        // A clean start: an earlier run that failed half-way may have left objects (the test
        // session's transaction IDs repeat, so it is the same folder).
        for object in try await raw.list() { try await raw.delete(key: object.key) }
        await account.refresh()
        #expect(account.status == .active)
        #expect(account.hasKeyOnThisDevice == false)

        // Back up a library with one PDF.
        let book = try #require(try await ImportService(store: source).importPDF(at: BackupTestSupport.small).book)
        try await BackupTestSupport.seedRecords(source, book: book, label: "E2E")
        let service = BackupTestSupport.makeService(source, scratch: scratch)
        let result = try await service.backUp(to: cloud.destination, includePDFs: true)
        #expect(result.uploadedPDFs == 1)
        #expect(account.hasKeyOnThisDevice == true)
        #expect(account.recoveryKeyShown == false && account.recoveryKeySaved == false)
        #expect(try await keyStore.load() != nil)

        // Everything in the folder is opaque: names give nothing away, bytes are not a ZIP or PDF.
        let objects = try await raw.list()
        #expect(objects.count == 3, "key check, one snapshot, one PDF: \(objects.map(\.key))")
        let pdfBytes = try Data(contentsOf: BackupTestSupport.small)
        for object in objects {
            let key = object.key
            #expect(!key.lowercased().contains(".pdf") && !key.contains(".ttbackup") && !key.contains("Test iPad")
                    && !key.contains(book.title) && !key.contains(ContentHash.sha256(of: pdfBytes)), "\(key)")
            let file = scratch.appendingPathComponent(UUID().uuidString)
            _ = try await raw.download(key: key, to: file)
            let bytes = try Data(contentsOf: file)
            #expect(!bytes.starts(with: Data("PK".utf8)) && !bytes.starts(with: Data("%PDF".utf8)), "\(key) is readable")
            #expect(bytes.range(of: Data("manifest.json".utf8)) == nil && bytes.range(of: Data(book.title.utf8)) == nil)
        }

        // Restore into an empty library.
        let snapshots = try await cloud.destination.listSnapshots()
        #expect(snapshots.count == 1)
        let restoring = BackupTestSupport.makeService(target, scratch: scratch)
        let newest = try #require(snapshots.first)
        let opened = try await restoring.openBackup(newest, from: cloud.destination)
        let summary = try await restoring.restore(Set(opened.plan.items.map(\.id)), from: opened, restorePDFs: true)
        opened.close()
        #expect(summary.restored.count == 1 && summary.needingPDF.isEmpty)
        #expect(try BackupTestSupport.archive(target, book.id) == (try BackupTestSupport.archive(source, book.id)))
        #expect(BackupTestSupport.files(in: target.bookDirectoryURL(bookID: book.id))
                == BackupTestSupport.files(in: source.bookDirectoryURL(bookID: book.id)))

        // Delete everything: the service's loop, then the key.
        try await account.deleteEverything()
        #expect(try await keyStore.load() == nil)
        #expect(account.hasKeyOnThisDevice == false)
        // `wrangler dev`'s bucket binding is the local bucket, so delete-my-data emptied that
        // one; the real development bucket still holds this run's objects. Remove them with the
        // folder's own credentials, so nothing is left behind, and check the folder is empty.
        for object in try await raw.list() { try await raw.delete(key: object.key) }
        #expect(try await raw.list().isEmpty)
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
