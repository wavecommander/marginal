import CryptoKit
import Foundation

/// A PKCE (RFC 7636) code verifier and its S256 challenge.
public struct GooglePKCE: Sendable, Hashable {
    /// The challenge method sent to Google. Plain is never used.
    public static let method = "S256"
    static let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 43 characters of base64url from 32 secure random bytes (Google allows 43 to 128 characters
    /// of `A-Z a-z 0-9 - . _ ~`).
    public let verifier: String
    /// `BASE64URL(SHA256(ASCII(verifier)))`, unpadded.
    public let challenge: String

    /// A fresh random verifier.
    public init() {
        self.init(validVerifier: Data.secureRandom(count: 32).base64URLEncodedString)
    }

    /// A specific verifier, or `nil` when it is not 43 to 128 unreserved characters.
    public init?(verifier: String) {
        guard (43...128).contains(verifier.count), verifier.allSatisfy(Self.allowedCharacters.contains) else {
            return nil
        }
        self.init(validVerifier: verifier)
    }

    private init(validVerifier: String) {
        verifier = validVerifier
        challenge = Self.challenge(for: validVerifier)
    }

    /// The S256 challenge for a verifier.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }
}

/// One sign-in attempt: the URL to open in `ASWebAuthenticationSession`, and the secrets needed to
/// check the callback and exchange its code. Keep it until the callback arrives; use it once.
public struct GoogleAuthorizationRequest: Sendable, Hashable {
    public let configuration: GoogleOAuthConfiguration
    public let pkce: GooglePKCE
    /// Random value echoed back by Google; a callback with any other value is refused (CSRF).
    public let state: String
    public let loginHint: String?

    /// A request with a fresh verifier and state.
    public init(configuration: GoogleOAuthConfiguration, loginHint: String? = nil) {
        self.init(configuration: configuration, pkce: GooglePKCE(),
                  state: Data.secureRandom(count: 16).base64URLEncodedString, loginHint: loginHint)
    }

    /// A request with given values (for tests).
    public init(configuration: GoogleOAuthConfiguration, pkce: GooglePKCE, state: String, loginHint: String? = nil) {
        self.configuration = configuration
        self.pkce = pkce
        self.state = state
        self.loginHint = loginHint
    }

    /// `https://accounts.google.com/o/oauth2/v2/auth?client_id=…&redirect_uri=…&response_type=code&scope=…&code_challenge=…&code_challenge_method=S256&state=…`
    public var url: URL {
        var items: [(String, String)] = [
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI),
            ("response_type", "code"),
            ("scope", configuration.scopes.joined(separator: " ")),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", GooglePKCE.method),
            ("state", state),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        return FormEncoding.url(GoogleOAuthConfiguration.authorizationEndpoint.absoluteString, items)
    }

    /// Validates Google's redirect and returns its authorisation code.
    ///
    /// - Throws: ``GoogleDriveError/signInCancelled`` for `error=access_denied` (the reader said no
    ///   or closed the consent page), ``GoogleDriveError/signInFailed(reason:)`` for a foreign
    ///   scheme, a `state` that does not match, another OAuth error or a missing `code`.
    public func authorizationCode(fromCallback callbackURL: URL) throws -> String {
        guard callbackURL.scheme?.lowercased() == configuration.callbackScheme.lowercased() else {
            throw GoogleDriveError.signInFailed(reason: "unexpected redirect")
        }
        let parameters = FormEncoding.decodeQuery(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        // An error carries nothing secret, so it is reported even without a matching state.
        if let error = parameters["error"] {
            if error == "access_denied" { throw GoogleDriveError.signInCancelled }
            throw GoogleDriveError.signInFailed(reason: error)
        }
        guard parameters["state"] == state else {
            throw GoogleDriveError.signInFailed(reason: "state mismatch")
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw GoogleDriveError.signInFailed(reason: "missing authorization code")
        }
        return code
    }
}
