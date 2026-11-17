import Foundation
import ReaderBackup
import S3Kit
import UIKit
@testable import TactileTexts

// Fakes for the cloud backup service's building blocks: a bucket that behaves like R2 with
// temporary credentials (multipart included), a credentials source, and a StoreKit fake.
// Nothing here touches the network.

// MARK: - Fake R2 bucket

/// One bucket, objects in memory keyed by the full decoded key (prefix included), behind a
/// `BackupCloudStub`. With `requireToken`, every request must carry the current session token
/// (`x-amz-security-token`); a stale token gets R2's answer for an expired temporary credential
/// (403 `SignatureDoesNotMatch`). `readOnly` refuses writes as R2 refuses actions a credential
/// doesn't allow (403 `AccessDenied`), and so does a key outside `allowedPrefix`.
nonisolated final class BackupCloudServiceFakeR2: BackupCloudHandling, @unchecked Sendable {
    static let bucket = "tactile-backups"
    static let prefix = "users/u-123"
    static let host = "account.r2.cloudflarestorage.com"

    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var uploads: [String: (key: String, parts: [Int: Data])] = [:]
    private var uploadCounter = 0
    private var _validToken: String?
    private var _readOnly = false
    private var _allowedPrefix: String? = BackupCloudServiceFakeR2.prefix + "/"
    private var _override: BackupCloudReply?
    private var _aborted = 0

    let stub: BackupCloudStub

    init() {
        let target = BackupCloudWeakTarget()
        stub = BackupCloudStub { target.value?.handleRequest($0) ?? .http(599) }
        target.value = self
    }

    func handleRequest(_ request: BackupCloudRequest) -> BackupCloudReply { handle(request) }

    /// The session token requests must carry; `nil` accepts any (or none).
    var validToken: String? { get { lock.withLock { _validToken } } set { lock.withLock { _validToken = newValue } } }
    var readOnly: Bool { get { lock.withLock { _readOnly } } set { lock.withLock { _readOnly = newValue } } }
    var override: BackupCloudReply? { get { lock.withLock { _override } } set { lock.withLock { _override = newValue } } }
    /// Multipart uploads aborted so far.
    var aborted: Int { lock.withLock { _aborted } }
    var pendingUploads: Int { lock.withLock { uploads.count } }

    var keys: [String] { lock.withLock { objects.keys.sorted() } }
    func object(_ key: String) -> Data? { lock.withLock { objects[key] } }
    func put(_ key: String, _ data: Data) { lock.withLock { objects[key] = data } }
    func remove(_ key: String) { _ = lock.withLock { objects.removeValue(forKey: key) } }
    /// Every stored byte, for "nothing readable" checks.
    var allBytes: Data { lock.withLock { objects.values.reduce(into: Data()) { $0.append($1) } } }

    func endpoint() -> S3Endpoint {
        S3Endpoint(host: Self.host, region: "auto", bucket: Self.bucket, prefix: Self.prefix)!
    }

    private func handle(_ request: BackupCloudRequest) -> BackupCloudReply {
        lock.withLock { () -> BackupCloudReply in
            if let override = _override { return override }
            if let token = _validToken, request.headers["x-amz-security-token"] != token {
                return request.method == "HEAD" ? .http(403) : BackupCloudFakeS3.error(403, code: "SignatureDoesNotMatch")
            }
            let bucketPath = "/\(Self.bucket)"
            guard request.path.hasPrefix(bucketPath) else { return BackupCloudFakeS3.error(404, code: "NoSuchBucket") }
            let key = String(String(request.path.dropFirst(bucketPath.count)).trimmingPrefix("/"))
            let query = request.query
            if key.isEmpty, request.method == "GET" {
                let prefix = query["prefix"] ?? ""
                if let allowed = _allowedPrefix, !prefix.hasPrefix(allowed) { return BackupCloudFakeS3.error(403, code: "AccessDenied") }
                return list(prefix: prefix)
            }
            if let allowed = _allowedPrefix, !key.hasPrefix(allowed) {
                return request.method == "HEAD" ? .http(403) : BackupCloudFakeS3.error(403, code: "AccessDenied")
            }
            let writing = ["PUT", "POST", "DELETE"].contains(request.method)
            if writing, _readOnly { return BackupCloudFakeS3.error(403, code: "AccessDenied") }
            switch request.method {
            case "POST" where query["uploads"] != nil:
                uploadCounter += 1
                let id = "upload-\(uploadCounter)"
                uploads[id] = (key, [:])
                return xml("<InitiateMultipartUploadResult><Bucket>\(Self.bucket)</Bucket><Key>\(key)</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
            case "PUT" where query["uploadId"] != nil:
                guard let id = query["uploadId"], uploads[id] != nil, let number = Int(query["partNumber"] ?? "") else {
                    return BackupCloudFakeS3.error(404, code: "NoSuchUpload")
                }
                uploads[id]!.parts[number] = request.body
                return .http(200, headers: ["ETag": "\"\(BackupCloudFixtures.md5(request.body))\""])
            case "POST" where query["uploadId"] != nil:
                guard let id = query["uploadId"], let upload = uploads.removeValue(forKey: id) else {
                    return BackupCloudFakeS3.error(404, code: "NoSuchUpload")
                }
                objects[upload.key] = upload.parts.keys.sorted().reduce(into: Data()) { $0.append(upload.parts[$1]!) }
                return xml("<CompleteMultipartUploadResult><Key>\(upload.key)</Key><ETag>\"done\"</ETag></CompleteMultipartUploadResult>")
            case "DELETE" where query["uploadId"] != nil:
                if let id = query["uploadId"], uploads.removeValue(forKey: id) != nil { _aborted += 1 }
                return .http(204)
            case "PUT":
                objects[key] = request.body
                return .http(200, headers: ["ETag": "\"\(BackupCloudFixtures.md5(request.body))\""])
            case "HEAD":
                guard let data = objects[key] else { return .http(404) }
                return .http(200, headers: ["Content-Length": String(data.count), "ETag": "\"\(BackupCloudFixtures.md5(data))\""])
            case "GET":
                guard let data = objects[key] else { return BackupCloudFakeS3.error(404, code: "NoSuchKey") }
                return .http(200, headers: ["Content-Length": String(data.count), "ETag": "\"\(BackupCloudFixtures.md5(data))\""], body: data)
            case "DELETE":
                objects[key] = nil
                return .http(204)
            default:
                return .http(405)
            }
        }
    }

    private func xml(_ body: String) -> BackupCloudReply {
        .http(200, headers: ["Content-Type": "application/xml"],
              body: Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + body).utf8))
    }

    private func list(prefix: String) -> BackupCloudReply {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var xml = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        xml += "<Name>\(Self.bucket)</Name><Prefix>\(escape(prefix))</Prefix><IsTruncated>false</IsTruncated>"
        for key in objects.keys.sorted() where key.hasPrefix(prefix) {
            xml += "<Contents><Key>\(escape(key))</Key><LastModified>2026-11-15T09:00:00.000Z</LastModified>"
            xml += "<ETag>&quot;e&quot;</ETag><Size>\(objects[key]!.count)</Size></Contents>"
        }
        xml += "</ListBucketResult>"
        return .http(200, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
    }
}

// MARK: - Credentials

/// What a credentials source throws when the backup service refuses (stands in for the service
/// client's own error, which `S3BackupBlobStore` must pass through untouched).
nonisolated struct BackupCloudServiceNotSubscribed: Error, Hashable, LocalizedError {
    var errorDescription: String? { "You’re not subscribed to Tactile Texts Cloud Backup." }
}

/// Temporary credentials `token-1`, `token-2`, … — a new one after each rejection, and keeps
/// `fake` (the R2) accepting only the newest unless told otherwise.
nonisolated final class BackupCloudServiceCredentials: S3CredentialsProvider, @unchecked Sendable {
    static let secret = "TEMP-SECRET-must-not-leak"

    private let lock = NSLock()
    private var generation = 1
    private var _failure: (any Error)?
    private var _calls = 0
    private var _rejections = 0
    private weak var r2: BackupCloudServiceFakeR2?
    /// When false, the R2's valid token is not moved on a rejection (so fresh ones fail too).
    var followRejections = true

    init(r2: BackupCloudServiceFakeR2?) {
        self.r2 = r2
        r2?.validToken = "token-1"
    }

    var failure: (any Error)? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    var rejections: Int { lock.withLock { _rejections } }

    func credentials() async throws -> S3Credentials {
        try lock.withLock {
            _calls += 1
            if let failure = _failure { throw failure }
            return S3Credentials(accessKeyID: "TEMPKEY", secretAccessKey: Self.secret, sessionToken: "token-\(generation)",
                                 expiration: Date().addingTimeInterval(900))
        }
    }

    func credentialsRejected(_ credentials: S3Credentials) async {
        let token: String = lock.withLock {
            _rejections += 1
            if credentials.sessionToken == "token-\(generation)" { generation += 1 }
            return "token-\(generation)"
        }
        if followRejections { r2?.validToken = token }
    }
}

nonisolated enum BackupCloudServiceFixtures {
    static let displayName = "Tactile Texts Cloud"

    static func store(_ r2: BackupCloudServiceFakeR2, credentials: (any S3CredentialsProvider)? = nil,
                      partSize: Int64 = S3Client.defaultPartSize) -> S3BackupBlobStore {
        S3BackupBlobStore(endpoint: r2.endpoint(), credentialsProvider: credentials ?? BackupCloudServiceCredentials(r2: r2),
                          displayName: displayName, session: r2.stub.session,
                          retryPolicy: S3RetryPolicy(maxAttempts: 1, sleep: { _ in }), partSize: partSize)
    }

    /// The full key of `relative` under the fake's prefix.
    static func key(_ relative: String) -> String { "\(BackupCloudServiceFakeR2.prefix)/\(relative)" }
}

// MARK: - Fake StoreKit

/// A scripted `BackupStoreKit`: products, a transaction history, statuses, and the result of
/// the next purchase or sync. `send(_:)` delivers a transaction update.
@MainActor
final class BackupCloudServiceFakeStore: BackupStoreKit {
    var products: [BackupStoreProduct] = []
    var productsError: BackupSubscriptionError?
    var history: [BackupStoreTransaction] = []
    /// `nil`: statuses can't be read (thrown).
    var statuses: [BackupStoreSubscriptionStatus]? = []
    var nextPurchase: Result<BackupStorePurchaseResult, any Error> = .success(.userCancelled)
    var syncResult: Result<[BackupStoreTransaction], any Error> = .success([])
    private(set) var finished: [UInt64] = []
    private(set) var purchases: [String] = []
    /// The `appAccountToken` each purchase carried.
    private(set) var purchaseTokens: [UUID?] = []
    private(set) var syncs = 0
    private var continuation: AsyncStream<BackupStoreTransaction>.Continuation?
    private(set) var updatesRequested = 0

    func products(for ids: [String]) async throws -> [BackupStoreProduct] {
        if let productsError { throw productsError }
        return products.filter { ids.contains($0.id) }
    }

    func purchase(productID: String, appAccountToken: UUID?, confirmIn scene: UIScene?) async throws -> BackupStorePurchaseResult {
        purchases.append(productID)
        purchaseTokens.append(appAccountToken)
        let result = try nextPurchase.get()
        if case .success(let transaction) = result { history.append(transaction) }
        return result
    }

    func sync() async throws {
        syncs += 1
        history += try syncResult.get()
    }

    func transactions(for productIDs: Set<String>) async -> [BackupStoreTransaction] {
        history.filter { productIDs.contains($0.productID) }
    }

    func subscriptionStatuses(groupID: String) async throws -> [BackupStoreSubscriptionStatus] {
        guard let statuses else { throw BackupSubscriptionError.networkUnavailable }
        return statuses
    }

    func transactionUpdates() -> AsyncStream<BackupStoreTransaction> {
        updatesRequested += 1
        let (stream, continuation) = AsyncStream<BackupStoreTransaction>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finish(_ transaction: BackupStoreTransaction) async {
        finished.append(transaction.id)
    }

    /// Delivers `transaction` as an update (and adds it to the history).
    func send(_ transaction: BackupStoreTransaction) {
        history.append(transaction)
        continuation?.yield(transaction)
    }

    var isListening: Bool { continuation != nil }
}

nonisolated enum BackupCloudServiceStoreFixtures {
    static let productID = "software.tactile.texts.backup.standard"
    static let otherProductID = "software.tactile.texts.backup.large"
    static let groupID = "21800001"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let product = BackupStoreProduct(id: productID, displayName: "Cloud Backup", summary: "Backups",
                                            displayPrice: "£2.99", subscriptionGroupID: groupID,
                                            period: .init(value: 1, unit: .month))

    /// A JWS-looking string that must never leak into descriptions.
    static func jws(_ id: UInt64) -> String { "eyJhbGciOiJFUzI1NiJ9.JWS-\(id)-must-not-leak.c2lnbmF0dXJl" }

    static func transaction(_ id: UInt64, original: UInt64 = 1, product: String = productID, purchased: TimeInterval,
                            expires: TimeInterval?, revoked: TimeInterval? = nil, verified: Bool = true) -> BackupStoreTransaction {
        BackupStoreTransaction(id: id, originalID: original, productID: product,
                               purchaseDate: now.addingTimeInterval(purchased),
                               expirationDate: expires.map { now.addingTimeInterval($0) },
                               revocationDate: revoked.map { now.addingTimeInterval($0) },
                               isVerified: verified, jwsRepresentation: jws(id))
    }

    static func status(_ state: BackupStoreSubscriptionStatus.State, _ transaction: BackupStoreTransaction,
                       willRenew: Bool? = true) -> BackupStoreSubscriptionStatus {
        BackupStoreSubscriptionStatus(state: state, transaction: transaction, willAutoRenew: willRenew)
    }
}
