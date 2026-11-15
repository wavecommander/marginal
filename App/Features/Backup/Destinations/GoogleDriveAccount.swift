import AuthenticationServices
import Foundation
import GoogleDriveKit
import Observation

/// The reader's Google Drive connection, for the Backup screen to show and drive.
///
/// It owns the one `GoogleAuthSession` of the app (the Google Drive destination uses the same
/// one, so a sign-in here is what the destination's requests use). Call `refresh()` when the
/// screen appears to read the saved sign-in.
@MainActor
@Observable
final class GoogleDriveAccount {
    nonisolated enum State: Hashable, Sendable {
        /// This build has no Google OAuth client ID (`GOOGLE_DRIVE_CLIENT_ID` is empty).
        case notSetUp
        /// No Google account is connected.
        case signedOut
        /// Signed in; the destination can be used.
        case signedIn
        /// Google stopped accepting the saved sign-in (revoked, expired, password changed). Shown
        /// until the reader signs in again or signs out. Not kept across launches: after a
        /// relaunch it reads as `signedOut`.
        case needsSignInAgain
    }

    /// The connection's state.
    private(set) var state: State
    /// `true` while the sign-in sheet is up or its code is being exchanged.
    private(set) var isSigningIn = false

    /// `nil` when the build is not set up.
    @ObservationIgnored let auth: GoogleAuthSession?
    @ObservationIgnored private let webAuthentication: any GoogleDriveWebAuthenticating

    /// - Parameters:
    ///   - auth: the app's Google sign-in, or `nil` when the build is not set up.
    ///   - webAuthentication: presents Google's page (`ASWebAuthenticationSession` by default).
    init(auth: GoogleAuthSession?, webAuthentication: (any GoogleDriveWebAuthenticating)? = nil) {
        self.auth = auth
        self.webAuthentication = webAuthentication ?? GoogleDriveSystemWebAuthentication()
        state = auth == nil ? .notSetUp : .signedOut
    }

    /// Re-reads the saved sign-in. A `needsSignInAgain` state stays until a sign-in succeeds.
    func refresh() async {
        guard let auth else { return }
        let signedIn = (try? await auth.isSignedIn()) ?? false
        if signedIn {
            state = .signedIn
        } else if state != .needsSignInAgain {
            state = .signedOut
        }
    }

    /// Shows Google's sign-in page over `anchor` (the window of the button the reader tapped) and
    /// saves the sign-in.
    ///
    /// - Returns: `true` when signed in; `false` when the reader closed the sheet or declined on
    ///   Google's page (a quiet cancellation: nothing to report), or a sign-in is already showing.
    /// - Throws: `CloudBackupError` (`notSetUp`, `signInFailed`, `driveAccessNotGranted`,
    ///   `noNetwork`, `serviceError`), or the web session's error when the sheet cannot be shown.
    @discardableResult
    func signIn(anchor: ASPresentationAnchor) async throws -> Bool {
        guard let auth else { throw CloudBackupError.notSetUp(destination: GoogleDriveBackupDestination.name) }
        guard !isSigningIn else { return false }
        isSigningIn = true
        defer { isSigningIn = false }

        let request = auth.makeAuthorizationRequest()
        let callback: URL
        do {
            callback = try await webAuthentication.authenticate(
                url: request.url, callbackScheme: auth.configuration.callbackScheme, anchor: anchor)
        } catch is CancellationError {
            return false
        }
        do {
            try await auth.completeSignIn(request: request, callbackURL: callback)
        } catch GoogleDriveError.signInCancelled {
            return false
        } catch is CancellationError {
            return false
        } catch {
            throw CloudBackupError.mapping(google: error, subject: .other)
        }
        state = .signedIn
        return true
    }

    /// Signs out: revokes the sign-in at Google when it can be reached and forgets it on this
    /// iPad either way.
    /// - Throws: the Keychain's error when the saved sign-in could not be removed.
    func signOut() async throws {
        guard let auth else { return }
        _ = try await auth.signOut()
        state = .signedOut
    }

    /// Called by the destination when Google refused the saved sign-in.
    func noteNeedsSignInAgain() {
        guard auth != nil else { return }
        state = .needsSignInAgain
    }

    /// Called by the destination when a request found no sign-in.
    func noteSignedOut() {
        guard auth != nil, state == .signedIn else { return }
        state = .signedOut
    }
}
