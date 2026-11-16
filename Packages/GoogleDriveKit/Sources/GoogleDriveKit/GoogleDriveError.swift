import Foundation

/// Everything that can go wrong talking to Google, in words the reader can act on.
public enum GoogleDriveError: Error, LocalizedError, Sendable, Hashable {
    /// No Google account is connected.
    case notSignedIn
    /// Google no longer accepts the saved sign-in (revoked, expired, or the password changed).
    case needsSignInAgain
    /// The reader closed or declined Google's sign-in page.
    case signInCancelled
    /// Google's sign-in redirect could not be used (state mismatch, missing code, OAuth error).
    case signInFailed(reason: String)
    /// The reader signed in but did not allow access to the files this app creates.
    case driveAccessNotGranted
    /// No internet connection, or it kept dropping.
    case noNetwork
    /// The reader's Google storage is full (Drive `storageQuotaExceeded`).
    case storageFull
    /// Google asked us to slow down and kept doing so after several retries.
    case rateLimited
    /// The file or folder is not in Drive (or this app cannot see it).
    case notFound
    /// A transferred file does not match what was expected (size or checksum).
    case checksumMismatch(expected: String, actual: String)
    /// Google answered in a way this app does not handle. `status` is the HTTP status and
    /// `reason` Google's error reason, when there was one, for diagnostics.
    case unexpectedResponse(status: Int?, reason: String?)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "You're not signed in to Google Drive."
        case .needsSignInAgain:
            "Google Drive needs you to sign in again."
        case .signInCancelled:
            "Google sign-in was cancelled."
        case .signInFailed:
            "Google sign-in didn't complete. Please try again."
        case .driveAccessNotGranted:
            "Google Drive access wasn't allowed. Sign in again and allow access to the files this app creates."
        case .noNetwork:
            "Couldn't reach Google Drive. Check your internet connection and try again."
        case .storageFull:
            "Your Google storage is full. Free up space or add storage, then try again."
        case .rateLimited:
            "Google Drive is busy right now. Try again in a few minutes."
        case .notFound:
            "The file wasn't found in Google Drive."
        case .checksumMismatch:
            "The copy in Google Drive doesn't match the original, so it wasn't used."
        case .unexpectedResponse(let status, let reason):
            "Google Drive gave an unexpected response" + Self.diagnostic(status: status, reason: reason) + "."
        }
    }

    private static func diagnostic(status: Int?, reason: String?) -> String {
        switch (status, reason) {
        case let (status?, reason?): " (\(status) \(reason))"
        case let (status?, nil): " (\(status))"
        case let (nil, reason?): " (\(reason))"
        case (nil, nil): ""
        }
    }
}
