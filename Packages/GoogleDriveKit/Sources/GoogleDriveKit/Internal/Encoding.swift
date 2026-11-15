import CryptoKit
import Foundation

/// Percent-encoding for `application/x-www-form-urlencoded` bodies and query strings.
///
/// Everything outside RFC 3986's unreserved set is encoded, including `+`, `&`, `=` and `'`, so a
/// Drive search query such as `name = 'a+b'` survives the trip (a bare `+` is read as a space).
enum FormEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// Builds `base?items`, encoded as above.
    static func url(_ base: String, _ items: [(String, String)]) -> URL {
        let query = encode(items)
        // Every caller passes a constant https base and encoded components, so this cannot fail.
        return URL(string: query.isEmpty ? base : "\(base)?\(query)")!
    }

    /// Decodes a query string into its first value per name (`+` is not treated as a space:
    /// Google's redirect uses percent-encoding).
    static func decodeQuery(_ query: String?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (query ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first,
                  let name = String(rawName).removingPercentEncoding else { continue }
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }
}

extension Data {
    /// RFC 4648 §5 base64url without padding.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func secureRandom(count: Int) -> Data {
        // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

extension Sequence where Element == UInt8 {
    var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// SHA-256 and MD5 of a byte stream fed in order. MD5 is only for comparing with Drive's
/// `md5Checksum` when it has no `sha256Checksum` for a file, never for anything security-related.
struct StreamDigest {
    private var sha256 = SHA256()
    private var md5 = Insecure.MD5()
    private(set) var byteCount: Int64 = 0

    mutating func update(_ data: Data) {
        sha256.update(data: data)
        md5.update(data: data)
        byteCount += Int64(data.count)
    }

    func finalize() -> (sha256: String, md5: String) {
        (sha256.finalize().lowercaseHex, md5.finalize().lowercaseHex)
    }
}

/// Drive search-query string literal: backslash and single quote are escaped with a backslash.
func driveQueryLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
    return "'\(escaped)'"
}
