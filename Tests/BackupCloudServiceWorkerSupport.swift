import CryptoKit
import Foundation
import ReaderBackup
import S3Kit
@testable import Marginal

// A fake of the backup service Worker (the HTTP contract in Backend/backup-worker/README.md),
// behind a `BackupCloudStub`, and a rig that builds Tactile Texts Cloud on fakes: this Worker,
// the fake R2 bucket, the fake StoreKit, `FakeAppAttestClient` and an in-memory key store.

nonisolated final class BackupCloudServiceFakeWorker: BackupCloudHandling, @unchecked Sendable {
    static let host = "backup.test"
    static let bypass = "BYPASS-SECRET-must-not-leak-0123456789"
    static let tokenPrefix = "token-"

    /// A scripted error answer.
    struct Failure {
        var status: Int
        var code: String
        var subscription: [String: Any]?
        /// `nil`: every time; otherwise this many answers.
        var times: Int?
    }

    private let lock = NSLock()
    private var issued: Set<String> = []
    private var registered: Set<String> = []
    private var _mode = "read-write"
    private var _subscription: [String: Any] = BackupCloudServiceFakeWorker.activeSubscription
    private var _usage: (bytes: Int64, allowance: Int64) = (1234, 10_000_000)
    private var _sessionFailure: Failure?
    private var _attestFailure: Failure?
    private var _rejectAssertions = 0
    private var _tokens = 0
    private var _sessions = 0
    private var _deleteCalls = 0
    private var _attests = 0
    private var _deleteBatch = 2
    private var _sessionBodies: [Data] = []
    private var _bypassed = 0
    private var _clock: @Sendable () -> Date = { Date() }
    private weak var r2: BackupCloudServiceFakeR2?

    let stub: BackupCloudStub

    init(r2: BackupCloudServiceFakeR2?) {
        self.r2 = r2
        let target = BackupCloudWeakTarget()
        stub = BackupCloudStub { target.value?.handleRequest($0) ?? .http(599) }
        target.value = self
    }

    func handleRequest(_ request: BackupCloudRequest) -> BackupCloudReply { handle(request) }

    static var activeSubscription: [String: Any] { [
        "state": "active", "environment": "Production", "productId": BackupCloudServiceStoreFixtures.productID,
        "expiresAt": "2027-02-15T00:00:00.000Z", "endedAt": NSNull(), "readOnlyUntil": NSNull(), "deleteAfter": NSNull(),
    ] }
    static var endedSubscription: [String: Any] { [
        "state": "ended", "environment": "Production", "productId": BackupCloudServiceStoreFixtures.productID,
        "expiresAt": "2027-01-01T00:00:00.000Z", "endedAt": "2027-01-01T00:00:00.000Z",
        "readOnlyUntil": "2027-01-31T00:00:00.000Z", "deleteAfter": "2027-03-02T00:00:00Z",
    ] }
    static let readOnlyUntil = Date(timeIntervalSince1970: 1_801_353_600) // 2027-01-31
    static let deleteAfter = Date(timeIntervalSince1970: 1_803_945_600) // 2027-03-02

    var mode: String { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
    var subscription: [String: Any] { get { lock.withLock { _subscription } } set { lock.withLock { _subscription = newValue } } }
    var usage: (bytes: Int64, allowance: Int64) { get { lock.withLock { _usage } } set { lock.withLock { _usage = newValue } } }
    var sessionFailure: Failure? { get { lock.withLock { _sessionFailure } } set { lock.withLock { _sessionFailure = newValue } } }
    var attestFailure: Failure? { get { lock.withLock { _attestFailure } } set { lock.withLock { _attestFailure = newValue } } }
    /// Answers this many assertions with `assertion-invalid`.
    var rejectAssertions: Int { get { lock.withLock { _rejectAssertions } } set { lock.withLock { _rejectAssertions = newValue } } }
    var deleteBatch: Int { get { lock.withLock { _deleteBatch } } set { lock.withLock { _deleteBatch = newValue } } }
    var clock: @Sendable () -> Date { get { lock.withLock { _clock } } set { lock.withLock { _clock = newValue } } }
    /// Sessions granted.
    var sessions: Int { lock.withLock { _sessions } }
    var deleteCalls: Int { lock.withLock { _deleteCalls } }
    /// Attestations accepted.
    var attests: Int { lock.withLock { _attests } }
    var bypassed: Int { lock.withLock { _bypassed } }
    var registeredKeys: Set<String> { lock.withLock { registered } }
    /// Bodies of authenticated requests that passed the checks.
    var sessionBodies: [Data] { lock.withLock { _sessionBodies } }

    /// The service forgets every registered key (as after its database was reset).
    func forgetDevices() { lock.withLock { registered.removeAll() } }
    func preregister(_ keyID: String) { _ = lock.withLock { registered.insert(keyID) } }

    /// Every request the service received, in order, as `METHOD path`.
    var log: [String] { stub.requests.map { "\($0.method) \($0.path)" } }

    // MARK: Handling

    private func handle(_ request: BackupCloudRequest) -> BackupCloudReply {
        lock.withLock { () -> BackupCloudReply in
            switch (request.method, request.path) {
            case ("GET", "/v1/health"):
                return .json(200, ["ok": true, "environment": "dev"])
            case ("POST", "/v1/challenge"):
                let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                let text = bytes.base64EncodedString()
                issued.insert(text)
                return .json(200, ["challenge": text, "expiresAt": "2027-01-15T08:05:00.000Z"])
            case ("POST", "/v1/attest"):
                return attest(request)
            case ("POST", "/v1/session"), ("POST", "/v1/delete-my-data"):
                let action = String(request.path.dropFirst("/v1/".count))
                if let refusal = authenticate(request, action: action) { return refusal }
                _sessionBodies.append(request.body)
                return action == "session" ? session() : deleteMyData()
            default:
                return Self.error(404, "not-found")
            }
        }
    }

    private func attest(_ request: BackupCloudRequest) -> BackupCloudReply {
        if let failure = take(&_attestFailure) { return Self.error(failure.status, failure.code, failure.subscription) }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
              let keyID = body["keyId"], let challenge = body["challenge"], let attestation = body["attestation"],
              let object = Data(base64Encoded: attestation), let challengeBytes = Data(base64Encoded: challenge) else {
            return Self.error(400, "bad-request")
        }
        guard issued.remove(challenge) != nil else { return Self.error(401, "challenge-invalid") }
        guard String(decoding: object, as: UTF8.self) == "fake-attestation:\(keyID):\(Self.hex(challengeBytes))" else {
            return Self.error(401, "attestation-invalid")
        }
        guard registered.insert(keyID).inserted else { return Self.error(409, "device-already-attested") }
        _attests += 1
        return .json(201, ["keyId": keyID, "environment": "development"])
    }

    /// The contract's checks in its order: body, challenge, assertion (or bypass), transaction.
    private func authenticate(_ request: BackupCloudRequest, action: String) -> BackupCloudReply? {
        guard request.headers["content-type"] == "application/json",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
              body["action"] == action, let challenge = body["challenge"], body["signedTransaction"] != nil else {
            return Self.error(400, "bad-request")
        }
        guard issued.remove(challenge) != nil else { return Self.error(401, "challenge-invalid") }
        if let bypass = request.headers["x-app-attest-bypass"] {
            guard bypass == Self.bypass else { return Self.error(401, "assertion-invalid") }
            _bypassed += 1
        } else {
            guard let keyID = request.headers["x-app-attest-key-id"],
                  let assertion = request.headers["x-app-attest-assertion"].flatMap({ Data(base64Encoded: $0) }) else {
                return Self.error(401, "assertion-invalid")
            }
            guard registered.contains(keyID) else { return Self.error(401, "device-unknown") }
            if _rejectAssertions > 0 {
                _rejectAssertions -= 1
                return Self.error(401, "assertion-invalid")
            }
            guard String(decoding: assertion, as: UTF8.self) == "fake-assertion:\(keyID):\(Self.hex(request.body))" else {
                return Self.error(401, "assertion-invalid")
            }
        }
        if action == "session", let failure = take(&_sessionFailure) {
            return Self.error(failure.status, failure.code, failure.subscription)
        }
        return nil
    }

    private func session() -> BackupCloudReply {
        _tokens += 1
        _sessions += 1
        let token = "\(Self.tokenPrefix)\(_tokens)"
        r2?.validToken = token
        // R2 refuses what the mode's credentials don't allow; read-delete still deletes (and, in
        // this fake, would even accept an upload, so a test sees whether one was attempted).
        r2?.readOnly = _mode == "read-only"
        let expires = _clock().addingTimeInterval(900)
        return .json(200, [
            "mode": _mode,
            "credentials": ["accessKeyId": "TEMPKEY", "secretAccessKey": BackupCloudServiceCredentials.secret,
                            "sessionToken": token, "expiresAt": expires.formatted(.iso8601)],
            "storage": ["endpoint": "https://\(BackupCloudServiceFakeR2.host)", "host": BackupCloudServiceFakeR2.host,
                        "region": "auto", "bucket": BackupCloudServiceFakeR2.bucket,
                        "prefix": BackupCloudServiceFakeR2.prefix + "/"],
            "subscription": _subscription,
            "usage": ["bytes": _usage.bytes, "allowanceBytes": _usage.allowance, "overAllowance": _usage.bytes > _usage.allowance,
                      "countedAt": "2027-01-15T08:00:00.000Z"],
        ])
    }

    private func deleteMyData() -> BackupCloudReply {
        _deleteCalls += 1
        let prefix = BackupCloudServiceFakeR2.prefix + "/"
        let keys = (r2?.keys ?? []).filter { $0.hasPrefix(prefix) }
        let batch = keys.prefix(_deleteBatch)
        for key in batch { r2?.remove(key) }
        return .json(200, ["done": keys.count <= _deleteBatch, "deletedObjects": batch.count])
    }

    private func take(_ failure: inout Failure?) -> Failure? {
        guard let current = failure else { return nil }
        if let times = current.times {
            failure = times > 1 ? Failure(status: current.status, code: current.code, subscription: current.subscription,
                                          times: times - 1) : nil
        }
        return current
    }

    static func error(_ status: Int, _ code: String, _ subscription: [String: Any]? = nil) -> BackupCloudReply {
        var body: [String: Any] = ["error": ["code": code, "message": "Server message for \(code)."]]
        if let subscription { body["subscription"] = subscription }
        return .json(status, body)
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A clock tests move by hand.
nonisolated final class BackupCloudServiceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

// MARK: - A rig

/// Tactile Texts Cloud on fakes.
@MainActor
struct BackupCloudServiceRig {
    typealias S = BackupCloudServiceStoreFixtures
    static let renewalJWS = "eyJhbGciOiJFUzI1NiJ9.RENEWAL-must-not-leak.c2ln"

    let r2: BackupCloudServiceFakeR2
    let worker: BackupCloudServiceFakeWorker
    let store: BackupCloudServiceFakeStore
    let attest: FakeAppAttestClient
    let keyStore: InMemoryBackupKeyStore
    let clock: BackupCloudServiceClock
    let defaults: UserDefaults
    let scratch: URL
    let cloud: TactileCloudBackup

    var account: CloudBackupAccount { cloud.account }
    var destination: TactileCloudBackupDestination { cloud.destination }
    var connection: CloudBackupConnection { cloud.account.connection! }

    /// - Parameter subscribed: whether StoreKit holds an active subscription (otherwise none ever).
    static func make(subscribed: Bool = true, key: BackupEncryptionKey? = nil, attestSupported: Bool = true,
                     bypass: String = "") throws -> BackupCloudServiceRig {
        let r2 = BackupCloudServiceFakeR2()
        let worker = BackupCloudServiceFakeWorker(r2: r2)
        let clock = BackupCloudServiceClock()
        worker.clock = { clock.now }
        let store = BackupCloudServiceFakeStore()
        store.products = [S.product]
        if subscribed {
            let transaction = S.transaction(11, original: 11, purchased: -86_400, expires: 30 * 86_400)
            store.history = [transaction]
            store.statuses = [BackupStoreSubscriptionStatus(state: .subscribed, transaction: transaction, willAutoRenew: true,
                                                            renewalInfoJWS: renewalJWS)]
        }
        let attest = FakeAppAttestClient(isSupported: attestSupported)
        let keyStore = InMemoryBackupKeyStore(key: key)
        let suite = "CloudRig-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let scratch = try BackupCloudFixtures.scratch()
        let configuration = BackupServiceConfiguration(host: BackupCloudServiceFakeWorker.host, productIDs: S.productID,
                                                       attestBypass: bypass)!
        let cloud = TactileCloudBackup.make(configuration: configuration, store: store, attest: attest, keyStore: keyStore,
                                            urlSession: worker.stub.session, s3Session: r2.stub.session,
                                            retryPolicy: S3RetryPolicy(maxAttempts: 1, sleep: { _ in }),
                                            temporaryDirectory: scratch.appendingPathComponent("tmp"), defaults: defaults,
                                            now: { clock.now })
        return BackupCloudServiceRig(r2: r2, worker: worker, store: store, attest: attest, keyStore: keyStore, clock: clock,
                                     defaults: defaults, scratch: scratch, cloud: cloud)
    }

    /// Loads the products and refreshes the account.
    func start() async {
        await cloud.subscription.load()
        await account.refresh()
    }

    /// A local file of `count` bytes and its digest.
    func pdf(_ count: Int = 3000, seed: UInt8 = 3) throws -> (url: URL, sha256: String, size: Int64) {
        let data = BackupCloudFixtures.bytes(count, seed: seed)
        let url = try BackupCloudFixtures.write(data, in: scratch)
        return (url, BackupCloudFixtures.sha256(data), Int64(data.count))
    }

    /// A snapshot file with a valid snapshot name.
    func snapshot(_ seconds: TimeInterval = 0) throws -> (url: URL, name: String) {
        let name = SnapshotName.make(createdAt: BackupCloudFixtures.date.addingTimeInterval(seconds), deviceName: "Rig iPad")
        let url = try BackupCloudFixtures.write(BackupCloudFixtures.bytes(500, seed: 9), in: scratch, name: name)
        return (url, name)
    }

    /// Requests that change the bucket.
    var bucketWrites: Int { r2.stub.requests.filter { ["PUT", "POST", "DELETE"].contains($0.method) }.count }

    func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
    }
}
