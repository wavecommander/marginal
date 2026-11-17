import Foundation

/// The settings for one iOS OAuth client registered in Google Cloud.
///
/// An iOS client receives Google's redirect on a custom URL scheme that is its client ID with the
/// dot-separated fields reversed (Google's "iOS URL scheme" in the Cloud console), for example
/// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`. The redirect URI
/// is that scheme, a colon and a single-slash path: `com.googleusercontent.apps.123-abc:/oauthredirect`.
/// The app passes ``callbackURLScheme`` to `ASWebAuthenticationSession`.
public struct GoogleSignInConfiguration: Sendable, Hashable {
    /// Google's authorisation endpoint, opened in the web sign-in sheet.
    public static let defaultAuthorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    /// Google's token endpoint, where the code is exchanged.
    public static let defaultTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// The scopes requested: enough for an ID token carrying the reader's email address.
    public static let scopes = ["openid", "email"]
    /// The redirect path. Any path is accepted for an iOS client's scheme; this one is fixed so the
    /// redirect can be checked.
    public static let redirectPath = "/oauthredirect"

    static let clientIDSuffix = ".apps.googleusercontent.com"
    static let reversedPrefix = "com.googleusercontent.apps."

    /// The client ID as registered, for example `123456789012-abc123.apps.googleusercontent.com`.
    public let clientID: String
    /// The `redirect_uri` sent in the authorisation and token requests.
    public let redirectURI: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    /// Creates a configuration, or returns `nil` when `clientID` is empty, an unexpanded build
    /// setting such as `$(GOOGLE_SIGNIN_CLIENT_ID)`, or not an iOS client ID of the form
    /// `<id>.apps.googleusercontent.com`. Surrounding whitespace is ignored. The endpoints are
    /// Google's unless a test replaces them.
    public init?(clientID: String,
                 authorizationEndpoint: URL = Self.defaultAuthorizationEndpoint,
                 tokenEndpoint: URL = Self.defaultTokenEndpoint) {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.clientIDSuffix) else { return nil }
        let identifier = trimmed.dropLast(Self.clientIDSuffix.count)
        // The identifier becomes part of a URL scheme (letters, digits, "+", "-", "."), and must not
        // contain a dot or the reversal would not be the plain prefix swap Google documents. This
        // also refuses "$(…)".
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !identifier.isEmpty, identifier.allSatisfy(allowed.contains),
              let redirectURI = URL(string: Self.reversedPrefix + identifier + ":" + Self.redirectPath)
        else { return nil }
        self.clientID = trimmed
        self.redirectURI = redirectURI
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    /// The custom URL scheme Google redirects to: the reversed client ID, for example
    /// `com.googleusercontent.apps.123-abc`.
    public var callbackURLScheme: String {
        Self.reversedPrefix + clientID.dropLast(Self.clientIDSuffix.count)
    }
}
