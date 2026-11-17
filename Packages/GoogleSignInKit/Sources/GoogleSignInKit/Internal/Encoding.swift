import CryptoKit
import Foundation

/// Percent-encoding for `application/x-www-form-urlencoded` bodies and query strings.
///
/// Everything outside RFC 3986's unreserved set is encoded, including `+`, `&`, `=` and `/`, so a
/// value never arrives as a literal `+` (which a form decoder reads as a space).
enum FormEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// Appends `items`, encoded as above, to `base` as its query.
    static func url(_ base: URL, _ items: [(String, String)]) -> URL {
        let query = encode(items)
        let string = base.absoluteString
        let separator = string.contains("?") ? "&" : "?"
        // `base` is a valid URL and the query is percent-encoded, so this cannot fail.
        return URL(string: query.isEmpty ? string : string + separator + query)!
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

    /// Decodes base64url with or without padding; `nil` for anything else.
    init?(base64URLEncoded string: some StringProtocol) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    static func secureRandom(count: Int) -> Data {
        // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// PKCE (RFC 7636) with the S256 method only; plain is never used.
enum PKCE {
    static let method = "S256"
    static let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 43 characters of base64url from 32 secure random bytes (RFC 7636 allows 43 to 128
    /// characters of `A-Z a-z 0-9 - . _ ~`).
    static func makeVerifier() -> String {
        Data.secureRandom(count: 32).base64URLEncodedString
    }

    static func isValidVerifier(_ verifier: String) -> Bool {
        (43...128).contains(verifier.count) && verifier.allSatisfy(allowedCharacters.contains)
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, unpadded.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }
}

/// The text shown in place of a secret in descriptions and mirrors.
let redacted = "<redacted>"
