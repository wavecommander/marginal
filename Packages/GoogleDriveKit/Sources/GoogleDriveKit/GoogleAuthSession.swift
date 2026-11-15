import Foundation

/// The reader's Google sign-in: exchanges the authorisation code, keeps a valid access token,
/// refreshes it (once, however many callers ask at the same time), and signs out.
///
/// The app presents ``GoogleAuthorizationRequest/url`` in `ASWebAuthenticationSession` with
/// ``GoogleOAuthConfiguration/callbackScheme``, then passes the callback URL to
/// ``completeSignIn(request:callbackURL:)``.
public actor GoogleAuthSession {
    public nonisolated let configuration: GoogleOAuthConfiguration
    /// An access token closer than this to expiry is refreshed before use.
    public nonisolated let refreshMargin: TimeInterval

    private let store: any GoogleTokenStore
    private let urlSession: URLSession
    private let now: @Sendable () -> Date

    private var tokens: GoogleTokenSet?
    private var loaded = false
    private var refreshRejected = false
    private var refreshTask: Task<GoogleTokenSet, any Error>?

    public init(
        configuration: GoogleOAuthConfiguration,
        tokenStore: any GoogleTokenStore,
        urlSession: URLSession = .shared,
        refreshMargin: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = tokenStore
        self.urlSession = urlSession
        self.refreshMargin = refreshMargin
        self.now = now
    }

    /// A new sign-in attempt (fresh PKCE verifier and state).
    public nonisolated func makeAuthorizationRequest(loginHint: String? = nil) -> GoogleAuthorizationRequest {
        GoogleAuthorizationRequest(configuration: configuration, loginHint: loginHint)
    }

    /// Validates the callback, exchanges its code and saves the tokens.
    @discardableResult
    public func completeSignIn(request: GoogleAuthorizationRequest, callbackURL: URL) async throws -> GoogleTokenSet {
        let code = try request.authorizationCode(fromCallback: callbackURL)
        return try await exchange(code: code, request: request)
    }

    /// Exchanges an authorisation code for tokens (`grant_type=authorization_code` with the PKCE
    /// verifier) and saves them. Throws ``GoogleDriveError/driveAccessNotGranted`` when the reader
    /// did not grant every requested scope; nothing is saved then.
    @discardableResult
    public func exchange(code: String, request: GoogleAuthorizationRequest) async throws -> GoogleTokenSet {
        let response: TokenResponse
        do {
            response = try await tokenRequest([
                ("code", code),
                ("client_id", configuration.clientID),
                ("code_verifier", request.pkce.verifier),
                ("grant_type", "authorization_code"),
                ("redirect_uri", configuration.redirectURI),
            ])
        } catch let TokenEndpointError.oauth(status, error) {
            throw GoogleDriveError.signInFailed(reason: error ?? "HTTP \(status)")
        }
        guard let refreshToken = response.refresh_token, !refreshToken.isEmpty else {
            throw GoogleDriveError.unexpectedResponse(status: 200, reason: "no refresh_token")
        }
        let granted = response.scope.map(Self.scopes) ?? configuration.scopes
        guard configuration.scopes.allSatisfy(granted.contains) else {
            throw GoogleDriveError.driveAccessNotGranted
        }
        let set = GoogleTokenSet(
            accessToken: response.access_token,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expires_in)),
            refreshToken: refreshToken,
            grantedScopes: granted)
        refreshTask = nil
        try await store.save(set)
        tokens = set
        loaded = true
        refreshRejected = false
        return set
    }

    /// The saved tokens, if any.
    public func currentTokens() async throws -> GoogleTokenSet? {
        try await loadIfNeeded()
        return tokens
    }

    public func isSignedIn() async throws -> Bool { try await currentTokens() != nil }

    /// An access token valid for at least ``refreshMargin``, refreshing first when needed.
    public func validAccessToken() async throws -> String {
        try await loadIfNeeded()
        guard let current = tokens else {
            throw refreshRejected ? GoogleDriveError.needsSignInAgain : GoogleDriveError.notSignedIn
        }
        if current.isAccessTokenValid(at: now(), margin: refreshMargin), refreshTask == nil {
            return current.accessToken
        }
        return try await refresh(current).accessToken
    }

    /// Called after Drive rejected `rejected` with 401: refreshes unless another caller already
    /// replaced that token, and returns the token to retry with.
    public func accessToken(replacingRejected rejected: String) async throws -> String {
        try await loadIfNeeded()
        guard let current = tokens else {
            throw refreshRejected ? GoogleDriveError.needsSignInAgain : GoogleDriveError.notSignedIn
        }
        if current.accessToken != rejected, refreshTask == nil,
           current.isAccessTokenValid(at: now(), margin: refreshMargin) {
            return current.accessToken
        }
        return try await refresh(current).accessToken
    }

    /// Revokes the refresh token at Google (which also revokes its access tokens) and clears the
    /// store. The local sign-out happens even when Google cannot be reached.
    /// - Returns: whether Google confirmed the revocation (or already considered the token invalid).
    @discardableResult
    public func signOut() async throws -> Bool {
        try await loadIfNeeded()
        let revoking = tokens
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        refreshRejected = false
        try await store.clear()
        guard let revoking else { return true }
        var request = URLRequest(method: "POST", url: GoogleOAuthConfiguration.revocationEndpoint)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode([("token", revoking.refreshToken)]).utf8)
        guard let (data, response) = try? await HTTP.send(request, on: urlSession) else { return false }
        if response.statusCode == 200 { return true }
        // 400 invalid_token: Google already considers it revoked or expired.
        return response.statusCode == 400 && Self.oauthError(in: data) == "invalid_token"
    }

    // MARK: - Internals

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        tokens = try await store.load()
        loaded = true
    }

    private func refresh(_ current: GoogleTokenSet) async throws -> GoogleTokenSet {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        return try await task.value
    }

    private func performRefresh(_ current: GoogleTokenSet) async throws -> GoogleTokenSet {
        let response: TokenResponse
        do {
            response = try await tokenRequest([
                ("client_id", configuration.clientID),
                ("refresh_token", current.refreshToken),
                ("grant_type", "refresh_token"),
            ])
        } catch TokenEndpointError.oauth(_, .some("invalid_grant")) {
            // The refresh token was revoked, expired or replaced: the reader must sign in again.
            tokens = nil
            refreshRejected = true
            try await store.clear()
            throw GoogleDriveError.needsSignInAgain
        } catch let TokenEndpointError.oauth(status, error) {
            throw GoogleDriveError.unexpectedResponse(status: status, reason: error)
        }
        let set = GoogleTokenSet(
            accessToken: response.access_token,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expires_in)),
            refreshToken: response.refresh_token ?? current.refreshToken,
            grantedScopes: response.scope.map(Self.scopes) ?? current.grantedScopes)
        try await store.save(set)
        tokens = set
        return set
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    private enum TokenEndpointError: Error {
        case oauth(status: Int, error: String?)
    }

    private func tokenRequest(_ items: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(method: "POST", url: GoogleOAuthConfiguration.tokenEndpoint)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(items).utf8)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await HTTP.send(request, on: urlSession)
        } catch let failure as AttemptFailure {
            throw failure.error
        }
        guard response.statusCode == 200 else {
            if (500...599).contains(response.statusCode) {
                throw GoogleDriveError.unexpectedResponse(status: response.statusCode, reason: Self.oauthError(in: data))
            }
            throw TokenEndpointError.oauth(status: response.statusCode, error: Self.oauthError(in: data))
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleDriveError.unexpectedResponse(status: 200, reason: "unreadable token response")
        }
    }

    private static func oauthError(in data: Data) -> String? {
        struct Body: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }

    private static func scopes(_ scope: String) -> [String] {
        scope.split(separator: " ").map(String.init)
    }
}
