import CryptoKit
import Foundation

/// AWS Signature Version 4 signing in the `Authorization` header, as Amazon S3 specifies it
/// ("Signature Calculations for the Authorization Header: Transferring Payload in a Single Chunk").
///
/// The canonical request is built the S3 way: the path is **not** normalized, each path segment is
/// URI-encoded exactly once (`/` kept between segments), query names and values are URI-encoded
/// individually and sorted after encoding, header names are lowercased and sorted, and header
/// values are trimmed with inner runs of spaces collapsed. The signer signs `host`, `x-amz-date`,
/// `x-amz-content-sha256` and every header passed in; pass only headers that are sent unchanged
/// (`x-amz-*`, `Range`, `If-Match`, `Date`), not ones `URLSession` may rewrite.
///
/// With temporary credentials, the session token is sent as `X-Amz-Security-Token` and is one of
/// the signed headers: AWS's "Create a signed AWS API request" requires every `x-amz-*` header
/// sent, `x-amz-security-token` named among them, to be in the canonical headers, and Cloudflare
/// R2 takes the token in that header on every request. Without a token, nothing changes.
///
/// The secret access key and session token are held privately and never appear in a description
/// or mirror.
public struct S3Signer: Sendable {
    /// The `x-amz-content-sha256` value for a payload that is not hashed.
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    /// The SHA-256 of an empty payload, which bodiless requests (GET, HEAD, DELETE) sign.
    public static let emptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// The header that carries a session token.
    public static let securityTokenHeader = "X-Amz-Security-Token"

    public let accessKeyID: String
    public let region: String
    public let service: String
    private let secretAccessKey: String
    private let sessionToken: String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - sessionToken: the token of temporary credentials; `nil` (or empty) for a long-lived key.
    ///   - now: the clock used when `sign` is not given a date (injected for tests).
    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, region: String,
                service: String = "s3", now: @escaping @Sendable () -> Date = { Date() }) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken?.isEmpty == false ? sessionToken : nil
        self.region = region
        self.service = service
        self.now = now
    }

    public init(credentials: S3Credentials, region: String, service: String = "s3",
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey,
                  sessionToken: credentials.sessionToken, region: region, service: service, now: now)
    }

    public init(configuration: S3Configuration, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(accessKeyID: configuration.accessKeyID, secretAccessKey: configuration.secretAccessKey,
                  region: configuration.region, now: now)
    }

    /// Whether requests carry and sign `X-Amz-Security-Token`.
    public var hasSessionToken: Bool { sessionToken != nil }

    /// The headers to add to the request: `Authorization`, `x-amz-date` and `x-amz-content-sha256`,
    /// and `X-Amz-Security-Token` when signing with a session token.
    ///
    /// - Parameters:
    ///   - headers: further headers that will be sent and must be signed (names in any case).
    ///   - payloadSHA256: lowercase hex SHA-256 of the body, or `unsignedPayload`.
    ///   - date: the signing time; the injected clock when `nil`.
    public func sign(method: String, url: URL, headers: [String: String] = [:], payloadSHA256: String,
                     date: Date? = nil) -> [String: String] {
        let parts = signature(method: method, url: url, headers: headers, payloadSHA256: payloadSHA256,
                              date: date ?? now())
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(parts.scope),"
            + "SignedHeaders=\(parts.signedHeaders),Signature=\(parts.signature)"
        var result = ["Authorization": authorization, "x-amz-date": parts.timestamp,
                      "x-amz-content-sha256": payloadSHA256]
        if let sessionToken { result[Self.securityTokenHeader] = sessionToken }
        return result
    }

    /// The canonical request `sign` hashes, for diagnostics and tests.
    public func canonicalRequest(method: String, url: URL, headers: [String: String] = [:],
                                 payloadSHA256: String, date: Date) -> String {
        signature(method: method, url: url, headers: headers, payloadSHA256: payloadSHA256, date: date).canonicalRequest
    }

    /// The string to sign `sign` uses, for diagnostics and tests.
    public func stringToSign(method: String, url: URL, headers: [String: String] = [:],
                             payloadSHA256: String, date: Date) -> String {
        signature(method: method, url: url, headers: headers, payloadSHA256: payloadSHA256, date: date).stringToSign
    }

    // MARK: Canonical forms

    /// `UriEncode()` from the S3 documentation: every byte of the UTF-8 form is percent-encoded
    /// with uppercase hex except the unreserved `A-Z a-z 0-9 - . _ ~`; a space becomes `%20`
    /// (never `+`); `/` is kept only when `encodeSlash` is false (object key paths).
    public static func uriEncode(_ value: String, encodeSlash: Bool = true) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "/") where !encodeSlash:
                result.append("/")
            default:
                result.append("%")
                result.append(hexDigits[Int(byte >> 4)])
                result.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return result
    }

    /// The canonical URI of `url`: each `/`-separated segment of its path is decoded and encoded
    /// once with `uriEncode`; empty segments and `.`/`..` are kept as they are (S3 paths are not
    /// normalized). An empty path is `/`.
    public static func canonicalURI(for url: URL) -> String {
        let path = url.path(percentEncoded: true)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in uriEncode(String(segment).removingPercentEncoding ?? String(segment)) }
            .joined(separator: "/")
    }

    /// The canonical query string of `url`: names and values decoded, then encoded with
    /// `uriEncode` (so `/`, `=`, `+` and spaces are all percent-encoded), sorted by name then value,
    /// with `name=` for a parameter without a value. A `+` in the URL is taken literally, not as a space.
    public static func canonicalQueryString(for url: URL) -> String {
        guard let query = url.query(percentEncoded: true), !query.isEmpty else { return "" }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: true).map { item -> (String, String) in
            let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0]), value = pieces.count > 1 ? String(pieces[1]) : ""
            return (uriEncode(name.removingPercentEncoding ?? name), uriEncode(value.removingPercentEncoding ?? value))
        }
        return pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// The `host` header value `URLSession` sends for `url`: the host (an IPv6 address in
    /// brackets), plus the port when it is not the scheme's default.
    public static func hostHeader(for url: URL) -> String {
        var host = url.host(percentEncoded: true) ?? ""
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        guard let port = url.port else { return host }
        let defaultPort = url.scheme?.lowercased() == "http" ? 80 : 443
        return port == defaultPort ? host : "\(host):\(port)"
    }

    /// `YYYYMMDD'T'HHMMSS'Z'` in UTC.
    public static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    // MARK: Signing

    private struct Parts {
        var canonicalRequest: String
        var stringToSign: String
        var signedHeaders: String
        var scope: String
        var timestamp: String
        var signature: String
    }

    private func signature(method: String, url: URL, headers: [String: String], payloadSHA256: String,
                           date: Date) -> Parts {
        let timestamp = Self.timestamp(date)
        let day = String(timestamp.prefix(8))

        var canonical: [String: String] = [:]
        for (name, value) in headers {
            let name = name.lowercased()
            let value = Self.canonicalHeaderValue(value)
            canonical[name] = canonical[name].map { "\($0),\(value)" } ?? value
        }
        if let sessionToken { canonical["x-amz-security-token"] = Self.canonicalHeaderValue(sessionToken) }
        canonical["host"] = Self.hostHeader(for: url)
        canonical["x-amz-date"] = timestamp
        canonical["x-amz-content-sha256"] = payloadSHA256
        let names = canonical.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let headerBlock = names.map { "\($0):\(canonical[$0]!)\n" }.joined()

        let canonicalRequest = [method.uppercased(), Self.canonicalURI(for: url), Self.canonicalQueryString(for: url),
                                headerBlock, signedHeaders, payloadSHA256].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope,
                            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for component in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(component.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return Parts(canonicalRequest: canonicalRequest, stringToSign: stringToSign, signedHeaders: signedHeaders,
                     scope: scope, timestamp: timestamp, signature: signature)
    }

    /// Trimmed, with each run of spaces collapsed to one.
    static func canonicalHeaderValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var result = ""
        for byte in digest {
            result.append(lowerHexDigits[Int(byte >> 4)])
            result.append(lowerHexDigits[Int(byte & 0x0F)])
        }
        return result
    }

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")
    private static let lowerHexDigits: [Character] = Array("0123456789abcdef")
}

extension S3Signer: CustomStringConvertible, CustomReflectable {
    /// With a session token the access key ID is redacted too: it belongs to temporary credentials.
    public var description: String {
        guard hasSessionToken else {
            return "S3Signer(accessKeyID: \(accessKeyID), region: \(region), service: \(service), secretAccessKey: <redacted>)"
        }
        return "S3Signer(accessKeyID: <redacted>, region: \(region), service: \(service), secretAccessKey: <redacted>, "
            + "sessionToken: <redacted>)"
    }

    public var customMirror: Mirror {
        guard hasSessionToken else {
            return Mirror(self, children: ["accessKeyID": accessKeyID, "region": region, "service": service,
                                           "secretAccessKey": "<redacted>"], displayStyle: .struct)
        }
        return Mirror(self, children: ["accessKeyID": "<redacted>", "region": region, "service": service,
                                       "secretAccessKey": "<redacted>", "sessionToken": "<redacted>"],
                      displayStyle: .struct)
    }
}
