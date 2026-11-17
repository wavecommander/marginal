import Foundation

/// The outcome of a sign-in: Google's ID token, for the server to verify.
public struct GoogleSignInResult: Sendable, Hashable {
    /// The ID token (a JWT). Secret: never printed.
    public let idToken: String

    public init(idToken: String) {
        self.idToken = idToken
    }

    /// The token's `email` claim, unverified: for display on the device only.
    public var email: String? { GoogleIDTokenClaims.email(in: idToken) }

    /// The token's `email_verified` claim, unverified: for display on the device only.
    public var emailVerified: Bool? { GoogleIDTokenClaims.emailVerified(in: idToken) }
}

extension GoogleSignInResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "GoogleSignInResult(idToken: \(redacted))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["idToken": redacted], displayStyle: .struct)
    }
}

/// Completes a sign-in: validates Google's redirect and exchanges its code for the ID token.
///
/// The app makes a request (``makeRequest(nonce:loginHint:)``), opens its ``GoogleSignInRequest/url``
/// in `ASWebAuthenticationSession` with ``GoogleSignInConfiguration/callbackURLScheme``, and passes
/// the redirect URL to ``complete(_:redirect:)``. Nothing is logged or stored.
public struct GoogleSignInClient: Sendable {
    public let configuration: GoogleSignInConfiguration
    private let urlSession: URLSession

    public init(configuration: GoogleSignInConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    /// A new sign-in attempt for this client's configuration.
    public func makeRequest(nonce: String, loginHint: String? = nil) -> GoogleSignInRequest {
        .make(configuration: configuration, nonce: nonce, loginHint: loginHint)
    }

    /// Validates the redirect (scheme and path, `error` → ``GoogleSignInError/authorizationDenied(code:)``,
    /// `state` matches, `code` present), then exchanges the code at Google's token endpoint (one
    /// form POST: `code`, `client_id`, `redirect_uri`, `grant_type=authorization_code`,
    /// `code_verifier`) and returns the ID token.
    ///
    /// - Throws: ``GoogleSignInError`` only. A request made for another configuration is
    ///   ``GoogleSignInError/redirectInvalid``; task cancellation is ``GoogleSignInError/cancelled``.
    public func complete(_ request: GoogleSignInRequest, redirect: URL) async throws(GoogleSignInError) -> GoogleSignInResult {
        guard request.configuration == configuration else { throw .redirectInvalid }
        let code = try request.authorizationCode(from: redirect)
        return try await exchange(code: code, verifier: request.codeVerifier)
    }

    private struct TokenResponse: Decodable {
        let id_token: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String?
    }

    private func exchange(code: String, verifier: String) async throws(GoogleSignInError) -> GoogleSignInResult {
        if Task.isCancelled { throw .cancelled }
        var request = URLRequest(url: configuration.tokenEndpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode([
            ("code", code),
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI.absoluteString),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ]).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .unexpectedResponse }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw .exchangeFailed(status: http.statusCode, code: code)
        }
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw .unexpectedResponse
        }
        guard let idToken = body.id_token, !idToken.isEmpty else { throw .missingIDToken }
        return GoogleSignInResult(idToken: idToken)
    }

    private static func transportError(_ error: any Error) -> GoogleSignInError {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        guard let urlError = error as? URLError else { return .unexpectedResponse }
        return urlError.code == .cancelled ? .cancelled : .network
    }
}
