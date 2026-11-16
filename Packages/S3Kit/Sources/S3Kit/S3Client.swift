import CryptoKit
import Foundation

/// A small client for one S3-compatible bucket (Amazon S3, Cloudflare R2, MinIO).
///
/// Every request goes over HTTPS (plain HTTP only to a loopback development endpoint; see
/// `S3Endpoint`) with path-style addressing, `https://<host>/<bucket>/<key>`, signed with
/// Signature Version 4 (payloads hashed, never `UNSIGNED-PAYLOAD`). Keys passed in and returned
/// are relative to the endpoint's prefix; they are NFC-normalized before use, as R2 does on its
/// side, so the same name means the same object on every service.
///
/// **Credentials.** Every request — each list page, each part of a multipart upload, its
/// completion or abort, each ranged download request, and every retry — is signed with what the
/// `credentialsProvider` returns at that moment, so a long transfer survives the credentials
/// changing underneath it. With temporary credentials (a session token), the token is sent and
/// signed as `X-Amz-Security-Token`, and:
/// - when the service says the credentials may have expired or be invalid (`Unauthorized`,
///   `ExpiredToken`, `InvalidToken`, a bodiless 401, or `SignatureDoesNotMatch`, which is what
///   R2 was measured to return for an expired temporary credential), the client tells the
///   provider (`credentialsRejected(_:)`), asks it again, and retries that request once; a
///   second such answer throws
///   `S3Error.authenticationFailed(code: S3Error.temporaryCredentialsRejectedCode, …)`;
/// - when it refuses the key or action (`AccessDenied`), the client throws
///   `S3Error.accessDenied(code: S3Error.notAllowedByCredentialsCode)` at once, without a retry
///   or a refresh;
/// - a bodiless 403 (a HEAD response) can mean either, so it gets one refresh and retry, and
///   becomes the "not allowed" error if fresh credentials are refused too.
/// Clock-skew codes keep their own error. Requests signed without a session token behave as they
/// always have.
///
/// Idempotent requests are retried on transient failures under `retryPolicy`;
/// `CreateMultipartUpload` is not (a retry could leave an orphaned upload). Cancelling the calling
/// task cancels the request in flight and throws `CancellationError`. Errors the credentials
/// provider throws are passed through unchanged. Everything else thrown is an `S3Error`.
public struct S3Client: Sendable {
    /// 16 MiB.
    public static let defaultPartSize: Int64 = 16 * 1024 * 1024
    /// 5 MiB, the S3 and R2 minimum for every part but the last.
    public static let minimumPartSize: Int64 = 5 * 1024 * 1024
    /// 5 GiB less 5 MiB: R2's limit for one request, just under Amazon S3's 5 GiB part limit.
    public static let maximumPartSize: Int64 = 5 * 1024 * 1024 * 1024 - 5 * 1024 * 1024
    /// 10,000 parts, the S3 and R2 limit.
    public static let maximumPartCount: Int64 = 10_000

    /// Where the bucket is.
    public let endpoint: S3Endpoint
    /// Who is asking: asked for credentials before every request.
    public let credentialsProvider: any S3CredentialsProvider
    public let retryPolicy: S3RetryPolicy
    let session: URLSession
    let now: @Sendable () -> Date

    /// A client for a bucket reached with long-lived keys (the developer destination).
    ///
    /// - Parameters:
    ///   - session: used for every request (inject one with a `URLProtocol` stub in tests).
    ///   - now: the signing clock.
    public init(configuration: S3Configuration, session: URLSession = .shared,
                retryPolicy: S3RetryPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(endpoint: configuration.endpoint,
                  credentialsProvider: S3StaticCredentialsProvider(configuration.credentials),
                  session: session, retryPolicy: retryPolicy, now: now)
    }

    /// A client for `endpoint`, signing each request with what `credentialsProvider` returns.
    ///
    /// - Parameters:
    ///   - session: used for every request (inject one with a `URLProtocol` stub in tests).
    ///   - now: the signing clock.
    public init(endpoint: S3Endpoint, credentialsProvider: any S3CredentialsProvider, session: URLSession = .shared,
                retryPolicy: S3RetryPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.credentialsProvider = credentialsProvider
        self.session = session
        self.retryPolicy = retryPolicy
        self.now = now
    }

    // MARK: Operations

    /// Every object whose key starts with `prefix` (relative to the endpoint's prefix; empty for
    /// everything under it), following `ListObjectsV2` continuation tokens to the end. Keys come
    /// back relative to the endpoint's prefix, in the service's order (UTF-8 binary order).
    public func list(prefix: String = "") async throws -> [S3ObjectSummary] {
        let base = endpoint.prefix.isEmpty ? "" : endpoint.prefix + "/"
        let fullPrefix = base + prefix.precomposedStringWithCanonicalMapping
        var objects: [S3ObjectSummary] = []
        var token: String?
        while true {
            var query: [(String, String?)] = [("list-type", "2")]
            if !fullPrefix.isEmpty { query.append(("prefix", fullPrefix)) }
            if let token { query.append(("continuation-token", token)) }
            let (data, _) = try await send(Request(method: "GET", key: nil, query: query), key: nil)
            let page: S3XML.ListPage
            do { page = try S3XML.listPage(from: data) } catch {
                throw S3Error.unexpectedResponse(status: 200, code: nil, message: "The object list couldn't be read.")
            }
            for object in page.objects where object.key.hasPrefix(base) {
                var relative = object
                relative.key = String(object.key.dropFirst(base.count))
                objects.append(relative)
            }
            guard page.isTruncated else { return objects }
            guard let next = page.nextContinuationToken, next != token else {
                throw S3Error.unexpectedResponse(status: 200, code: nil,
                                                 message: "The object list was cut short without a continuation token.")
            }
            token = next
        }
    }

    /// The object's size and user metadata, or `nil` when there is no such object.
    ///
    /// A HEAD response has no body, so a missing bucket also reads as `nil`, and Amazon S3 answers
    /// 403 rather than 404 for a missing object when the key lacks `s3:ListBucket`, which throws
    /// `accessDenied`.
    public func head(key: String) async throws -> S3ObjectHead? {
        let fullKey = try fullKey(for: key)
        let (_, response) = try await send(Request(method: "HEAD", key: fullKey), key: key, accepting: [404])
        if response.statusCode == 404 { return nil }
        let headers = Self.lowercasedHeaders(response)
        guard let size = headers["content-length"].flatMap({ Int64($0) }) else {
            throw S3Error.unexpectedResponse(status: response.statusCode, code: nil,
                                             message: "The object's size was missing.")
        }
        var metadata: [String: String] = [:]
        for (name, value) in headers where name.hasPrefix("x-amz-meta-") {
            metadata[String(name.dropFirst("x-amz-meta-".count))] = value
        }
        return S3ObjectHead(size: size, metadata: metadata, eTag: headers["etag"],
                            lastModified: headers["last-modified"].flatMap(Self.parseHTTPDate))
    }

    /// Stores a small object in one `PutObject`, replacing any object with that key.
    ///
    /// Metadata names must be lowercase letters, digits, `-`, `_` or `.`; values printable ASCII
    /// (the service trims surrounding spaces). Encode anything else before passing it.
    public func put(data: Data, key: String, metadata: [String: String] = [:]) async throws {
        let fullKey = try fullKey(for: key)
        var request = Request(method: "PUT", key: fullKey, signedHeaders: try Self.metadataHeaders(metadata),
                              body: .data(data), payloadSHA256: S3Signer.hex(SHA256.hash(data: data)))
        request.otherHeaders["Content-Type"] = "application/octet-stream"
        _ = try await send(request, key: key)
    }

    /// Deletes the object; succeeds when it is already absent.
    public func delete(key: String) async throws {
        let fullKey = try fullKey(for: key)
        let (data, response, credentials) = try await exchange(Request(method: "DELETE", key: fullKey), key: key,
                                                               accepting: [404])
        if response.statusCode == 404 {
            let service = S3XML.serviceError(from: data)
            guard let service, service.code != "NoSuchKey" else { return }
            throw S3Error.from(status: 404, code: service.code, message: service.message, bucket: endpoint.bucket,
                               key: key, redacting: credentials.redactions)
        }
    }

    // MARK: Requests

    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    struct Request: Sendable {
        var method: String
        /// The full key, prefix included; `nil` for a bucket-level request.
        var key: String?
        /// A `nil` value is sent as a bare name (`?uploads`), signed as `uploads=`.
        var query: [(String, String?)] = []
        var signedHeaders: [String: String] = [:]
        var otherHeaders: [String: String] = [:]
        var body: Body = .none
        var payloadSHA256: String = S3Signer.emptyPayloadSHA256
    }

    /// `<scheme>://<host>[:<port>][<basePath>]/<bucket>[/<key>][?<query>]`, the base path and key
    /// encoded once per segment and the query in canonical (sorted, encoded) order, so what is
    /// sent is exactly what is signed.
    func url(for request: Request) throws -> URL {
        var path = ""
        for segment in endpoint.basePath.split(separator: "/") { path += "/" + S3Signer.uriEncode(String(segment)) }
        path += "/" + S3Signer.uriEncode(endpoint.bucket)
        if let key = request.key { path += "/" + S3Signer.uriEncode(key, encodeSlash: false) }
        var pairs: [(name: String, value: String?)] = []
        for (name, value) in request.query {
            pairs.append((S3Signer.uriEncode(name), value.map { S3Signer.uriEncode($0) }))
        }
        pairs.sort { lhs, rhs in
            lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name
        }
        let query = pairs.map { pair -> String in
            guard let value = pair.value else { return pair.name }
            return pair.name + "=" + value
        }.joined(separator: "&")
        guard let url = URL(string: "\(endpoint.origin)\(path)\(query.isEmpty ? "" : "?" + query)") else {
            throw S3Error.unexpectedResponse(status: 0, code: "InvalidEndpoint",
                                             message: "The storage host isn't a valid host name.")
        }
        return url
    }

    /// The request, signed with `credentials` (and carrying their session token, if any).
    func urlRequest(for request: Request, credentials: S3Credentials) throws -> URLRequest {
        let url = try url(for: request)
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        urlRequest.httpMethod = request.method
        for (name, value) in request.otherHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in request.signedHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let signer = S3Signer(credentials: credentials, region: endpoint.region, now: now)
        let auth = signer.sign(method: request.method, url: url, headers: request.signedHeaders,
                               payloadSHA256: request.payloadSHA256)
        for (name, value) in auth { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    /// One attempt, signed afresh with `credentials`. Transport errors become `S3Error.noNetwork`
    /// (or `CancellationError`); the response is returned whatever its status.
    func perform(_ request: Request, credentials: S3Credentials) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try urlRequest(for: request, credentials: credentials)
        let result: (Data, URLResponse)
        do {
            switch request.body {
            case .none: result = try await session.data(for: urlRequest, delegate: RefuseRedirects.shared)
            case .data(let data): result = try await session.upload(for: urlRequest, from: data,
                                                                    delegate: RefuseRedirects.shared)
            case .file(let file): result = try await session.upload(for: urlRequest, fromFile: file,
                                                                    delegate: RefuseRedirects.shared)
            }
        } catch {
            throw S3Error.from(transport: error)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw S3Error.unexpectedResponse(status: 0, code: nil, message: "The response wasn't HTTP.")
        }
        return (result.0, response)
    }

    /// Sends `request`, retrying transient failures when `retrying`. A 2xx response or a status
    /// in `accepting` is returned; anything else is thrown as an `S3Error`.
    func send(_ request: Request, key: String?, accepting: Set<Int> = [], retrying: Bool = true)
        async throws -> (Data, HTTPURLResponse) {
        let (data, response, _) = try await exchange(request, key: key, accepting: accepting, retrying: retrying)
        return (data, response)
    }

    /// `send`, also returning the credentials the answered attempt was signed with.
    func exchange(_ request: Request, key: String?, accepting: Set<Int> = [], retrying: Bool = true)
        async throws -> (Data, HTTPURLResponse, S3Credentials) {
        try await withRetries(enabled: retrying) {
            try await withCredentials { credentials in
                let (data, response) = try await perform(request, credentials: credentials)
                if (200..<300).contains(response.statusCode) || accepting.contains(response.statusCode) {
                    return (data, response, credentials)
                }
                throw failure(status: response.statusCode, body: data, key: key, credentials: credentials)
            }
        }
    }

    /// Runs `attempt` with the provider's current credentials. When the service rejects their
    /// session token (`attempt` throws `SessionTokenRejected`), the provider is told, asked
    /// again, and `attempt` runs once more; a second rejection throws
    /// `authenticationFailed(code: temporaryCredentialsRejectedCode, …)`.
    func withCredentials<T: Sendable>(_ attempt: (S3Credentials) async throws -> T) async throws -> T {
        let first = try await credentialsProvider.credentials()
        do {
            return try await attempt(first)
        } catch is SessionTokenRejected {
            await credentialsProvider.credentialsRejected(first)
        }
        try Task.checkCancellation()
        let second = try await credentialsProvider.credentials()
        do {
            return try await attempt(second)
        } catch let rejection as SessionTokenRejected {
            await credentialsProvider.credentialsRejected(second)
            throw rejection.ifRepeated
        }
    }

    /// The error for a failed response to a request signed with `credentials`: with a session
    /// token, `SessionTokenRejected` for an expired or invalid token and
    /// `accessDenied(notAllowedByCredentialsCode)` for a refusal; otherwise the usual `S3Error`.
    func failure(status: Int, body: Data, key: String?, credentials: S3Credentials) -> any Error {
        let service = S3XML.serviceError(from: body)
        return failure(status: status, code: service?.code, message: service?.message, key: key, credentials: credentials)
    }

    func failure(status: Int, code: String?, message: String?, key: String?, credentials: S3Credentials) -> any Error {
        if credentials.sessionToken != nil {
            let notAllowed = S3Error.accessDenied(code: S3Error.notAllowedByCredentialsCode)
            if let code {
                if S3Error.sessionTokenRejectedCodes.contains(code) {
                    return SessionTokenRejected(ifRepeated: .temporaryCredentialsRejected)
                }
                if S3Error.notAllowedCodes.contains(code) { return notAllowed }
            } else {
                if status == 401 { return SessionTokenRejected(ifRepeated: .temporaryCredentialsRejected) }
                // A bodiless 403 (HEAD) is either an expired credential (R2 answers those with 403
                // SignatureDoesNotMatch) or a refusal (403 AccessDenied): refresh once, and if fresh
                // credentials are refused too, it was a refusal.
                if status == 403 { return SessionTokenRejected(ifRepeated: notAllowed) }
            }
        }
        return S3Error.from(status: status, code: code, message: message, bucket: endpoint.bucket, key: key,
                            redacting: credentials.redactions)
    }

    /// Runs `operation`, repeating it after a backoff while it throws a transient `S3Error`,
    /// up to `retryPolicy.maxAttempts` attempts.
    func withRetries<T: Sendable>(enabled: Bool = true, _ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as S3Error where enabled && error.isTransient && attempt < retryPolicy.maxAttempts {
                try await retryPolicy.sleep(retryPolicy.delay(beforeRetry: attempt))
                attempt += 1
            }
        }
    }

    // MARK: Keys and headers

    /// The key with the endpoint's prefix, NFC-normalized and checked: not empty, no empty, `.` or
    /// `..` segments (URL handling could rewrite them), no control characters, at most 1,024 bytes.
    func fullKey(for key: String) throws -> String {
        let normalized = key.precomposedStringWithCanonicalMapping
        let full = endpoint.prefix.isEmpty ? normalized : endpoint.prefix + "/" + normalized
        let segments = full.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty, full.utf8.count <= 1024,
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !full.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw S3Error.invalidKey(key: key)
        }
        return full
    }

    static func metadataHeaders(_ metadata: [String: String]) throws -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in metadata {
            let lower = name.lowercased()
            let nameOK = !lower.isEmpty && lower.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == "."
            }
            let valueOK = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
            guard nameOK, valueOK else { throw S3Error.invalidMetadata(name: name) }
            headers["x-amz-meta-\(lower)"] = value
        }
        return headers
    }

    static func lowercasedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name.lowercased()] = "\(value)"
        }
        return headers
    }

    /// An HTTP date (`Wed, 12 Oct 2009 17:50:00 GMT`).
    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// Thrown inside one attempt when the service refused temporary credentials in a way that may
/// mean they expired; `withCredentials` (or the download loop) turns it into a refresh and one
/// retry, and throws `ifRepeated` when fresh credentials are refused too. Never escapes the client.
struct SessionTokenRejected: Error {
    var ifRepeated: S3Error
}

extension S3Error {
    /// What a request rejected for its session token twice in a row throws.
    static let temporaryCredentialsRejected = S3Error.authenticationFailed(code: temporaryCredentialsRejectedCode,
                                                                           clockSkewed: false)
}

/// Redirects are not followed: a signed request re-sent to another host would only fail its
/// signature, and S3's 301/307 mean the host or region is configured wrongly.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefuseRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
