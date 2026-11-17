import Foundation

/// Everything that can stop a Google sign-in, with reader-facing descriptions. Associated values
/// are Google's error codes, for logs; they are never shown to the reader and carry no secrets.
public enum GoogleSignInError: Error, Sendable, Hashable, LocalizedError {
    /// The reader closed the sign-in sheet, or the task was cancelled. The app maps
    /// `ASWebAuthenticationSession`'s cancel to this too.
    case cancelled
    /// The redirect's `state` is not this request's (a stale or forged redirect).
    case stateMismatch
    /// The redirect has the wrong scheme or path, or no `code`.
    case redirectInvalid
    /// Google's redirect carried `error=…` (`access_denied` when the reader declined).
    case authorizationDenied(code: String)
    /// Google's token response had no `id_token`.
    case missingIDToken
    /// The token endpoint refused the code: its HTTP status and Google's `error` (such as
    /// `invalid_grant`), when there was one.
    case exchangeFailed(status: Int, code: String?)
    /// Google could not be reached.
    case network
    /// Google answered in a way this package does not understand.
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .cancelled, .authorizationDenied(code: "access_denied"):
            "Google sign-in was cancelled."
        case .network:
            "Couldn’t reach Google. Check your internet connection and try again."
        case .stateMismatch, .redirectInvalid, .authorizationDenied, .missingIDToken, .exchangeFailed,
             .unexpectedResponse:
            "Couldn’t sign in with Google. Try again."
        }
    }

    /// Whether the reader chose to stop (closed the sheet or declined at Google), so the app can
    /// return quietly instead of showing an error.
    public var isCancellation: Bool {
        switch self {
        case .cancelled, .authorizationDenied(code: "access_denied"): true
        default: false
        }
    }
}
