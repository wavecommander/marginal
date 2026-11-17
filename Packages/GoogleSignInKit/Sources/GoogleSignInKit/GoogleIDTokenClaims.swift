import Foundation

/// Reads claims from a Google ID token's payload WITHOUT verifying its signature, issuer,
/// audience, nonce or expiry. For display on the device only (for example "Signed in as …");
/// the server verifies the token before trusting anything in it.
public enum GoogleIDTokenClaims {
    /// The `email` claim, or `nil` when the token is malformed or has none.
    public static func email(in idToken: String) -> String? {
        guard let email = payload(of: idToken)?["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    /// The `email_verified` claim (Google sends a JSON boolean; the string forms are accepted too),
    /// or `nil` when the token is malformed or has none.
    public static func emailVerified(in idToken: String) -> Bool? {
        switch payload(of: idToken)?["email_verified"] {
        case let value as Bool: value
        case let value as String where value == "true": true
        case let value as String where value == "false": false
        default: nil
        }
    }

    /// The decoded payload: a compact JWS has three dot-separated base64url parts and the second
    /// is a JSON object.
    static func payload(of idToken: String) -> [String: Any]? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let data = Data(base64URLEncoded: parts[1]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
