import Foundation

/// One sign-in attempt: the URL to open in `ASWebAuthenticationSession`, and what is needed to
/// check the redirect and exchange its code. Keep it until the redirect arrives; use it once.
///
/// The PKCE code verifier stays inside: it is never public, and descriptions and mirrors show
/// it as redacted.
public struct GoogleSignInRequest: Sendable {
    /// The authorisation URL to open.
    public let url: URL
    /// Random and URL-safe; Google echoes it back and a redirect with any other value is refused
    /// (CSRF).
    public let state: String
    /// The caller's nonce (normally issued by the server that will verify the ID token), sent
    /// unchanged; Google copies it into the ID token.
    public let nonce: String
    public let loginHint: String?
    let configuration: GoogleSignInConfiguration
    /// The PKCE verifier. Secret until the exchange; never printed.
    let codeVerifier: String

    /// A request with a fresh PKCE verifier and state.
    ///
    /// - Parameters:
    ///   - nonce: sent as `nonce` exactly as given.
    ///   - loginHint: an email address to preselect, if any (`login_hint`).
    public static func make(configuration: GoogleSignInConfiguration, nonce: String,
                            loginHint: String? = nil) -> GoogleSignInRequest {
        GoogleSignInRequest(configuration: configuration, nonce: nonce, loginHint: loginHint,
                            state: Data.secureRandom(count: 16).base64URLEncodedString,
                            codeVerifier: PKCE.makeVerifier())
    }

    /// A request with given values (for tests). `codeVerifier` must be 43 to 128 unreserved
    /// characters.
    init(configuration: GoogleSignInConfiguration, nonce: String, loginHint: String? = nil,
         state: String, codeVerifier: String) {
        precondition(PKCE.isValidVerifier(codeVerifier), "invalid PKCE verifier")
        self.configuration = configuration
        self.nonce = nonce
        self.loginHint = loginHint
        self.state = state
        self.codeVerifier = codeVerifier
        var items: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI.absoluteString),
            ("scope", GoogleSignInConfiguration.scopes.joined(separator: " ")),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", PKCE.challenge(for: codeVerifier)),
            ("code_challenge_method", PKCE.method),
            ("prompt", "select_account"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        url = FormEncoding.url(configuration.authorizationEndpoint, items)
    }

    /// Validates Google's redirect against this request and returns the authorisation code.
    ///
    /// An `error` parameter is reported before `state` is compared: it carries nothing secret, and
    /// a reader who backs out should hear that they cancelled.
    func authorizationCode(from redirect: URL) throws(GoogleSignInError) -> String {
        guard let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == configuration.callbackURLScheme.lowercased(),
              components.host == nil || components.host == "",
              components.path == GoogleSignInConfiguration.redirectPath else {
            throw .redirectInvalid
        }
        let parameters = FormEncoding.decodeQuery(components.percentEncodedQuery)
        if let error = parameters["error"] {
            throw .authorizationDenied(code: error)
        }
        guard parameters["state"] == state else { throw .stateMismatch }
        guard let code = parameters["code"], !code.isEmpty else { throw .redirectInvalid }
        return code
    }
}

extension GoogleSignInRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "GoogleSignInRequest(state: \(state), codeVerifier: \(redacted))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["url": url, "state": state, "nonce": nonce, "codeVerifier": redacted],
               displayStyle: .struct)
    }
}
