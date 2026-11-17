import CryptoKit
import Foundation

extension S3Client {
    /// The default limit of `getObject`: 4 MiB.
    public static let defaultSmallObjectLimit = 4 * 1024 * 1024

    /// Stores a small object in one `PutObject`, optionally only if a condition holds, and returns
    /// the ETag the service gave the stored object (quotes included).
    ///
    /// With a `condition`, its header (`If-Match: <eTag>` or `If-None-Match: *`) is sent and
    /// signed, and the service evaluates it atomically when the write commits. A condition that
    /// does not hold throws exactly `S3Error.preconditionFailed` and changes nothing.
    ///
    /// **A put whose answer was lost is ambiguous.** Transient failures are retried under
    /// `retryPolicy` with the same condition, which is what Cloudflare documents for R2: if the
    /// first attempt had in fact committed, the retry finds its own object there and gets 412.
    /// So a `preconditionFailed` after a retry may mean "this write already won"; the caller tells
    /// the two apart by reading the object back (`getObject` or `head`) and comparing an ID it
    /// stored in the object's metadata or content.
    ///
    /// Metadata follows the rules of `put(data:key:metadata:)`.
    @discardableResult
    public func putObject(data: Data, key: String, metadata: [String: String] = [:],
                          condition: S3PutCondition? = nil) async throws -> String {
        let fullKey = try fullKey(for: key)
        var headers = try Self.metadataHeaders(metadata)
        switch condition {
        case .ifMatch(let eTag): headers["If-Match"] = eTag
        case .ifAbsent: headers["If-None-Match"] = "*"
        case nil: break
        }
        var request = Request(method: "PUT", key: fullKey, signedHeaders: headers, body: .data(data),
                              payloadSHA256: S3Signer.hex(SHA256.hash(data: data)))
        request.otherHeaders["Content-Type"] = "application/octet-stream"
        let (_, response) = try await send(request, key: key, accepting: condition == nil ? [] : [412])
        if response.statusCode == 412 { throw S3Error.preconditionFailed }
        guard let eTag = Self.lowercasedHeaders(response)["etag"], !eTag.isEmpty else {
            throw S3Error.unexpectedResponse(status: response.statusCode, code: nil,
                                             message: "The service didn't say which version it stored.")
        }
        return eTag
    }

    /// Reads a small object into memory with its ETag and user metadata, or `nil` when there is
    /// no object with that key.
    ///
    /// At most `maxBytes` are accepted: a larger object (by its announced length, or by what
    /// arrives) stops the transfer and throws `unexpectedResponse` with `objectTooLargeCode`
    /// (`isObjectTooLarge`), which is not retried. A missing bucket throws `bucketNotFound`.
    public func getObject(key: String, maxBytes: Int = defaultSmallObjectLimit) async throws -> S3Object? {
        switch try await read(key: key, maxBytes: maxBytes, ifNoneMatch: nil) {
        case .found(let object): return object
        case .notFound: return nil
        case .notModified:
            // Only a request with If-None-Match can be answered 304.
            throw S3Error.unexpectedResponse(status: 304, code: nil, message: nil)
        }
    }

    /// `getObject(key:maxBytes:)` with `If-None-Match: <eTag>` (signed): `.notModified` when the
    /// object's ETag is still `eTag` (HTTP 304, no body), `.notFound` when there is no object.
    public func getObject(key: String, maxBytes: Int = defaultSmallObjectLimit,
                          ifNoneMatch eTag: String) async throws -> S3ObjectRead {
        try await read(key: key, maxBytes: maxBytes, ifNoneMatch: eTag)
    }

    private func read(key: String, maxBytes: Int, ifNoneMatch: String?) async throws -> S3ObjectRead {
        let fullKey = try fullKey(for: key)
        var request = Request(method: "GET", key: fullKey)
        if let ifNoneMatch { request.signedHeaders["If-None-Match"] = ifNoneMatch }
        let accepting: Set<Int> = ifNoneMatch == nil ? [404] : [304, 404]
        let (data, response, credentials) = try await withRetries {
            try await withCredentials { credentials in
                let (data, response) = try await performBounded(request, credentials: credentials, maxBytes: maxBytes,
                                                                key: key)
                if (200..<300).contains(response.statusCode) || accepting.contains(response.statusCode) {
                    return (data, response, credentials)
                }
                throw failure(status: response.statusCode, body: data, key: key, credentials: credentials)
            }
        }
        switch response.statusCode {
        case 304:
            return .notModified
        case 404:
            let service = S3XML.serviceError(from: data)
            guard let service, service.code != "NoSuchKey" else { return .notFound }
            throw S3Error.from(status: 404, code: service.code, message: service.message, bucket: endpoint.bucket,
                               key: key, redacting: credentials.redactions)
        default:
            let headers = Self.lowercasedHeaders(response)
            return .found(S3Object(data: data, eTag: headers["etag"], metadata: Self.userMetadata(headers),
                                   lastModified: headers["last-modified"].flatMap(Self.parseHTTPDate)))
        }
    }

    /// One attempt at a bodiless request whose 2xx body may be at most `maxBytes`: the body is
    /// streamed and the transfer cancelled as soon as it is known to be larger. An error body is
    /// kept up to 64 KiB (enough for an S3 `<Error>` document).
    private func performBounded(_ request: Request, credentials: S3Credentials, maxBytes: Int,
                                key: String) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try urlRequest(for: request, credentials: credentials)
        let tooLarge = S3Error.unexpectedResponse(status: 200, code: S3Error.objectTooLargeCode,
                                                  message: "The object is larger than \(maxBytes) bytes.")
        let bytes: URLSession.AsyncBytes
        let urlResponse: URLResponse
        do {
            (bytes, urlResponse) = try await session.bytes(for: urlRequest, delegate: RefuseRedirects.shared)
        } catch {
            throw S3Error.from(transport: error)
        }
        guard let response = urlResponse as? HTTPURLResponse else {
            bytes.task.cancel()
            throw S3Error.unexpectedResponse(status: 0, code: nil, message: "The response wasn't HTTP.")
        }
        let success = (200..<300).contains(response.statusCode)
        let limit = success ? maxBytes : 64 * 1024
        if success, response.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw tooLarge
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    bytes.task.cancel()
                    if success { throw tooLarge }
                    break
                }
                data.append(byte)
            }
        } catch let error as S3Error {
            throw error
        } catch {
            throw S3Error.from(transport: error)
        }
        return (data, response)
    }
}
