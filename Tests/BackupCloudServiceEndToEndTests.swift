import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync
import S3Kit
import StoreKit
import StoreKitTest
import Testing
@testable import TactileTexts

private final class EndToEndBundleMarker {}

/// Tactile Texts Cloud end to end, opt-in: the app's own client against `wrangler dev` of
/// `Backend/backup-worker`, which mints real temporary credentials for the real development
/// bucket. It signs in through the `dev` Worker's test issuer (no Apple or Google account).
/// Skipped unless all three are set (`TEST_RUNNER_` passes them through `xcodebuild`):
///
///     TEST_RUNNER_TACTILE_BACKUP_SERVICE=localhost:<port>
///     TEST_RUNNER_TACTILE_BACKUP_SERVICE_BYPASS=<the Worker's APP_ATTEST_BYPASS_SECRET>
///     TEST_RUNNER_TACTILE_BACKUP_SERVICE_DEV_SIGNIN=<the Worker's DEV_TEST_SIGNIN_SECRET>
///
/// Never point it at a real deployment: production refuses the test issuer anyway.
///
/// The Worker needs `XCODE_STOREKIT_CERT` (the certificate this simulator's StoreKit test
/// session signs with): `TEST_RUNNER_TACTILE_STOREKIT_CERT_OUT=<file>` runs
/// `writeStoreKitTestCertificate`, which writes it there (see the Worker's README).
///
/// Nothing secret is printed: not the JWS, the credentials, the tokens or the secrets.
@MainActor
@Suite(.serialized)
struct BackupCloudServiceEndToEndTests {
    static let productID = "software.tactile.texts.backup.standard"
    nonisolated static let serviceHost = ProcessInfo.processInfo.environment["TACTILE_BACKUP_SERVICE"]
    nonisolated static let bypassSecret = ProcessInfo.processInfo.environment["TACTILE_BACKUP_SERVICE_BYPASS"]
    nonisolated static let devSignInSecret = ProcessInfo.processInfo.environment["TACTILE_BACKUP_SERVICE_DEV_SIGNIN"]
    nonisolated static let certificateOut = ProcessInfo.processInfo.environment["TACTILE_STOREKIT_CERT_OUT"]

    func storeKitSession() throws -> SKTestSession {
        let url = try #require(Bundle(for: EndToEndBundleMarker.self).url(forResource: "TactileTexts", withExtension: "storekit"))
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
    func subscribe(_ subscription: BackupSubscription, session: SKTestSession,
                   appAccountToken: UUID? = nil) async throws -> BackupSignedTransaction {
        await subscription.load()
        _ = try await session.buyProduct(identifier: Self.productID,
                                         options: appAccountToken.map { [.appAccountToken($0)] } ?? [])
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
    /// `TACTILE_STOREKIT_CERT_OUT`, for the Worker's `XCODE_STOREKIT_CERT`. A public
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

    @Test(.enabled(if: serviceHost != nil && bypassSecret != nil && devSignInSecret != nil))
    func signInBackUpRestoreAndDeleteThroughTheService() async throws {
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
        let identity = DevTestCloudIdentityProvider(secret: try #require(Self.devSignInSecret), audience: "software.tactile.texts",
                                                    subject: "end-to-end-\(UUID().uuidString.lowercased())")
        let cloud = TactileCloudBackup.make(configuration: configuration, store: AppStoreBackupStore(), attest: attest,
                                            keyStore: keyStore, sessionStore: InMemoryCloudDeviceSessionStore(),
                                            identity: identity, temporaryDirectory: scratch.appendingPathComponent("enc"),
                                            defaults: defaults)
        let account = cloud.account
        let connection = try #require(account.connection)
        #expect(try await connection.client.health() == "dev")

        // Sign in (a new account), then subscribe: the purchase binds to it.
        #expect(account.status == .signedOut)
        try await cloud.signIn.signIn(with: .apple, anchor: nil)
        #expect(cloud.signIn.isSignedIn)
        let token = try #require(cloud.signIn.appAccountToken)
        _ = try await subscribe(cloud.subscription, session: storeKit, appAccountToken: token)
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

        // Change the sign-in to Google and back, then sign out and in again: the same account.
        let accountID = try #require(cloud.signIn.accountID)
        try await cloud.signIn.changeSignIn(anchor: nil)
        #expect(cloud.signIn.session?.provider == .google && cloud.signIn.accountID == accountID)
        await cloud.signIn.signOut()
        #expect(account.status == .signedOut)
        try await cloud.signIn.signIn(with: .google, anchor: nil)
        #expect(cloud.signIn.accountID == accountID)

        // Delete the account: the device is signed out and the account is gone.
        try await cloud.deleteAccount(anchor: nil)
        #expect(!cloud.signIn.isSignedIn && cloud.signIn.signedOutReason == .accountDeleted)
        try await cloud.signIn.signIn(with: .google, anchor: nil)
        #expect(cloud.signIn.accountID != accountID, "the same identity now makes a new account")
        try await cloud.deleteAccount(anchor: nil)
    }

    // MARK: Sync through the service (C5)

    /// Two libraries in one process sync through the real path: the Worker's session and
    /// temporary credentials, `SyncS3ObjectStore` over `S3Client`, the real development bucket.
    /// A note, a highlight, page ink and a deletion cross; Recently Deleted brings the book back;
    /// housekeeping runs and removes nothing it should not; writing an object again moves its date
    /// (the reuse rule's assumption about R2); every object is opaque; everything is removed.
    @Test(.enabled(if: serviceHost != nil && bypassSecret != nil && devSignInSecret != nil))
    func syncTwoLibrariesThroughTheService() async throws {
        let storeKit = try storeKitSession()
        defer { storeKit.clearTransactions() }
        let host = try #require(Self.serviceHost)
        let bypass = try #require(Self.bypassSecret)
        let configuration = try #require(BackupServiceConfiguration(host: host, productIDs: Self.productID, attestBypass: bypass))
        let scratch = try BackupTestSupport.scratch("SyncEndToEnd")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "SyncEndToEnd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = InMemoryBackupKeyStore()
        let identity = DevTestCloudIdentityProvider(secret: try #require(Self.devSignInSecret), audience: "software.tactile.texts",
                                                    subject: "sync-end-to-end-\(UUID().uuidString.lowercased())")
        let cloud = TactileCloudBackup.make(configuration: configuration, store: AppStoreBackupStore(),
                                            attest: DeviceAppAttestClient(defaultsSuiteName: suite), keyStore: keyStore,
                                            sessionStore: InMemoryCloudDeviceSessionStore(), identity: identity,
                                            temporaryDirectory: scratch.appendingPathComponent("enc"), defaults: defaults)
        let account = cloud.account
        let connection = try #require(account.connection)
        try await cloud.signIn.signIn(with: .apple, anchor: nil)
        let token = try #require(cloud.signIn.appAccountToken)
        _ = try await subscribe(cloud.subscription, session: storeKit, appAccountToken: token)
        await account.refresh()
        let session = try #require(connection.latestSession, "no session: \(String(describing: account.lastError))")
        #expect(session.mode == .readWrite)
        let raw = S3Client(endpoint: try #require(session.storage.s3Endpoint), credentialsProvider: connection.credentials)
        for object in try await raw.list() { try await raw.delete(key: object.key) }
        let accountID = try #require(cloud.signIn.accountID)
        let access = TactileCloudSyncAccess(connection: connection, accountID: { accountID },
                                            temporaryDirectory: scratch.appendingPathComponent("sync-tmp"))
        guard case .ready(let ready) = try await access.prepareRound() else {
            Issue.record("the account is not ready to sync")
            return
        }
        #expect(ready.mode == .full)
        #expect(try await keyStore.load() == ready.key, "the first round made the account's key")

        do {
            let a = try SyncTestDevice("A", objects: ready.store, key: ready.key)
            let b = try SyncTestDevice("B", objects: ready.store, key: ready.key)
            defer { a.cleanUp(); b.cleanUp() }
            let date = Date(timeIntervalSinceReferenceDate: 790_000_000)
            let noteText = "End-to-end note \(UUID().uuidString)"

            // A note, a highlight and page ink cross from A to B.
            let bookA = try await a.importBook()
            let other = try await a.importBook(BackupTestSupport.noOutline)
            try await a.sync()
            try await b.sync()
            try a.store.notes.save(Note(bookID: bookA.id, target: .page(2), text: noteText, createdAt: date))
            try a.store.highlights.save(Highlight(bookID: bookA.id, pageIndex: 1, rects: [CGRect(x: 10, y: 20, width: 90, height: 12)],
                                                  color: .green, text: "marked end to end", createdAt: date))
            let stroke = SyncTestSupport.stroke(80)
            try await SyncTestSupport.addPageInk(a, bookA.id, page: 5, [stroke])
            #expect(try await a.sync().failures.isEmpty)
            #expect(try await b.sync().failures.isEmpty)
            let bookB = try #require(b.book(sha256: SyncTestSupport.sha256(bookA, in: a)))
            #expect(try b.archive(bookB).notes.map(\.text) == [noteText])
            #expect(try b.archive(bookB).highlights.map(\.text) == ["marked end to end"])
            #expect(try await b.pageStrokes(bookB.id, page: 5) == [StrokeIdentity(stroke)])

            // A deletion crosses, and Recently Deleted on B brings the book back to both.
            try await a.store.deleteBook(id: other.id, origin: nil)
            #expect(try await a.sync().count(.deletedInAccount) == 1)
            #expect(try await b.sync().count(.deletedHere) == 1)
            #expect(try b.store.books.allBooks().count == 1)
            let deleted = try await b.engine.recentlyDeleted()
            #expect(deleted.map(\.deviceName) == ["A"])
            let restored = try await b.engine.restoreDeleted(bookKey: try #require(deleted.first).bookKey)
            #expect(restored?.action == .createdHere)
            #expect(try b.store.books.allBooks().count == 2)
            #expect(try await a.sync().count(.createdHere) == 1)
            #expect(try await b.engine.recentlyDeleted().isEmpty)

            // Writing an object again moves its date (S3 `LastModified`), as the reuse rule assumes.
            let probe = try await ready.store.list(prefix: SyncLayout.blobsPrefix).first
            let probeKey = try #require(probe?.key)
            let before = try #require(try await ready.store.head(probeKey)?.lastModified)
            try await Task.sleep(for: .milliseconds(1_500))
            let encrypted = await a.engine.store
            let head = try #require(try await encrypted.readHead(bookKey: try encrypted.bookKey(pdfSHA256: SyncTestSupport.sha256(bookA, in: a))))
            let records = try await encrypted.blob(head.head.references.records)
            try await encrypted.putBlob(records, reuseIfWrittenAfter: .distantFuture)
            let recordsKey = try encrypted.blobKey(sha256: head.head.references.records.sha256)
            let after = try #require(try await ready.store.head(recordsKey)?.lastModified)
            #expect(after > before, "rewritten: \(before) → \(after)")

            // Housekeeping runs (with the account's snapshots) and removes nothing anything needs.
            let keysBefore = Set(try await ready.store.list(prefix: "").map(\.key))
            let snapshots = SyncSnapshotPDFReferences(
                destination: EncryptedBackupDestination(id: "sync-housekeeping", displayName: "", store: try #require(ready.backupStore),
                                                        key: ready.key, temporaryDirectory: scratch.appendingPathComponent("snap-tmp")),
                cacheDirectory: scratch.appendingPathComponent("snapshots"))
            let run = try await a.engine.housekeep(snapshots: snapshots)
            #expect(run.outcome == .finished, "\(run)")
            #expect(!run.removedAnything && run.repairedBlobs == 0 && run.missingBlobs == 0, "\(run)")
            let keysAfter = Set(try await ready.store.list(prefix: "").map(\.key))
            #expect(keysBefore.subtracting(keysAfter).isEmpty, "removed \(keysBefore.subtracting(keysAfter))")
            #expect(try await a.sync().failures.isEmpty)
            #expect(try await b.sync().failures.isEmpty)
            try await SyncTestSupport.expectEqual(a, b, "after housekeeping, through the service")

            // Every object is opaque: no title, note, highlight or PDF hash in a name or in the bytes.
            let pdfHash = SyncTestSupport.sha256(bookA, in: a)
            let secrets = [noteText, "marked end to end", pdfHash, bookA.title, other.title]
            let objects = try await raw.list()
            #expect(objects.contains { $0.key.hasPrefix(SyncLayout.headsPrefix) } && objects.contains { $0.key.hasPrefix(SyncLayout.blobsPrefix) })
            for object in objects {
                for secret in secrets { #expect(!object.key.contains(secret), "\(object.key) names it") }
                let file = scratch.appendingPathComponent(UUID().uuidString)
                _ = try await raw.download(key: object.key, to: file)
                let bytes = try Data(contentsOf: file)
                #expect(!bytes.starts(with: Data("%PDF".utf8)) && !bytes.starts(with: Data("PK".utf8)) && !bytes.starts(with: Data("{".utf8)),
                        "\(object.key) is readable")
                for secret in secrets where secret.utf8.count >= 5 {
                    #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(object.key) holds plaintext")
                }
            }
        }

        // Everything this run wrote is removed, and the account with it.
        for object in try await raw.list() { try await raw.delete(key: object.key) }
        #expect(try await raw.list().isEmpty)
        try await cloud.deleteAccount(anchor: nil)
        #expect(!cloud.signIn.isSignedIn)
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
