import Foundation
import Testing
@testable import GoogleSignInKit

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
        var form: [String: String] { FormEncoding.decodeQuery(String(decoding: body, as: UTF8.self)) }
        var bodyString: String { String(decoding: body, as: UTF8.self) }
    }

    enum Reply: Sendable {
        case http(Int, headers: [String: String] = [:], body: Data = Data())
        /// Fails before any response.
        case drop(URLError.Code)
        /// Never answers (until cancelled).
        case hang
    }

    private struct Expectation {
        let method: String
        let urlPrefix: String
        let reply: Reply
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

    func expect(_ method: String, _ urlPrefix: String, _ reply: Reply) {
        lock.withLock { script.append(Expectation(method: method, urlPrefix: urlPrefix, reply: reply)) }
    }

    var requests: [Request] { lock.withLock { recorded } }

    /// Fails the test on any unexpected request or any scripted request that never came.
    func verify(sourceLocation: SourceLocation = #_sourceLocation) {
        let (unexpected, remaining) = lock.withLock {
            (unexpectedRequests.map { "\($0.method) \($0.url)" }, script.map { "\($0.method) \($0.urlPrefix)" })
        }
        #expect(unexpected == [], "unexpected requests", sourceLocation: sourceLocation)
        #expect(remaining == [], "scripted requests that never came", sourceLocation: sourceLocation)
    }

    fileprivate func handle(_ request: Request) -> Reply {
        lock.withLock {
            recorded.append(request)
            guard let next = script.first, next.method == request.method,
                  request.url.absoluteString.hasPrefix(next.urlPrefix) else {
                unexpectedRequests.append(request)
                return .http(599, body: Data("unexpected request".utf8))
            }
            script.removeFirst()
            return next.reply
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
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
        switch server.handle(recorded) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .drop(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

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

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

let testClientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
let testScheme = "com.googleusercontent.apps.123456789012-abcdefghijklmnop"
let testRedirectURI = "\(testScheme):/oauthredirect"
let testConfiguration = GoogleSignInConfiguration(clientID: testClientID)!
let tokenURL = "https://oauth2.googleapis.com/token"
/// RFC 7636 appendix B.
let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

/// An unsigned (`alg: none`) JWT with the given payload, the way a test would hand-make one.
func unsignedJWT(_ payload: [String: Any], signature: String = "") -> String {
    let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLEncodedString
    return "\(header).\(json(payload).base64URLEncodedString).\(signature)"
}

func redirect(_ query: String) -> URL {
    URL(string: "\(testRedirectURI)?\(query)")!
}
