import AuthenticationServices
import Foundation
import UIKit

/// The web step of Google sign-in: shows `url` in a system browser sheet and returns the URL
/// Google redirects to. The reader types their Google password only into Google's page in that
/// sheet; the app never sees it. Tests substitute a fake that returns a chosen callback URL.
protocol GoogleDriveWebAuthenticating: AnyObject {
    /// Presents `url` over `anchor` and returns the callback URL (scheme `callbackScheme`).
    /// - Throws: `CancellationError` when the reader closes the sheet (or declines the system's
    ///   "wants to use google.com to sign in" prompt) or the calling task is cancelled; any other
    ///   error when the sheet could not be shown.
    func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL
}

/// `ASWebAuthenticationSession`, with a custom-scheme callback (the reversed Google client ID).
///
/// On iPadOS 17.4 and later the session is created with `ASWebAuthenticationSession.Callback`
/// (`.customScheme`); on 17.0 to 17.3 with the older `callbackURLScheme:` initialiser, which
/// Apple marks as to be deprecated. Either way the scheme is matched by the session itself, so it
/// does not need to be registered in `CFBundleURLTypes`.
final class GoogleDriveSystemWebAuthentication: NSObject, GoogleDriveWebAuthenticating,
    ASWebAuthenticationPresentationContextProviding {
    /// `true` (the default) asks for a private browser session: no cookies are shared with Safari,
    /// so the system's "wants to use google.com to sign in" prompt is not shown and the sign-in
    /// leaves nothing behind. The reader then signs in to Google each time they connect Drive.
    let prefersEphemeralSession: Bool

    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    init(prefersEphemeralSession: Bool = true) {
        self.prefersEphemeralSession = prefersEphemeralSession
    }

    /// Why the sheet could not be shown.
    struct PresentationError: LocalizedError, Hashable {
        var errorDescription: String? { "The Google sign-in page couldn’t be shown. Try again." }
    }

    func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
        // One sheet at a time: a second request cancels the first.
        session?.cancel()
        self.anchor = anchor
        let state = CallbackState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                state.set(continuation)
                // `@Sendable`, so it is not bound to the main actor: the documentation does not say
                // which thread calls it.
                let completion: @Sendable (URL?, (any Error)?) -> Void = { [weak self] callbackURL, error in
                    Task { @MainActor in
                        self?.session = nil
                        self?.anchor = nil
                    }
                    if let callbackURL {
                        state.resume(with: .success(callbackURL))
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        state.resume(with: .failure(CancellationError()))
                    } else {
                        state.resume(with: .failure(error ?? PresentationError()))
                    }
                }
                let session: ASWebAuthenticationSession
                if #available(iOS 17.4, *) {
                    session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme),
                                                         completionHandler: completion)
                } else {
                    session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme,
                                                         completionHandler: completion)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
                // The session must stay referenced until its completion handler runs.
                self.session = session
                if !session.start() {
                    self.session = nil
                    state.resume(with: .failure(PresentationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.session?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}

/// Resumes a continuation exactly once, from whichever thread finishes first.
private nonisolated final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    func set(_ continuation: CheckedContinuation<URL, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<URL, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
