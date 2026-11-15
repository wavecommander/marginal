import Foundation

/// The tokens from one Google sign-in.
public struct GoogleTokenSet: Sendable, Codable, Hashable {
    /// Short-lived bearer token for Drive requests.
    public var accessToken: String
    /// When ``accessToken`` stops working (from `expires_in`).
    public var expiresAt: Date
    /// Long-lived token used to get new access tokens. Keep it in the Keychain.
    public var refreshToken: String
    /// The scopes the reader actually granted (Google lets them untick some).
    public var grantedScopes: [String]

    public init(accessToken: String, expiresAt: Date, refreshToken: String, grantedScopes: [String]) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.grantedScopes = grantedScopes
    }

    /// Whether the access token is still good for at least `margin` seconds after `date`.
    public func isAccessTokenValid(at date: Date, margin: TimeInterval) -> Bool {
        expiresAt.timeIntervalSince(date) > margin
    }

    public func grants(_ scope: String) -> Bool { grantedScopes.contains(scope) }
}

/// Persists the reader's Google tokens. The app supplies a Keychain implementation.
public protocol GoogleTokenStore: Sendable {
    func load() async throws -> GoogleTokenSet?
    func save(_ tokens: GoogleTokenSet) async throws
    func clear() async throws
}

/// A token store that keeps tokens in memory (tests, previews).
public actor InMemoryGoogleTokenStore: GoogleTokenStore {
    private var tokens: GoogleTokenSet?

    public init(_ tokens: GoogleTokenSet? = nil) { self.tokens = tokens }

    public func load() -> GoogleTokenSet? { tokens }
    public func save(_ tokens: GoogleTokenSet) { self.tokens = tokens }
    public func clear() { tokens = nil }
}
