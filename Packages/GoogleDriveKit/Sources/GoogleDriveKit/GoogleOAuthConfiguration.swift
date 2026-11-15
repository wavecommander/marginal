import Foundation

/// The OAuth settings for one iOS OAuth client registered in Google Cloud.
///
/// An iOS client receives Google's redirect on a custom URL scheme that is its client ID with the
/// dot-separated fields reversed (Google's "iOS URL scheme" in the Cloud console), for example
/// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`. The redirect URI
/// is that scheme, a colon, and a path with a single slash: `com.googleusercontent.apps.123-abc:/oauth2redirect`.
/// The app registers ``callbackScheme`` in `CFBundleURLTypes` and passes it to
/// `ASWebAuthenticationSession`.
public struct GoogleOAuthConfiguration: Sendable, Hashable {
    /// Google's authorisation endpoint (shown to the reader in the web sign-in sheet).
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    /// Token exchange and refresh.
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// Token revocation.
    public static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    static let clientIDSuffix = ".apps.googleusercontent.com"
    static let reversedPrefix = "com.googleusercontent.apps."
    /// The redirect path. Any path is accepted for an iOS client's scheme; this one is fixed so the
    /// callback can be checked.
    public static let redirectPath = "/oauth2redirect"

    /// The client ID as registered, for example `123456789012-abc123.apps.googleusercontent.com`.
    public let clientID: String
    /// The scopes requested at sign-in. Defaults to ``GoogleDriveScope/driveFile`` only.
    public let scopes: [String]

    /// Creates a configuration, or returns `nil` when `clientID` is missing, empty, an unexpanded
    /// build setting such as `$(GOOGLE_DRIVE_CLIENT_ID)`, or not an iOS client ID of the form
    /// `<id>.apps.googleusercontent.com`. The app shows "not set up in this build" for `nil`.
    public init?(clientID: String?, scopes: [String] = [GoogleDriveScope.driveFile]) {
        guard let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasSuffix(Self.clientIDSuffix) else { return nil }
        let identifier = trimmed.dropLast(Self.clientIDSuffix.count)
        // The identifier becomes part of a URL scheme (letters, digits, "+", "-", "."), and must not
        // contain a dot or the reversal would not be the plain prefix swap Google documents.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !identifier.isEmpty, identifier.allSatisfy(allowed.contains), !scopes.isEmpty else { return nil }
        self.clientID = trimmed
        self.scopes = scopes
    }

    /// The custom URL scheme Google redirects to: the reversed client ID.
    public var callbackScheme: String {
        Self.reversedPrefix + clientID.dropLast(Self.clientIDSuffix.count)
    }

    /// The `redirect_uri` sent in the authorisation and token requests.
    public var redirectURI: String { callbackScheme + ":" + Self.redirectPath }
}
