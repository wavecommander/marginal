import AuthenticationServices
import CryptoKit
import Foundation
import ReaderBackup
import S3Kit
@testable import TactileTexts

// A fake of the backup service Worker (the HTTP contract in Backend/backup-worker/README.md),
// behind a `BackupCloudStub`, a fake of Apple's and Google's sign-in, and a rig that builds
// Tactile Texts Cloud on fakes: this Worker, the fake R2 bucket, the fake StoreKit,
// `FakeAppAttestClient`, the fake sign-in and in-memory key and session stores.

nonisolated final class BackupCloudServiceFakeWorker: BackupCloudHandling, @unchecked Sendable {
    static let host = "backup.test"
    static let bypass = "BYPASS-SECRET-must-not-leak-0123456789"
    static let tokenPrefix = "token-"
    /// A device session that is live from the start, on the first account (`account(1)`).
    static let liveToken = "SESSION-TOKEN-must-not-leak-000000000001"
    static let appAccountToken = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

    /// An account's ID: 32 hex digits.
    static func account(_ number: Int) -> String { String(format: "%032x", number) }

    /// A scripted error answer.
    struct Failure {
        var status: Int
        var code: String
        var subscription: [String: Any]?
        /// `nil`: every time; otherwise this many answers.
        var times: Int?
    }

    struct Account {
        var id: String
        var provider: String
        var identity: String
        var appAccountToken: String
        var deleting = false
    }

    struct Session {
        var id: String
        var account: String
        var label: String?
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
    private var _accountDeleteCalls = 0
    private var _attests = 0
    private var _deleteBatch = 2
    private var _hasSubscription = true
    private var _sessionBodies: [Data] = []
    private var _bypassed = 0
    private var _clock: @Sendable () -> Date = { Date() }
    /// Identity ("apple:<subject>") to account.
    private var accounts: [String: Account] = [:]
    /// Session token to session.
    private var live: [String: Session] = [:]
    private var counter = 1
    private weak var r2: BackupCloudServiceFakeR2?

    let stub: BackupCloudStub

    init(r2: BackupCloudServiceFakeR2?) {
        self.r2 = r2
        let account = Account(id: Self.account(1), provider: "apple", identity: "apple:reader",
                              appAccountToken: Self.appAccountToken)
        accounts[account.identity] = account
        live[Self.liveToken] = Session(id: Self.account(1001), account: account.id)
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
    /// Whether the account has a subscription; without one, a session request that brings a
    /// signed transaction binds it, and one that does not is `not-subscribed`.
    var hasSubscription: Bool { get { lock.withLock { _hasSubscription } } set { lock.withLock { _hasSubscription = newValue } } }
    var clock: @Sendable () -> Date { get { lock.withLock { _clock } } set { lock.withLock { _clock = newValue } } }
    /// Sessions granted.
    var sessions: Int { lock.withLock { _sessions } }
    var deleteCalls: Int { lock.withLock { _deleteCalls } }
    var accountDeleteCalls: Int { lock.withLock { _accountDeleteCalls } }
    /// Attestations accepted.
    var attests: Int { lock.withLock { _attests } }
    var bypassed: Int { lock.withLock { _bypassed } }
    var registeredKeys: Set<String> { lock.withLock { registered } }
    /// Bodies of authenticated requests that passed the checks.
    var sessionBodies: [Data] { lock.withLock { _sessionBodies } }
    /// The live device session tokens.
    var liveTokens: Set<String> { lock.withLock { Set(live.keys) } }
    /// Every account, by identity ("apple:<subject>").
    var accountsByIdentity: [String: Account] { lock.withLock { accounts } }
    /// The encrypted device labels, by session token.
    func label(of token: String) -> String? { lock.withLock { live[token]?.label } }

    /// The service forgets every registered key (as after its database was reset).
    func forgetDevices() { lock.withLock { registered.removeAll() } }
    func preregister(_ keyID: String) { _ = lock.withLock { registered.insert(keyID) } }
    /// Makes an account for `identity` ("google:<subject>"), as its own first sign-in would.
    func addAccount(identity: String) {
        lock.withLock {
            counter += 1
            accounts[identity] = Account(id: Self.account(counter), provider: String(identity.prefix { $0 != ":" }),
                                         identity: identity, appAccountToken: UUID().uuidString.lowercased())
        }
    }

    /// Ends every session (as Sign Out of All Devices on another device would).
    func endAllSessions() { lock.withLock { live.removeAll() } }
    /// Starts another device's session on the account of `identity`; returns its token.
    @discardableResult
    func addSession(identity: String = "apple:reader") -> String {
        lock.withLock {
            counter += 1
            let token = "OTHER-DEVICE-\(counter)"
            live[token] = Session(id: Self.account(1000 + counter), account: accounts[identity]!.id)
            return token
        }
    }

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
            case ("POST", _):
                guard let action = Self.actions[request.path] else { return Self.error(404, "not-found") }
                let checked = authenticate(request, action: action)
                guard case .success(let fields) = checked else {
                    if case .failure(let refusal) = checked { return refusal.reply }
                    return Self.error(500, "internal")
                }
                _sessionBodies.append(request.body)
                return endpoint(action, fields)
            default:
                return Self.error(404, "not-found")
            }
        }
    }

    static let actions = [
        "/v1/auth/apple": "auth-apple", "/v1/auth/google": "auth-google", "/v1/auth/change": "auth-change",
        "/v1/auth/signout": "auth-signout", "/v1/auth/signout-all": "auth-signout-all", "/v1/account": "account",
        "/v1/account/delete": "account-delete", "/v1/session": "session", "/v1/delete-my-data": "delete-my-data",
    ]

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

    struct Refusal: Error { let reply: BackupCloudReply }

    /// The contract's checks in its order: body, challenge, assertion (or bypass); the fields
    /// with the challenge's nonce under `"nonce"`.
    private func authenticate(_ request: BackupCloudRequest, action: String) -> Result<[String: String], Refusal> {
        guard request.headers["content-type"] == "application/json",
              var body = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
              body["action"] == action, let challenge = body["challenge"] else {
            return .failure(Refusal(reply: Self.error(400, "bad-request")))
        }
        guard issued.remove(challenge) != nil else { return .failure(Refusal(reply: Self.error(401, "challenge-invalid"))) }
        if let bypass = request.headers["x-app-attest-bypass"] {
            guard bypass == Self.bypass else { return .failure(Refusal(reply: Self.error(401, "assertion-invalid"))) }
            _bypassed += 1
        } else {
            guard let keyID = request.headers["x-app-attest-key-id"],
                  let assertion = request.headers["x-app-attest-assertion"].flatMap({ Data(base64Encoded: $0) }) else {
                return .failure(Refusal(reply: Self.error(401, "assertion-invalid")))
            }
            guard registered.contains(keyID) else { return .failure(Refusal(reply: Self.error(401, "device-unknown"))) }
            if _rejectAssertions > 0 {
                _rejectAssertions -= 1
                return .failure(Refusal(reply: Self.error(401, "assertion-invalid")))
            }
            guard String(decoding: assertion, as: UTF8.self) == "fake-assertion:\(keyID):\(Self.hex(request.body))" else {
                return .failure(Refusal(reply: Self.error(401, "assertion-invalid")))
            }
        }
        body["nonce"] = Self.hex(Data(base64Encoded: challenge) ?? Data())
        return .success(body)
    }

    /// The identity an ID token from `FakeCloudIdentity` names ("apple:<subject>"), if it is
    /// for `provider` and carries `nonce`.
    private static func identity(_ token: String?, provider: String, nonce: String?) -> String? {
        let parts = (token ?? "").split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "fake-id-token", parts[1] == provider, parts[3] == nonce else { return nil }
        return "\(provider):\(parts[2])"
    }

    private func endpoint(_ action: String, _ fields: [String: String]) -> BackupCloudReply {
        if action == "auth-apple" || action == "auth-google" {
            let provider = action == "auth-apple" ? "apple" : "google"
            guard let identity = Self.identity(fields["idToken"], provider: provider, nonce: fields["nonce"]) else {
                return Self.error(401, "id-token-invalid")
            }
            if provider == "apple", fields["authorizationCode"] == nil { return Self.error(400, "bad-request") }
            var newAccount = false
            if accounts[identity] == nil {
                counter += 1
                accounts[identity] = Account(id: Self.account(counter), provider: provider, identity: identity,
                                             appAccountToken: UUID().uuidString.lowercased())
                newAccount = true
            }
            let account = accounts[identity]!
            if account.deleting { return Self.error(409, "account-deleting") }
            counter += 1
            let token = "SESSION-\(counter)-must-not-leak"
            let session = Session(id: Self.account(1000 + counter), account: account.id, label: fields["deviceLabel"])
            live[token] = session
            return .json(200, ["deviceSessionToken": token, "sessionId": session.id, "newAccount": newAccount,
                               "account": accountBody(account, current: session.id)])
        }
        guard let token = fields["deviceSessionToken"], let session = live[token],
              var account = accounts.values.first(where: { $0.id == session.account }) else {
            return Self.error(401, "session-invalid")
        }
        switch action {
        case "session":
            if account.deleting { return Self.error(409, "account-deleting") }
            if let failure = take(&_sessionFailure) { return Self.error(failure.status, failure.code, failure.subscription) }
            if !_hasSubscription {
                guard fields["signedTransaction"] != nil else { return Self.error(403, "not-subscribed") }
                _hasSubscription = true
            }
            return sessionReply()
        case "delete-my-data":
            return deleteMyData()
        case "account":
            if account.deleting { return Self.error(409, "account-deleting") }
            if let label = fields["deviceLabel"] { live[token]?.label = label }
            return .json(200, accountBody(account, current: session.id))
        case "auth-signout":
            live[token] = nil
            return .json(200, ["ok": true, "endedSessions": 1])
        case "auth-signout-all":
            let tokens = live.filter { $0.value.account == account.id }.map(\.key)
            for ended in tokens { live[ended] = nil }
            return .json(200, ["ok": true, "endedSessions": tokens.count])
        case "auth-change":
            guard let target = fields["newProvider"], target != account.provider, target == "apple" || target == "google" else {
                return Self.error(400, "bad-request")
            }
            if account.provider == "apple", fields["currentAuthorizationCode"] == nil { return Self.error(400, "bad-request") }
            guard let current = Self.identity(fields["currentIdToken"], provider: account.provider, nonce: fields["nonce"]),
                  let next = Self.identity(fields["newIdToken"], provider: target, nonce: fields["nonce"]) else {
                return Self.error(401, "id-token-invalid")
            }
            guard current == account.identity else { return Self.error(403, "identity-mismatch") }
            guard accounts[next] == nil else { return Self.error(409, "identity-in-use") }
            accounts[account.identity] = nil
            account.provider = target
            account.identity = next
            accounts[next] = account
            return .json(200, accountBody(account, current: session.id))
        case "account-delete":
            _accountDeleteCalls += 1
            if !account.deleting {
                guard let proof = Self.identity(fields["idToken"], provider: account.provider, nonce: fields["nonce"]) else {
                    return fields["idToken"] == nil ? Self.error(400, "bad-request") : Self.error(401, "id-token-invalid")
                }
                if account.provider == "apple", fields["authorizationCode"] == nil { return Self.error(400, "bad-request") }
                guard proof == account.identity else { return Self.error(403, "identity-mismatch") }
                account.deleting = true
                accounts[account.identity] = account
                for (other, value) in live where value.account == account.id && other != token { live[other] = nil }
            }
            let prefix = BackupCloudServiceFakeR2.prefix + "/"
            let keys = (r2?.keys ?? []).filter { $0.hasPrefix(prefix) }
            let batch = keys.prefix(_deleteBatch)
            for key in batch { r2?.remove(key) }
            let done = keys.count <= _deleteBatch
            if done {
                accounts[account.identity] = nil
                for (other, value) in live where value.account == account.id { live[other] = nil }
            }
            return .json(200, ["done": done, "deletedObjects": batch.count])
        default:
            return Self.error(404, "not-found")
        }
    }

    private func accountBody(_ account: Account, current: String) -> [String: Any] {
        let devices: [[String: Any]] = live.values.filter { $0.account == account.id }.sorted { $0.id < $1.id }.map {
            ["sessionId": $0.id, "createdAt": "2027-01-01T00:00:00.000Z", "lastUsedAt": "2027-01-15T08:00:00.000Z",
             "label": $0.label.map { $0 as Any } ?? NSNull(), "current": $0.id == current]
        }
        return ["accountId": account.id, "provider": account.provider, "appAccountToken": account.appAccountToken,
                "createdAt": "2027-01-01T00:00:00.000Z", "devices": devices, "subscription": _subscription,
                "usage": ["bytes": _usage.bytes, "allowanceBytes": _usage.allowance, "overAllowance": _usage.bytes > _usage.allowance,
                          "countedAt": "2027-01-15T08:00:00.000Z"]]
    }

    private func sessionReply() -> BackupCloudReply {
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

/// Apple's and Google's sign-in, faked: answers at once with `fake-id-token.<provider>.<subject>.<nonce>`,
/// which the fake Worker reads. The subject per provider is settable; `cancelNext` makes the
/// next request act as if the reader backed out.
@MainActor
final class FakeCloudIdentity: CloudIdentityProviding {
    var availableProviders: [CloudSignInProvider] = [.apple, .google]
    var subjects: [CloudSignInProvider: String] = [.apple: "reader", .google: "reader"]
    var cancelNext = false
    var appleEnded = false
    private(set) var requests: [(provider: CloudSignInProvider, nonce: String)] = []

    func credential(_ provider: CloudSignInProvider, nonce: String, anchor: ASPresentationAnchor?) async throws -> CloudIdentityCredential {
        requests.append((provider, nonce))
        if cancelNext {
            cancelNext = false
            throw CloudSignInError.cancelled
        }
        let subject = subjects[provider] ?? "reader"
        return CloudIdentityCredential(provider: provider, idToken: "fake-id-token.\(provider.rawValue).\(subject).\(nonce)",
                                       authorizationCode: provider == .apple ? "fake-code" : nil,
                                       email: "\(subject)@\(provider.rawValue).example", appleUserID: provider == .apple ? "apple-user" : nil)
    }

    func appleAuthorizationEnded(userID: String) async -> Bool { appleEnded }
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
    typealias W = BackupCloudServiceFakeWorker
    static let renewalJWS = "eyJhbGciOiJFUzI1NiJ9.RENEWAL-must-not-leak.c2ln"

    let r2: BackupCloudServiceFakeR2
    let worker: BackupCloudServiceFakeWorker
    let store: BackupCloudServiceFakeStore
    let attest: FakeAppAttestClient
    /// The key store every account shares (unless the rig was made with `keyStores`).
    let keyStore: InMemoryBackupKeyStore
    let sessionStore: InMemoryCloudDeviceSessionStore
    let identity: FakeCloudIdentity
    let clock: BackupCloudServiceClock
    let defaults: UserDefaults
    let scratch: URL
    let cloud: TactileCloudBackup

    var account: CloudBackupAccount { cloud.account }
    var signIn: CloudBackupSignIn { cloud.signIn }
    var destination: TactileCloudBackupDestination { cloud.destination }
    var connection: CloudBackupConnection { cloud.account.connection! }

    /// - Parameters:
    ///   - subscribed: whether StoreKit holds an active subscription (otherwise none ever).
    ///   - signedIn: whether the device starts signed in (to `W.account(1)`, with Apple).
    ///   - keyStores: each account's key; `nil`: one key store (`keyStore`) for every account.
    static func make(subscribed: Bool = true, key: BackupEncryptionKey? = nil, attestSupported: Bool = true,
                     bypass: String = "", signedIn: Bool = true,
                     keyStores: (any BackupKeyStoreFactory)? = nil) throws -> BackupCloudServiceRig {
        let r2 = BackupCloudServiceFakeR2()
        let worker = BackupCloudServiceFakeWorker(r2: r2)
        worker.hasSubscription = subscribed
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
        let sessionStore = InMemoryCloudDeviceSessionStore(signedIn ? Self.liveSession : nil)
        let identity = FakeCloudIdentity()
        let suite = "CloudRig-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let scratch = try BackupCloudFixtures.scratch()
        let configuration = BackupServiceConfiguration(host: W.host, productIDs: S.productID, attestBypass: bypass)!
        let cloud = TactileCloudBackup.make(configuration: configuration, store: store, attest: attest,
                                            keyStore: keyStores ?? keyStore, sessionStore: sessionStore, identity: identity,
                                            urlSession: worker.stub.session, s3Session: r2.stub.session,
                                            retryPolicy: S3RetryPolicy(maxAttempts: 1, sleep: { _ in }),
                                            temporaryDirectory: scratch.appendingPathComponent("tmp"), defaults: defaults,
                                            deviceName: { "Rig iPad" }, now: { clock.now })
        return BackupCloudServiceRig(r2: r2, worker: worker, store: store, attest: attest, keyStore: keyStore,
                                     sessionStore: sessionStore, identity: identity, clock: clock, defaults: defaults,
                                     scratch: scratch, cloud: cloud)
    }

    /// The session a signed-in rig starts with (the fake Worker's `liveToken`).
    static var liveSession: CloudDeviceSession {
        CloudDeviceSession(accountID: W.account(1), sessionID: W.account(1001), provider: .apple,
                           deviceSessionToken: W.liveToken, email: "reader@apple.example", appleUserID: "apple-user",
                           appAccountToken: UUID(uuidString: W.appAccountToken))
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
