import Foundation
import Testing
@testable import GoogleDriveKit

/// A scripted HTTP server behind a `URLProtocol`. Each test gets its own server and `URLSession`;
/// requests must arrive in the scripted order and match the scripted method and URL prefix.
/// Anything else is recorded as unexpected, answered with a 599, and fails ``verify()``.
final class StubServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var query: [String: String] { FormEncoding.decodeQuery(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery) }
        var form: [String: String] { FormEncoding.decodeQuery(String(decoding: body, as: UTF8.self)) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var urlWithoutQuery: String { url.absoluteString.components(separatedBy: "?")[0] }
    }

    enum Reply: Sendable {
        case http(Int, headers: [String: String] = [:], body: Data = Data())
        /// Fails before any response.
        case drop(URLError.Code)
        /// Sends the response and part of the body, then fails.
        case partial(Int, headers: [String: String] = [:], body: Data, then: URLError.Code)
        /// Sends the response and part of the body, then never finishes (until cancelled).
        case hang(Int, headers: [String: String] = [:], body: Data)
    }

    private struct Expectation {
        let method: String
        let urlPrefix: String
        let delay: TimeInterval
        let reply: @Sendable (Request) -> Reply
    }

    static let headerName = "X-Stub-Server"
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: StubServer] = [:]

    let id = UUID().uuidString
    let session: URLSession
    private let lock = NSLock()
    private var script: [Expectation] = []
    private var recorded: [Request] = []
    private var unexpectedRequests: [Request] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = [Self.headerName: id]
        session = URLSession(configuration: configuration)
        Self.registryLock.withLock { Self.registry[id] = self }
    }

    deinit {
        Self.registryLock.withLock { Self.registry[id] = nil }
    }

    static func server(for id: String) -> StubServer? { registryLock.withLock { registry[id] } }

    func expect(_ method: String, _ urlPrefix: String, delay: TimeInterval = 0,
                reply: @escaping @Sendable (Request) -> Reply) {
        lock.withLock { script.append(Expectation(method: method, urlPrefix: urlPrefix, delay: delay, reply: reply)) }
    }

    func expect(_ method: String, _ urlPrefix: String, delay: TimeInterval = 0, _ reply: Reply) {
        expect(method, urlPrefix, delay: delay) { _ in reply }
    }

    var requests: [Request] { lock.withLock { recorded } }
    var unexpectedCount: Int { lock.withLock { unexpectedRequests.count } }

    func requests(_ method: String, _ urlPrefix: String) -> [Request] {
        requests.filter { $0.method == method && $0.url.absoluteString.hasPrefix(urlPrefix) }
    }

    /// Fails the test on any unexpected request or any scripted request that never came.
    func verify(sourceLocation: SourceLocation = #_sourceLocation) {
        let (unexpected, remaining) = lock.withLock {
            (unexpectedRequests.map { "\($0.method) \($0.url)" }, script.map { "\($0.method) \($0.urlPrefix)" })
        }
        #expect(unexpected == [], "unexpected requests", sourceLocation: sourceLocation)
        #expect(remaining == [], "scripted requests that never came", sourceLocation: sourceLocation)
    }

    fileprivate func handle(_ request: Request) -> (Reply, TimeInterval) {
        lock.withLock {
            recorded.append(request)
            guard let next = script.first, next.method == request.method,
                  request.url.absoluteString.hasPrefix(next.urlPrefix) else {
                unexpectedRequests.append(request)
                return (.http(599, body: Data("unexpected request".utf8)), 0)
            }
            script.removeFirst()
            return (next.reply(request), next.delay)
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: StubServer.headerName), let server = StubServer.server(for: id),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name != StubServer.headerName {
            headers[name.lowercased()] = value
        }
        let recorded = StubServer.Request(method: request.httpMethod ?? "GET", url: url, headers: headers,
                                          body: request.httpBody ?? Self.read(request.httpBodyStream))
        let (reply, delay) = server.handle(recorded)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in deliver(reply, url: url) }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    private func deliver(_ reply: StubServer.Reply, url: URL) {
        guard !isStopped, let client else { return }
        func respond(_ status: Int, _ headers: [String: String]) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        switch reply {
        case .http(let status, let headers, let body):
            respond(status, headers)
            if !body.isEmpty { client.urlProtocol(self, didLoad: body) }
            client.urlProtocolDidFinishLoading(self)
        case .drop(let code):
            client.urlProtocol(self, didFailWithError: URLError(code))
        case .partial(let status, let headers, let body, let code):
            respond(status, headers)
            client.urlProtocol(self, didLoad: body)
            // Let the body reach the reader before the failure.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                guard !isStopped else { return }
                client.urlProtocol(self, didFailWithError: URLError(code))
            }
        case .hang(let status, let headers, let body):
            respond(status, headers)
            client.urlProtocol(self, didLoad: body)
        }
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Helpers

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func driveFileJSON(id: String, name: String, mimeType: String = "application/pdf", size: Int64? = nil,
                   sha256: String? = nil, md5: String? = nil, parents: [String] = [],
                   appProperties: [String: String]? = nil, trashed: Bool = false,
                   createdTime: String = "2026-11-01T10:00:00.000Z") -> [String: Any] {
    var file: [String: Any] = ["id": id, "name": name, "mimeType": mimeType, "parents": parents,
                               "trashed": trashed, "createdTime": createdTime, "modifiedTime": createdTime]
    if let size { file["size"] = String(size) }
    if let sha256 { file["sha256Checksum"] = sha256 }
    if let md5 { file["md5Checksum"] = md5 }
    if let appProperties { file["appProperties"] = appProperties }
    return file
}

func driveError(_ code: Int, reason: String, message: String = "error") -> Data {
    json(["error": ["code": code, "message": message,
                    "errors": [["domain": "global", "reason": reason, "message": message]]]])
}

let testClientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
let testConfiguration = GoogleOAuthConfiguration(clientID: testClientID)!
let tokenURL = "https://oauth2.googleapis.com/token"
let filesURL = "https://www.googleapis.com/drive/v3/files"
let uploadURL = "https://www.googleapis.com/upload/drive/v3/files"

/// Everything a Drive test needs: a stub server, a signed-in auth session with a fixed clock, a
/// client whose retries record their waits instead of sleeping.
struct Harness {
    let server = StubServer()
    let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    let sleeps = Locked<[Duration]>([])
    let store: InMemoryGoogleTokenStore
    let auth: GoogleAuthSession
    let client: GoogleDriveClient

    init(tokens: GoogleTokenSet? = .valid, maxAttempts: Int = 4) {
        store = InMemoryGoogleTokenStore(tokens)
        let clock = clock
        auth = GoogleAuthSession(configuration: testConfiguration, tokenStore: store, urlSession: server.session,
                                 now: { clock.value })
        let sleeps = sleeps
        client = GoogleDriveClient(
            auth: auth, urlSession: server.session,
            retryPolicy: GoogleRetryPolicy(maxAttempts: maxAttempts, sleep: { duration in sleeps.mutate { $0.append(duration) } },
                                           random: { 0.5 }))
    }
}

extension GoogleTokenSet {
    /// Expires an hour after the harness clock's start.
    static let valid = GoogleTokenSet(accessToken: "access-1", expiresAt: Date(timeIntervalSince1970: 1_800_003_600),
                                      refreshToken: "refresh-1", grantedScopes: [GoogleDriveScope.driveFile])
}

func tokenResponse(_ accessToken: String, expiresIn: Int = 3599, refreshToken: String? = nil,
                   scope: String = GoogleDriveScope.driveFile) -> StubServer.Reply {
    var body: [String: Any] = ["access_token": accessToken, "expires_in": expiresIn, "scope": scope, "token_type": "Bearer"]
    if let refreshToken { body["refresh_token"] = refreshToken }
    return .http(200, headers: ["Content-Type": "application/json"], body: json(body))
}

/// Temporary directory removed at deinit.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("GoogleDriveKitTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: Data) -> URL {
        let file = url.appendingPathComponent(name)
        try! contents.write(to: file)
        return file
    }

    var contents: [String] { (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] }
}

/// Deterministic pseudo-random bytes.
func testBytes(_ count: Int, seed: UInt64 = 42) -> Data {
    var state = seed
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        for index in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            buffer[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    return data
}
