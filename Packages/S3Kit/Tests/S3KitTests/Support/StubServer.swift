import Foundation
import Testing
@testable import S3Kit

/// A request as the stub received it.
struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data

    /// The percent-encoded path and query exactly as sent: `/bucket/key?a=b`.
    var target: String {
        let query = url.query(percentEncoded: true)
        return url.path(percentEncoded: true) + (query.map { "?" + $0 } ?? "")
    }
}

/// How the stub answers one request.
enum StubReply: Sendable {
    case respond(status: Int, headers: [String: String] = [:], body: Data = Data())
    /// Fails before any response.
    case fail(URLError.Code)
    /// Sends the response head and `body`, then fails with `error` (a dropped connection).
    case partial(status: Int, headers: [String: String], body: Data, error: URLError.Code)
    /// Sends the response head and `body`, then never finishes (until the task is cancelled).
    case stall(status: Int, headers: [String: String], body: Data)
    /// Never answers (until the task is cancelled).
    case hang

    static func ok(_ body: String = "", headers: [String: String] = [:]) -> StubReply {
        .respond(status: 200, headers: headers, body: Data(body.utf8))
    }

    static func xml(_ status: Int, _ body: String, headers: [String: String] = [:]) -> StubReply {
        .respond(status: status, headers: headers.merging(["Content-Type": "application/xml"]) { a, _ in a },
                 body: Data(body.utf8))
    }

    static func error(_ status: Int, code: String, message: String = "message") -> StubReply {
        xml(status, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message>"
            + "<RequestId>RID</RequestId></Error>")
    }
}

/// One fake S3 endpoint, reached through its own `URLSession` and its own unique host, so tests
/// run in parallel without sharing state.
///
/// Requests are answered by an ordered script of expectations (method and exact path + query),
/// then by an optional `handler`. Anything else is recorded as unexpected and answered with HTTP
/// 418, and `verify()` fails the test for it and for any expectation left unmet.
final class StubServer: @unchecked Sendable {
    struct Expectation {
        var method: String
        var target: String
        var reply: @Sendable (RecordedRequest) -> StubReply
        var sourceLocation: SourceLocation
    }

    static let secret = "SECRET/k+y=Do-Not-Leak-7Q9"
    static let accessKeyID = "AKIDTESTEXAMPLE"
    static let bucket = "backup-bucket"

    let host = "s3-\(UUID().uuidString.lowercased()).stub.test"
    let session: URLSession
    private let lock = NSLock()
    private var script: [Expectation] = []
    private var handler: (@Sendable (RecordedRequest) -> StubReply?)?
    private var recorded: [RecordedRequest] = []
    private var unexpectedRequests: [RecordedRequest] = []
    private let stalls: AsyncStream<RecordedRequest>
    private let stallContinuation: AsyncStream<RecordedRequest>.Continuation
    private(set) var sleeps: [Duration] { get { lock.withLock { _sleeps } } set { lock.withLock { _sleeps = newValue } } }
    private var _sleeps: [Duration] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        (stalls, stallContinuation) = AsyncStream<RecordedRequest>.makeStream()
        StubProtocol.register(self, for: host)
    }

    deinit { StubProtocol.unregister(host) }

    func configuration(prefix: String = "app/ipad") -> S3Configuration {
        S3Configuration(host: host, region: "auto", bucket: Self.bucket, accessKeyID: Self.accessKeyID,
                        secretAccessKey: Self.secret, prefix: prefix)!
    }

    /// A client whose retries don't wait (the waits are recorded in `sleeps`).
    func client(prefix: String = "app/ipad", maxAttempts: Int = 4) -> S3Client {
        let policy = S3RetryPolicy(maxAttempts: maxAttempts, initialDelay: .milliseconds(100), maximumDelay: .seconds(2),
                                   sleep: { [weak self] duration in
                                       self?.sleeps.append(duration)
                                       try Task.checkCancellation()
                                   }, random: { 1 })
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        return S3Client(configuration: configuration(prefix: prefix), session: session, retryPolicy: policy,
                        now: { date })
    }

    func expect(_ method: String, _ target: String, sourceLocation: SourceLocation = #_sourceLocation,
                reply: @escaping @Sendable (RecordedRequest) -> StubReply) {
        lock.withLock { script.append(Expectation(method: method, target: target, reply: reply,
                                                  sourceLocation: sourceLocation)) }
    }

    func expect(_ method: String, _ target: String, sourceLocation: SourceLocation = #_sourceLocation,
                _ reply: StubReply) {
        expect(method, target, sourceLocation: sourceLocation) { _ in reply }
    }

    /// Answers requests the script doesn't cover; returning `nil` makes a request unexpected.
    func handle(_ handler: @escaping @Sendable (RecordedRequest) -> StubReply?) {
        lock.withLock { self.handler = handler }
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    /// The next request answered with `.hang` or `.stall`.
    func nextStall() async -> RecordedRequest? {
        var iterator = stalls.makeAsyncIterator()
        return await iterator.next()
    }

    /// Fails the test for unexpected requests, unmet expectations, and any header or URL that
    /// carries the secret.
    func verify(sourceLocation: SourceLocation = #_sourceLocation) {
        let (unexpected, remaining, all) = lock.withLock { (unexpectedRequests, script, recorded) }
        for request in unexpected {
            Issue.record("Unexpected request: \(request.method) \(request.target)", sourceLocation: sourceLocation)
        }
        for expectation in remaining {
            Issue.record("Expected request never came: \(expectation.method) \(expectation.target)",
                         sourceLocation: expectation.sourceLocation)
        }
        for request in all {
            #expect(!request.url.absoluteString.contains(Self.secret), sourceLocation: sourceLocation)
            for (name, value) in request.headers {
                #expect(!value.contains(Self.secret), "header \(name) carries the secret", sourceLocation: sourceLocation)
            }
        }
    }

    fileprivate func reply(to request: RecordedRequest) -> StubReply {
        lock.withLock {
            recorded.append(request)
            if let next = script.first, next.method == request.method, next.target == request.target {
                script.removeFirst()
                return next.reply(request)
            }
            if let handler, let reply = handler(request) { return reply }
            unexpectedRequests.append(request)
            return .respond(status: 418, headers: [:], body: Data())
        }
    }

    fileprivate func stalled(_ request: RecordedRequest) {
        stallContinuation.yield(request)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: StubServer, for host: String) { lock.withLock { servers[host] = server } }
    static func unregister(_ host: String) { lock.withLock { _ = servers.removeValue(forKey: host) } }
    static func server(for host: String?) -> StubServer? { lock.withLock { host.flatMap { servers[$0] } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: url.host()) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let recorded = RecordedRequest(method: request.httpMethod ?? "GET", url: url, headers: headers,
                                       body: Self.body(of: request))
        switch server.reply(to: recorded) {
        case .respond(let status, let headers, let body):
            send(status: status, headers: headers, url: url)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .partial(let status, let headers, let body, let error):
            send(status: status, headers: headers, url: url)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            // The connection drops a moment later, on the loading thread, as a real one would:
            // failing in the same turn makes URLSession discard the bytes it hasn't delivered yet.
            pendingError = URLError(error)
            let loading = LoadingThread(thread: Thread.current)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                perform(#selector(failPending), on: loading.thread, with: nil, waitUntilDone: false)
            }
        case .stall(let status, let headers, let body):
            send(status: status, headers: headers, url: url)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            server.stalled(recorded)
        case .hang:
            server.stalled(recorded)
        }
    }

    /// The thread a load started on, which URLProtocol client calls must be made on.
    private struct LoadingThread: @unchecked Sendable { let thread: Thread }

    override func stopLoading() { pendingError = nil }

    private var pendingError: URLError?

    @objc private func failPending() {
        guard let pendingError else { return }
        self.pendingError = nil
        client?.urlProtocol(self, didFailWithError: pendingError)
    }

    private func send(status: Int, headers: [String: String], url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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
