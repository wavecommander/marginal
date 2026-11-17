import CryptoKit
import Foundation
import ReaderBackup

// Fakes for the cloud destination tests: a `URLProtocol` stub reached through its own
// `URLSession` (a header names the stub, so tests run in parallel against the same hosts), and
// small stateful fakes of Drive and S3 behind it. Nothing here touches the network.

/// A request as the stub received it.
nonisolated struct BackupCloudRequest: Sendable {
    var method: String
    var url: URL
    /// Lowercased names.
    var headers: [String: String]
    var body: Data

    var host: String { url.host() ?? "" }
    /// Decoded path.
    var path: String { url.path(percentEncoded: false) }
    var query: [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
    /// `application/x-www-form-urlencoded` body (no `+` handling: the clients encode spaces as %20).
    var form: [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }
}

nonisolated enum BackupCloudReply: Sendable {
    case http(Int, headers: [String: String] = [:], body: Data = Data())
    case fail(URLError.Code)

    static func json(_ status: Int, _ object: Any) -> BackupCloudReply {
        .http(status, headers: ["Content-Type": "application/json"],
              body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

/// One fake endpoint: every request on `session` goes to `handler`.
nonisolated final class BackupCloudStub: @unchecked Sendable {
    static let headerName = "X-Backup-Cloud-Stub"
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: BackupCloudStub] = [:]

    let id = UUID().uuidString
    let session: URLSession
    private let lock = NSLock()
    private var recorded: [BackupCloudRequest] = []
    private let handler: @Sendable (BackupCloudRequest) -> BackupCloudReply

    init(handler: @escaping @Sendable (BackupCloudRequest) -> BackupCloudReply) {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupCloudStubProtocol.self]
        configuration.httpAdditionalHeaders = [Self.headerName: id]
        session = URLSession(configuration: configuration)
        Self.registryLock.withLock { Self.registry[id] = self }
    }

    deinit { Self.registryLock.withLock { Self.registry[id] = nil } }

    static func stub(for id: String) -> BackupCloudStub? { registryLock.withLock { registry[id] } }

    var requests: [BackupCloudRequest] { lock.withLock { recorded } }

    func requests(_ method: String, pathPrefix: String) -> [BackupCloudRequest] {
        requests.filter { $0.method == method && $0.path.hasPrefix(pathPrefix) }
    }

    fileprivate func reply(_ request: BackupCloudRequest) -> BackupCloudReply {
        lock.withLock { recorded.append(request) }
        return handler(request)
    }
}

nonisolated final class BackupCloudStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: BackupCloudStub.headerName),
              let stub = BackupCloudStub.stub(for: id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name != BackupCloudStub.headerName {
            headers[name.lowercased()] = value
        }
        let recorded = BackupCloudRequest(method: request.httpMethod ?? "GET", url: url, headers: headers,
                                          body: request.httpBody ?? Self.read(request.httpBodyStream))
        switch stub.reply(recorded) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
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

/// A value shared with `@Sendable` closures.
nonisolated final class BackupCloudLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}

/// A fake that answers stub requests.
nonisolated protocol BackupCloudHandling: AnyObject, Sendable {
    func handleRequest(_ request: BackupCloudRequest) -> BackupCloudReply
}

/// A weak reference shared with a `@Sendable` closure (so a fake and its stub do not retain each other).
nonisolated final class BackupCloudWeakTarget: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: (any BackupCloudHandling)?
    var value: (any BackupCloudHandling)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated enum BackupCloudFixtures {
    static func sha256(_ data: Data) -> String { ContentHash.sha256(of: data) }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A scratch directory for one test.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    static let date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Snapshot names used by the cloud destinations' tests.
nonisolated enum BackupCloudNames {
    static let older = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_800_000_000), deviceName: "Ben’s iPad")
    static let newer = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_800_086_400), deviceName: "Ben’s iPad")
}

// MARK: - Fake S3

/// One bucket of an S3-compatible service, objects in memory, keyed by the decoded path after
/// `/<bucket>/` (prefix included). Signatures are not checked (S3Kit's own tests do that).
nonisolated final class BackupCloudFakeS3: BackupCloudHandling, @unchecked Sendable {
    struct Object {
        var data: Data
        var metadata: [String: String]
    }

    static let bucket = "backup-bucket"
    static let accessKeyID = "AKIDBACKUPCLOUDTEST"
    static let secret = "S3-SECRET/k+y=must-not-leak-42"

    private let lock = NSLock()
    private var objects: [String: Object] = [:]
    /// Every request is answered with this instead, when set.
    var override: BackupCloudReply? { get { lock.withLock { _override } } set { lock.withLock { _override = newValue } } }
    private var _override: BackupCloudReply?
    /// Flips a byte of every downloaded body.
    var corruptDownloads: Bool { get { lock.withLock { _corrupt } } set { lock.withLock { _corrupt = newValue } } }
    private var _corrupt = false
    /// Drops the last byte of every downloaded body and its length (a snapshot that changed size).
    var truncateDownloads: Bool { get { lock.withLock { _truncate } } set { lock.withLock { _truncate = newValue } } }
    private var _truncate = false

    let stub: BackupCloudStub

    init() {
        let target = BackupCloudWeakTarget()
        stub = BackupCloudStub { target.value?.handleRequest($0) ?? .http(599) }
        target.value = self
    }

    func handleRequest(_ request: BackupCloudRequest) -> BackupCloudReply { handle(request) }

    var keys: [String] { lock.withLock { objects.keys.sorted() } }
    func object(_ key: String) -> Object? { lock.withLock { objects[key] } }
    func put(_ key: String, _ data: Data, metadata: [String: String] = [:]) {
        lock.withLock { objects[key] = Object(data: data, metadata: metadata) }
    }

    static func error(_ status: Int, code: String, message: String = "message") -> BackupCloudReply {
        .http(status, headers: ["Content-Type": "application/xml"], body: Data(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message></Error>".utf8))
    }

    private func handle(_ request: BackupCloudRequest) -> BackupCloudReply {
        if let override { return override }
        return lock.withLock { () -> BackupCloudReply in
            let bucketPath = "/\(Self.bucket)"
            guard request.path.hasPrefix(bucketPath) else { return Self.error(404, code: "NoSuchBucket") }
            let key = String(request.path.dropFirst(bucketPath.count)).trimmingPrefix("/")
            if key.isEmpty, request.method == "GET" { return list(prefix: request.query["prefix"] ?? "") }
            let k = String(key)
            switch request.method {
            case "PUT":
                var metadata: [String: String] = [:]
                for (name, value) in request.headers where name.hasPrefix("x-amz-meta-") {
                    metadata[String(name.dropFirst("x-amz-meta-".count))] = value
                }
                objects[k] = Object(data: request.body, metadata: metadata)
                return .http(200, headers: ["ETag": "\"\(BackupCloudFixtures.md5(request.body))\""])
            case "HEAD":
                guard let object = objects[k] else { return .http(404) }
                var headers = ["Content-Length": String(object.data.count), "ETag": "\"\(BackupCloudFixtures.md5(object.data))\""]
                for (name, value) in object.metadata { headers["x-amz-meta-\(name)"] = value }
                return .http(200, headers: headers)
            case "GET":
                guard var data = objects[k]?.data else { return Self.error(404, code: "NoSuchKey") }
                if _corrupt, !data.isEmpty { data[data.count / 2] ^= 0xFF }
                if _truncate, !data.isEmpty { data.removeLast() }
                return .http(200, headers: ["Content-Length": String(data.count), "ETag": "\"etag\""], body: data)
            case "DELETE":
                objects[k] = nil
                return .http(204)
            default:
                return .http(405)
            }
        }
    }

    private func list(prefix: String) -> BackupCloudReply {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&apos;")
        }
        var xml = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        xml += "<Name>\(Self.bucket)</Name><Prefix>\(escape(prefix))</Prefix><IsTruncated>false</IsTruncated>"
        for key in objects.keys.sorted() where key.hasPrefix(prefix) {
            xml += "<Contents><Key>\(escape(key))</Key><LastModified>2026-11-15T09:00:00.000Z</LastModified>"
            xml += "<ETag>&quot;e&quot;</ETag><Size>\(objects[key]!.data.count)</Size><StorageClass>STANDARD</StorageClass></Contents>"
        }
        xml += "</ListBucketResult>"
        return .http(200, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
    }
}
