#if DEBUG
import CryptoKit
import Foundation
import ReaderBackup
import UIKit

// Tactile Texts Cloud for UI tests and screenshots, which cannot reach a Worker or the App
// Store: `-cloudBackupUITest <state>` builds `TactileCloudBackup` from the fakes below. Debug
// builds only; none of this exists in a release build.
//
// - StoreKit: `CloudBackupUITestStore`, one product at £2.99 a month; Subscribe succeeds at once.
// - The service: `CloudBackupUITestServer` behind a `URLProtocol`, answering the Worker's
//   contract (`/v1/challenge`, `/v1/session`, `/v1/delete-my-data`) and, for the storage, the
//   few S3 calls `S3BackupBlobStore` makes, kept as files in a temporary folder. App Attest is
//   unsupported, so the client sends the development bypass, which this fake accepts.
// - The key: `CloudBackupUITestKeyStore`, in memory. Seeded states hold a known key whose
//   recovery key is `CloudBackupUITestMode.recoveryKey`; UI tests type it.

/// The starting state `-cloudBackupUITest` names.
nonisolated enum CloudBackupUITestState: String, CaseIterable, Sendable {
    /// Never subscribed: the offer. Subscribing works.
    case notSubscribed
    /// Subscribed, nothing backed up, no key yet: the first backup makes one.
    case active
    /// Subscribed with two backups, over the allowance (restore and delete only).
    case overAllowance
    /// Ended five days ago, two backups: restore only, with dates.
    case readOnly
    /// Subscribed, two backups, no key on this iPad.
    case needsRecoveryKey
    /// Subscribed, two backups made with another key than this iPad's.
    case differentKey
    /// Ended long ago; backups kept until a date.
    case lapsed
    /// Refunded; backups deleted on a date.
    case revoked
    /// Ended and deleted.
    case dataDeleted
    /// The App Store can't be reached.
    case storeUnavailable
    /// Subscribed, but the service can't be reached.
    case unreachable
}

@MainActor
enum CloudBackupUITestMode {
    nonisolated static let argument = "-cloudBackupUITest"
    nonisolated static let productID = "software.tactile.texts.backup.standard"
    nonisolated static let groupID = "21800001"
    nonisolated static let serviceHost = "cloud.ui-test"
    nonisolated static let storageHost = "r2.ui-test"
    nonisolated static let bucket = "ui-test"
    nonisolated static let prefix = "users/ui-test/"
    /// The seeded backups' key, as a recovery key (UI tests type it).
    nonisolated static let recoveryKey = "0C51-260Z-4RPK-8ET2-9585-EQK5-DHSQ-N0C8-HYB9-V95B-PAWW-1HYE-TQE0-045G"
    /// Another valid recovery key, not the backups' (`differentKey` holds it; tests type it).
    nonisolated static let otherRecoveryKey = "CNS7-Z34S-MTSW-1KET-WZT0-23GV-50TM-4KTW-D5V8-744X-NAVW-9MEY-XFW0-R2A5"
    nonisolated static let defaultsSuite = "software.tactile.texts.cloud-backup-ui-test"

    /// Tactile Texts Cloud on fakes, in `state`; `nil` for a name that isn't a state.
    static func make(stateName: String) -> TactileCloudBackup? {
        guard let state = CloudBackupUITestState(rawValue: stateName) else { return nil }
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudBackupUITest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let backupsKey = try! BackupRecoveryKey(recoveryKey).encryptionKey
        let seeded: Bool
        let deviceKey: BackupEncryptionKey?
        switch state {
        case .notSubscribed, .active, .dataDeleted, .storeUnavailable, .unreachable:
            seeded = false
            deviceKey = nil
        case .needsRecoveryKey:
            seeded = true
            deviceKey = nil
        case .differentKey:
            seeded = true
            deviceKey = try! BackupRecoveryKey(otherRecoveryKey).encryptionKey
        case .overAllowance, .readOnly, .lapsed, .revoked:
            seeded = true
            deviceKey = backupsKey
        }

        let server = CloudBackupUITestServer.shared
        server.reset(root: root.appendingPathComponent("bucket", isDirectory: true), state: state, now: now)
        let seedDates = [now.addingTimeInterval(-86_400), now.addingTimeInterval(-8 * 86_400)]
        if seeded {
            server.seed(key: backupsKey, dates: seedDates, temporaryDirectory: root.appendingPathComponent("seed"))
        }

        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        if deviceKey != nil {
            defaults.set(true, forKey: CloudBackupAccount.recoveryKeyShownKey)
            defaults.set(true, forKey: CloudBackupAccount.recoveryKeySavedKey)
        }
        let lastSuccessKey = BackupService.lastSuccessKeyPrefix + TactileCloudBackupDestination.destinationID
        if seeded, deviceKey != nil {
            UserDefaults.standard.set(seedDates[0], forKey: lastSuccessKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastSuccessKey)
        }

        let configuration = BackupServiceConfiguration(host: serviceHost, productIDs: productID, attestBypass: "ui-test")!
        let session = CloudBackupUITestURLProtocol.session()
        return TactileCloudBackup.make(configuration: configuration, store: CloudBackupUITestStore(state: state, now: now),
                                       attest: CloudBackupUITestAttest(), keyStore: CloudBackupUITestKeyStore(key: deviceKey),
                                       urlSession: session, s3Session: session,
                                       temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                                       defaults: defaults)
    }
}

// MARK: - StoreKit

@MainActor
final class CloudBackupUITestStore: BackupStoreKit {
    private let state: CloudBackupUITestState
    private var history: [BackupStoreTransaction] = []
    private var statuses: [BackupStoreSubscriptionStatus] = []
    private var nextID: UInt64 = 100

    static let product = BackupStoreProduct(id: CloudBackupUITestMode.productID, displayName: "Cloud Backup",
                                            summary: "Encrypted backups of your library", displayPrice: "£2.99",
                                            subscriptionGroupID: CloudBackupUITestMode.groupID,
                                            period: .init(value: 1, unit: .month))

    init(state: CloudBackupUITestState, now: Date) {
        self.state = state
        switch state {
        case .notSubscribed, .storeUnavailable:
            break
        case .active, .overAllowance, .needsRecoveryKey, .differentKey, .unreachable:
            add(purchased: now.addingTimeInterval(-10 * 86_400), expires: now.addingTimeInterval(20 * 86_400), active: true)
        case .readOnly:
            add(purchased: now.addingTimeInterval(-35 * 86_400), expires: now.addingTimeInterval(-5 * 86_400), active: false)
        case .lapsed, .dataDeleted:
            add(purchased: now.addingTimeInterval(-100 * 86_400), expires: now.addingTimeInterval(-40 * 86_400), active: false)
        case .revoked:
            add(purchased: now.addingTimeInterval(-20 * 86_400), expires: now.addingTimeInterval(10 * 86_400), active: false,
                revoked: now.addingTimeInterval(-2 * 86_400))
        }
    }

    private func add(purchased: Date, expires: Date, active: Bool, revoked: Date? = nil) {
        nextID += 1
        let transaction = BackupStoreTransaction(id: nextID, originalID: 100, productID: CloudBackupUITestMode.productID,
                                                 purchaseDate: purchased, expirationDate: expires, revocationDate: revoked,
                                                 isVerified: true, jwsRepresentation: "ui-test.jws.\(nextID)")
        history.append(transaction)
        statuses = [BackupStoreSubscriptionStatus(state: active ? .subscribed : (revoked == nil ? .expired : .revoked),
                                                  transaction: transaction, willAutoRenew: active)]
    }

    func products(for ids: [String]) async throws -> [BackupStoreProduct] {
        if state == .storeUnavailable { throw BackupSubscriptionError.networkUnavailable }
        return ids.contains(Self.product.id) ? [Self.product] : []
    }

    func purchase(productID: String, confirmIn scene: UIScene?) async throws -> BackupStorePurchaseResult {
        try await Task.sleep(for: .milliseconds(300))
        let now = Date()
        add(purchased: now, expires: now.addingTimeInterval(30 * 86_400), active: true)
        CloudBackupUITestServer.shared.subscribed(now: now)
        return .success(history.last!)
    }

    func sync() async throws {}

    func transactions(for productIDs: Set<String>) async -> [BackupStoreTransaction] {
        history.filter { productIDs.contains($0.productID) }
    }

    func subscriptionStatuses(groupID: String) async throws -> [BackupStoreSubscriptionStatus] { statuses }

    func transactionUpdates() -> AsyncStream<BackupStoreTransaction> {
        AsyncStream { _ in }
    }

    func finish(_ transaction: BackupStoreTransaction) async {}
}

// MARK: - App Attest and the key

/// No App Attest (as in the simulator): the client sends the development bypass.
nonisolated struct CloudBackupUITestAttest: AppAttestClient {
    var isSupported: Bool { false }
    func keyID() async throws -> String { throw AppAttestError.unsupported }
    func attest(challenge: Data) async throws -> AppAttestation { throw AppAttestError.unsupported }
    func assertion(for clientData: Data) async throws -> AppAttestAssertion { throw AppAttestError.unsupported }
    func reset() async {}
}

nonisolated final class CloudBackupUITestKeyStore: BackupKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: BackupEncryptionKey?

    init(key: BackupEncryptionKey?) { self.key = key }

    func load() async throws -> BackupEncryptionKey? { lock.withLock { key } }

    func createKey() async throws -> BackupEncryptionKey {
        try lock.withLock {
            if key != nil { throw BackupKeyStoreError.keyAlreadyExists }
            let made = BackupEncryptionKey.generate()
            key = made
            return made
        }
    }

    func adoptKey(recoveryKey text: String) async throws -> BackupEncryptionKey {
        let adopted = try BackupRecoveryKey(text).encryptionKey
        lock.withLock { key = adopted }
        return adopted
    }

    func recoveryKey() async throws -> BackupRecoveryKey {
        guard let key = lock.withLock({ key }) else { throw BackupKeyStoreError.noKey }
        return key.recoveryKey
    }

    func removeKey() async throws { lock.withLock { key = nil } }
}

// MARK: - The service and its storage

/// The Worker's contract and a small S3 over a folder, for one process. Requests wait until
/// the seeded backups are written.
nonisolated final class CloudBackupUITestServer: @unchecked Sendable {
    static let shared = CloudBackupUITestServer()

    private let lock = NSLock()
    private let ready = DispatchGroup()
    private var root = FileManager.default.temporaryDirectory
    private var state = CloudBackupUITestState.active
    private var now = Date()
    private var challenges = 0
    private var uploads: [String: (key: String, parts: [Int: Data])] = [:]
    private var uploadCounter = 0

    func reset(root: URL, state: CloudBackupUITestState, now: Date) {
        lock.withLock {
            self.root = root
            self.state = state
            self.now = now
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A purchase in the fake store: the service now sees an active subscription.
    func subscribed(now: Date) {
        lock.withLock {
            if state == .notSubscribed || state == .readOnly || state == .lapsed || state == .dataDeleted {
                state = .active
                self.now = now
            }
        }
    }

    /// The reader's folder: `<root>/<bucket>/<prefix>`.
    private var folder: URL {
        lock.withLock { root }.appendingPathComponent(CloudBackupUITestMode.bucket, isDirectory: true)
            .appendingPathComponent(CloudBackupUITestMode.prefix, isDirectory: true)
    }

    /// Writes two empty backups encrypted with `key` (and with them the key check), in the
    /// background; requests wait for it.
    func seed(key: BackupEncryptionKey, dates: [Date], temporaryDirectory: URL) {
        let store = FolderBackupBlobStore(root: folder)
        ready.enter()
        Task.detached {
            defer { self.ready.leave() }
            try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let destination = EncryptedBackupDestination(id: TactileCloudBackupDestination.destinationID,
                                                         displayName: TactileCloudBackupDestination.name, store: store, key: key,
                                                         temporaryDirectory: temporaryDirectory)
            for date in dates {
                let archive = temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try BackupArchiveWriter.write(books: [], metadata: BackupMetadata(createdAt: date, appVersion: "1", appBuild: "1",
                                                                                      deviceName: "Reader’s iPad"),
                                                  includePDFs: false, to: archive)
                    try await destination.uploadSnapshot(from: archive, name: SnapshotName.make(createdAt: date, deviceName: "Reader’s iPad"),
                                                         progress: nil)
                } catch {
                    NSLog("Cloud backup UI test: seeding a backup failed: %@", error.localizedDescription)
                }
                try? FileManager.default.removeItem(at: archive)
            }
        }
    }

    // MARK: Requests

    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ status: Int, _ object: Any) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"],
                  body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    func handle(method: String, url: URL, body: Data) -> Reply {
        ready.wait()
        if url.host() == CloudBackupUITestMode.serviceHost { return service(method: method, path: url.path(), body: body) }
        return storage(method: method, url: url, body: body)
    }

    private func service(method: String, path: String, body: Data) -> Reply {
        let (state, now) = lock.withLock { (self.state, self.now) }
        switch (method, path) {
        case ("POST", "/v1/challenge"):
            let count = lock.withLock { challenges += 1; return challenges }
            return .json(200, ["challenge": Data("challenge-\(count)".utf8).base64EncodedString(),
                               "expiresAt": now.addingTimeInterval(300).formatted(.iso8601)])
        case ("POST", "/v1/session"):
            return session(state: state, now: now)
        case ("POST", "/v1/delete-my-data"):
            let deleted = (FileManager.default.subpaths(atPath: folder.path) ?? []).count
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return .json(200, ["done": true, "deletedObjects": deleted])
        default:
            return Self.error(404, "not-found")
        }
    }

    private func session(state: CloudBackupUITestState, now: Date) -> Reply {
        func iso(_ days: Double) -> String { now.addingTimeInterval(days * 86_400).formatted(.iso8601) }
        var subscription: [String: Any] = [
            "state": "active", "environment": "Xcode", "productId": CloudBackupUITestMode.productID,
            "expiresAt": iso(20), "endedAt": NSNull(), "readOnlyUntil": NSNull(), "deleteAfter": NSNull(),
        ]
        var mode = "read-write"
        var usage: (Int64, Int64) = (folderSize(), 10_000_000_000)
        switch state {
        case .unreachable:
            return Self.error(500, "internal")
        case .lapsed:
            subscription.merge(["state": "ended", "expiresAt": iso(-40), "endedAt": iso(-40), "deleteAfter": iso(20)]) { $1 }
            return Self.error(403, "subscription-lapsed", subscription)
        case .revoked:
            subscription.merge(["state": "revoked", "endedAt": iso(-2), "deleteAfter": iso(58)]) { $1 }
            return Self.error(403, "subscription-revoked", subscription)
        case .dataDeleted:
            subscription.merge(["state": "ended", "expiresAt": iso(-61), "endedAt": iso(-61)]) { $1 }
            return Self.error(410, "data-deleted", subscription)
        case .readOnly:
            mode = "read-only"
            subscription.merge(["state": "ended", "expiresAt": iso(-5), "endedAt": iso(-5), "readOnlyUntil": iso(25),
                                "deleteAfter": iso(55)]) { $1 }
        case .overAllowance:
            mode = "read-delete"
            usage = (10_400_000_000, 10_000_000_000)
        case .notSubscribed, .active, .needsRecoveryKey, .differentKey, .storeUnavailable:
            break
        }
        return .json(200, [
            "mode": mode,
            "credentials": ["accessKeyId": "UITEST", "secretAccessKey": "ui-test-secret", "sessionToken": "ui-test-token",
                            "expiresAt": Date().addingTimeInterval(900).formatted(.iso8601)],
            "storage": ["endpoint": "https://\(CloudBackupUITestMode.storageHost)", "host": CloudBackupUITestMode.storageHost,
                        "region": "auto", "bucket": CloudBackupUITestMode.bucket, "prefix": CloudBackupUITestMode.prefix],
            "subscription": subscription,
            "usage": ["bytes": usage.0, "allowanceBytes": usage.1, "overAllowance": usage.0 > usage.1,
                      "countedAt": now.formatted(.iso8601)],
        ])
    }

    private static func error(_ status: Int, _ code: String, _ subscription: [String: Any]? = nil) -> Reply {
        var body: [String: Any] = ["error": ["code": code, "message": "UI test: \(code)"]]
        if let subscription { body["subscription"] = subscription }
        return .json(status, body)
    }

    private func folderSize() -> Int64 {
        let base = folder
        return (FileManager.default.subpaths(atPath: base.path) ?? []).reduce(Int64(0)) { total, path in
            let size = (try? base.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    // MARK: Storage (path-style S3 over a folder)

    private func storage(method: String, url: URL, body: Data) -> Reply {
        let bucketPath = "/\(CloudBackupUITestMode.bucket)"
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(bucketPath) else { return Self.s3Error(404, "NoSuchBucket") }
        let key = String(path.dropFirst(bucketPath.count).drop { $0 == "/" })
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let bucketRoot = lock.withLock { root }.appendingPathComponent(CloudBackupUITestMode.bucket, isDirectory: true)
        if key.isEmpty, method == "GET" { return list(prefix: query["prefix"] ?? "", bucketRoot: bucketRoot) }
        guard !key.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return Self.s3Error(400, "InvalidKey") }
        let file = bucketRoot.appendingPathComponent(key, isDirectory: false)
        let manager = FileManager.default
        switch method {
        case "POST" where query["uploads"] != nil:
            let id = lock.withLock { uploadCounter += 1; uploads["u\(uploadCounter)"] = (key, [:]); return "u\(uploadCounter)" }
            return Self.xml("<InitiateMultipartUploadResult><Bucket>\(CloudBackupUITestMode.bucket)</Bucket><Key>\(Self.escape(key))</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
        case "PUT" where query["uploadId"] != nil:
            guard let id = query["uploadId"], let number = Int(query["partNumber"] ?? "") else { return Self.s3Error(404, "NoSuchUpload") }
            let found = lock.withLock { () -> Bool in
                guard uploads[id] != nil else { return false }
                uploads[id]!.parts[number] = body
                return true
            }
            return found ? Reply(status: 200, headers: ["ETag": Self.eTag(body)]) : Self.s3Error(404, "NoSuchUpload")
        case "POST" where query["uploadId"] != nil:
            guard let id = query["uploadId"], let upload = lock.withLock({ uploads.removeValue(forKey: id) }) else {
                return Self.s3Error(404, "NoSuchUpload")
            }
            let data = upload.parts.keys.sorted().reduce(into: Data()) { $0.append(upload.parts[$1]!) }
            guard write(data, to: bucketRoot.appendingPathComponent(upload.key)) else { return Self.s3Error(500, "InternalError") }
            return Self.xml("<CompleteMultipartUploadResult><Key>\(Self.escape(upload.key))</Key><ETag>\(Self.eTag(data))</ETag></CompleteMultipartUploadResult>")
        case "DELETE" where query["uploadId"] != nil:
            _ = lock.withLock { uploads.removeValue(forKey: query["uploadId"] ?? "") }
            return Reply(status: 204)
        case "PUT":
            guard write(body, to: file) else { return Self.s3Error(500, "InternalError") }
            return Reply(status: 200, headers: ["ETag": Self.eTag(body)])
        case "HEAD":
            guard let data = manager.contents(atPath: file.path) else { return Reply(status: 404) }
            return Reply(status: 200, headers: ["Content-Length": String(data.count), "ETag": Self.eTag(data)])
        case "GET":
            guard let data = manager.contents(atPath: file.path) else { return Self.s3Error(404, "NoSuchKey") }
            return Reply(status: 200, headers: ["Content-Length": String(data.count), "ETag": Self.eTag(data)], body: data)
        case "DELETE":
            try? manager.removeItem(at: file)
            return Reply(status: 204)
        default:
            return Reply(status: 405)
        }
    }

    private func write(_ data: Data, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func list(prefix: String, bucketRoot: URL) -> Reply {
        let keys = (FileManager.default.subpaths(atPath: bucketRoot.path) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return path.hasPrefix(prefix) && !(path as NSString).lastPathComponent.hasPrefix(".")
                && FileManager.default.fileExists(atPath: bucketRoot.appendingPathComponent(path).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }.sorted()
        var xml = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        xml += "<Name>\(CloudBackupUITestMode.bucket)</Name><Prefix>\(Self.escape(prefix))</Prefix><KeyCount>\(keys.count)</KeyCount><IsTruncated>false</IsTruncated>"
        for key in keys {
            let size = (try? bucketRoot.appendingPathComponent(key).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            xml += "<Contents><Key>\(Self.escape(key))</Key><LastModified>2026-11-15T09:00:00.000Z</LastModified>"
            xml += "<ETag>&quot;e&quot;</ETag><Size>\(size)</Size></Contents>"
        }
        xml += "</ListBucketResult>"
        return Reply(status: 200, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
    }

    private static func xml(_ body: String) -> Reply {
        Reply(status: 200, headers: ["Content-Type": "application/xml"],
              body: Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + body).utf8))
    }

    private static func s3Error(_ status: Int, _ code: String) -> Reply {
        Reply(status: status, headers: ["Content-Type": "application/xml"],
              body: Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(code)</Message></Error>".utf8))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func eTag(_ data: Data) -> String {
        "\"" + Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\""
    }
}

/// Answers every request to the fake hosts from `CloudBackupUITestServer`.
nonisolated final class CloudBackupUITestURLProtocol: URLProtocol, @unchecked Sendable {
    /// A session whose requests all go to the fake service and storage.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudBackupUITestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        [CloudBackupUITestMode.serviceHost, CloudBackupUITestMode.storageHost].contains(request.url?.host() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let reply = CloudBackupUITestServer.shared.handle(method: request.httpMethod ?? "GET", url: url, body: body)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty, request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
