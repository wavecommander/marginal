import CryptoKit
import Foundation

/// A small client for one S3-compatible bucket (Amazon S3, Cloudflare R2, MinIO).
///
/// Every request goes over HTTPS with path-style addressing, `https://<host>/<bucket>/<key>`,
/// signed with Signature Version 4 (payloads hashed, never `UNSIGNED-PAYLOAD`). Keys passed in and
/// returned are relative to the configuration's prefix; they are NFC-normalized before use, as R2
/// does on its side, so the same name means the same object on every service.
///
/// Idempotent requests are retried on transient failures under `retryPolicy`;
/// `CreateMultipartUpload` is not (a retry could leave an orphaned upload). Cancelling the calling
/// task cancels the request in flight and throws `CancellationError`. Everything else thrown is an
/// `S3Error`.
public struct S3Client: Sendable {
    /// 16 MiB.
    public static let defaultPartSize: Int64 = 16 * 1024 * 1024
    /// 5 MiB, the S3 and R2 minimum for every part but the last.
    public static let minimumPartSize: Int64 = 5 * 1024 * 1024
    /// 5 GiB less 5 MiB: R2's limit for one request, just under Amazon S3's 5 GiB part limit.
    public static let maximumPartSize: Int64 = 5 * 1024 * 1024 * 1024 - 5 * 1024 * 1024
    /// 10,000 parts, the S3 and R2 limit.
    public static let maximumPartCount: Int64 = 10_000

    public let configuration: S3Configuration
    public let retryPolicy: S3RetryPolicy
    let session: URLSession
    let signer: S3Signer

    /// - Parameters:
    ///   - session: used for every request (inject one with a `URLProtocol` stub in tests).
    ///   - now: the signing clock.
    public init(configuration: S3Configuration, session: URLSession = .shared,
                retryPolicy: S3RetryPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.session = session
        self.retryPolicy = retryPolicy
        self.signer = S3Signer(configuration: configuration, now: now)
    }

    // MARK: Operations

    /// Every object whose key starts with `prefix` (relative to the configured prefix; empty for
    /// everything under it), following `ListObjectsV2` continuation tokens to the end. Keys come
    /// back relative to the configured prefix, in the service's order (UTF-8 binary order).
    public func list(prefix: String = "") async throws -> [S3ObjectSummary] {
        let base = configuration.prefix.isEmpty ? "" : configuration.prefix + "/"
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
        let (data, response) = try await send(Request(method: "DELETE", key: fullKey), key: key, accepting: [404])
        if response.statusCode == 404 {
            let code = S3XML.serviceError(from: data)?.code
            guard code == nil || code == "NoSuchKey" else {
                throw S3Error.from(status: 404, body: data, bucket: configuration.bucket, key: key,
                                   secret: configuration.secretAccessKey)
            }
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

    /// `https://<host>/<bucket>[/<key>][?<query>]`, the key encoded once per segment and the
    /// query in canonical (sorted, encoded) order, so what is sent is exactly what is signed.
    func url(for request: Request) throws -> URL {
        var path = "/" + S3Signer.uriEncode(configuration.bucket)
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
        guard let url = URL(string: "https://\(configuration.host)\(path)\(query.isEmpty ? "" : "?" + query)") else {
            throw S3Error.unexpectedResponse(status: 0, code: "InvalidEndpoint",
                                             message: "The storage host isn't a valid host name.")
        }
        return url
    }

    func urlRequest(for request: Request) throws -> URLRequest {
        let url = try url(for: request)
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        urlRequest.httpMethod = request.method
        for (name, value) in request.otherHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in request.signedHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let auth = signer.sign(method: request.method, url: url, headers: request.signedHeaders,
                               payloadSHA256: request.payloadSHA256)
        for (name, value) in auth { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    /// One attempt, signed afresh. Transport errors become `S3Error.noNetwork` (or
    /// `CancellationError`); the response is returned whatever its status.
    func perform(_ request: Request) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try urlRequest(for: request)
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
        try await withRetries(enabled: retrying) {
            let (data, response) = try await perform(request)
            if (200..<300).contains(response.statusCode) || accepting.contains(response.statusCode) {
                return (data, response)
            }
            throw S3Error.from(status: response.statusCode, body: data, bucket: configuration.bucket, key: key,
                               secret: configuration.secretAccessKey)
        }
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

    /// The key with the configured prefix, NFC-normalized and checked: not empty, no empty, `.` or
    /// `..` segments (URL handling could rewrite them), no control characters, at most 1,024 bytes.
    func fullKey(for key: String) throws -> String {
        let normalized = key.precomposedStringWithCanonicalMapping
        let full = configuration.prefix.isEmpty ? normalized : configuration.prefix + "/" + normalized
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

/// Redirects are not followed: a signed request re-sent to another host would only fail its
/// signature, and S3's 301/307 mean the host or region is configured wrongly.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefuseRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
