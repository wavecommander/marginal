import AuthenticationServices
import CryptoKit
import Foundation
import GoogleSignInKit
import UIKit

/// A fresh sign-in from Apple or Google whose ID token carries a challenge's nonce, for one
/// request to the backup service. Nothing in it appears in a description, debug description or
/// mirror.
nonisolated struct CloudIdentityCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let provider: CloudSignInProvider
    /// The ID token, sent to the service as is.
    let idToken: String
    /// Sign in with Apple's authorization code (the service revokes with it); `nil` for Google.
    let authorizationCode: String?
    /// The email in the ID token, shown on this device only and never sent on its own.
    let email: String?
    /// Sign in with Apple's user identifier, to check the credential's state at launch.
    let appleUserID: String?

    var description: String { "CloudIdentityCredential(\(provider.rawValue), <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["provider": provider], displayStyle: .struct) }
}

/// Why a sign-in with Apple or Google did not give a credential.
nonisolated enum CloudSignInError: LocalizedError, Hashable, Sendable {
    /// The reader backed out.
    case cancelled
    /// This build does not offer that way of signing in.
    case unavailable(CloudSignInProvider)
    /// Apple or Google refused, or could not be reached. `message` is reader-facing.
    case failed(CloudSignInProvider, message: String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Signing in was cancelled."
        case .unavailable(let provider): "Sign in with \(provider.name) isn’t available in this version of Tactile Texts."
        case .failed(_, let message): message
        }
    }
}

/// Apple's and Google's sign-in, as the account needs it: a credential for a nonce, and whether
/// an Apple authorization still holds. The system's in the app; fakes in tests.
@MainActor
protocol CloudIdentityProviding: AnyObject {
    /// The ways of signing in this build offers, Apple first. Empty: the service is not available.
    var availableProviders: [CloudSignInProvider] { get }
    /// Asks `provider` for a sign-in whose ID token carries `nonce`, presenting over `anchor`.
    /// Throws `CloudSignInError` (`.cancelled` when the reader backed out).
    func credential(_ provider: CloudSignInProvider, nonce: String, anchor: ASPresentationAnchor?) async throws -> CloudIdentityCredential
    /// Whether Apple says the authorization for `userID` no longer holds (revoked, or not
    /// found). `false` when it holds or Apple could not say.
    func appleAuthorizationEnded(userID: String) async -> Bool
}

// MARK: - The system's

/// Sign in with Apple (`ASAuthorizationAppleIDProvider`, when the build has the entitlement) and
/// Sign in with Google (`ASWebAuthenticationSession` and `GoogleSignInKit`, when the build has a
/// Google client ID).
@MainActor
final class SystemCloudIdentityProvider: CloudIdentityProviding {
    let appleEnabled: Bool
    let google: GoogleSignInConfiguration?
    private let urlSession: URLSession

    init(appleEnabled: Bool, google: GoogleSignInConfiguration?, urlSession: URLSession = .shared) {
        self.appleEnabled = appleEnabled
        self.google = google
        self.urlSession = urlSession
    }

    var availableProviders: [CloudSignInProvider] {
        (appleEnabled ? [.apple] : []) + (google != nil ? [.google] : [])
    }

    func credential(_ provider: CloudSignInProvider, nonce: String, anchor: ASPresentationAnchor?) async throws -> CloudIdentityCredential {
        switch provider {
        case .apple:
            guard appleEnabled else { throw CloudSignInError.unavailable(.apple) }
            return try await AppleSignInFlow(anchor: anchor).run(nonce: nonce)
        case .google:
            guard let google else { throw CloudSignInError.unavailable(.google) }
            return try await GoogleSignInFlow(configuration: google, urlSession: urlSession, anchor: anchor).run(nonce: nonce)
        }
    }

    func appleAuthorizationEnded(userID: String) async -> Bool {
        guard appleEnabled else { return false }
        do {
            switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID) {
            case .revoked, .notFound: return true
            default: return false
            }
        } catch {
            return false
        }
    }
}

/// One Sign in with Apple request, asking for the email, with the nonce set.
@MainActor
private final class AppleSignInFlow: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<CloudIdentityCredential, any Error>?
    private var controller: ASAuthorizationController?

    init(anchor: ASPresentationAnchor?) {
        self.anchor = anchor
    }

    func run(nonce: String) async throws -> CloudIdentityCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = nonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            finish(.failure(CloudSignInError.failed(.apple, message: Self.failure)))
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        finish(.success(CloudIdentityCredential(provider: .apple, idToken: token, authorizationCode: code,
                                                email: GoogleIDTokenClaims.email(in: token) ?? credential.email,
                                                appleUserID: credential.user)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            finish(.failure(CloudSignInError.cancelled))
        } else {
            finish(.failure(CloudSignInError.failed(.apple, message: Self.failure)))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<CloudIdentityCredential, any Error>) {
        controller = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private static let failure = "Couldn’t sign in with Apple. Try again."
}

/// One Sign in with Google: the authorization page in an `ASWebAuthenticationSession`, then the
/// code exchange for the ID token (`GoogleSignInKit`).
@MainActor
private final class GoogleSignInFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let client: GoogleSignInClient
    private let anchor: ASPresentationAnchor?
    private var session: ASWebAuthenticationSession?

    init(configuration: GoogleSignInConfiguration, urlSession: URLSession, anchor: ASPresentationAnchor?) {
        client = GoogleSignInClient(configuration: configuration, urlSession: urlSession)
        self.anchor = anchor
    }

    func run(nonce: String) async throws -> CloudIdentityCredential {
        let request = client.makeRequest(nonce: nonce)
        let scheme = client.configuration.callbackURLScheme
        let redirect: URL = try await withCheckedThrowingContinuation { continuation in
            let handler: @Sendable (URL?, (any Error)?) -> Void = { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CloudSignInError.cancelled)
                } else {
                    continuation.resume(throwing: CloudSignInError.failed(.google, message: GoogleSignInError.unexpectedResponse.localizedDescription))
                }
            }
            let session = Self.makeSession(url: request.url, scheme: scheme, handler: handler)
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: CloudSignInError.failed(.google, message: GoogleSignInError.unexpectedResponse.localizedDescription))
            }
        }
        session = nil
        do {
            let result = try await client.complete(request, redirect: redirect)
            return CloudIdentityCredential(provider: .google, idToken: result.idToken, authorizationCode: nil, email: result.email,
                                           appleUserID: nil)
        } catch {
            if error.isCancellation { throw CloudSignInError.cancelled }
            throw CloudSignInError.failed(.google, message: error.localizedDescription)
        }
    }

    /// The session for a custom-scheme callback. iPadOS 17.4 added the `callback:` form and
    /// marked the scheme form to be deprecated; before 17.4 only the scheme form exists. The two
    /// behave the same for a custom scheme.
    private static func makeSession(url: URL, scheme: String,
                                    handler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> ASWebAuthenticationSession {
        if #available(iOS 17.4, *) {
            return ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: handler)
        }
        return ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: handler)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}

// MARK: - The dev Worker's test issuer

#if DEBUG
/// Debug builds only: ID tokens from the `dev` Worker's test issuer (`DEV_TEST_SIGNIN_SECRET`,
/// see `Backend/backup-worker/README.md`, "The dev test issuer"), standing in for Apple and
/// Google so the simulator and the end-to-end test can sign in to the `dev` deployment. The
/// production Worker refuses them, and their identities can never reach an Apple or Google
/// account's.
@MainActor
final class DevTestCloudIdentityProvider: CloudIdentityProviding {
    static let issuer = "tactile-texts-dev-test"
    static let authorizationCode = "dev-test-authorization-code"

    private let secret: String
    private let audience: String
    private let subjectSource: () -> String
    private let emailSource: (CloudSignInProvider) -> String
    private let now: () -> Date
    /// The named test user signing in, when the provider follows one (the app's debug build).
    let user: DevTestUser?

    /// The test identity's subject, the same for both stand-ins (they are kept apart by the Worker).
    var subject: String { subjectSource() }

    /// A fixed subject (the end-to-end tests).
    init(secret: String, audience: String, subject: String, now: @escaping () -> Date = { Date() }) {
        self.secret = secret
        self.audience = audience
        subjectSource = { subject }
        emailSource = { "\($0.rawValue)-dev-test@example.invalid" }
        self.now = now
        user = nil
    }

    /// Signs in as `user`, whatever its name is at the moment of signing in: the same name on
    /// any simulator is the same account. The email shown on this device is `<name>@dev-test.invalid`.
    init(secret: String, audience: String, user: DevTestUser, now: @escaping () -> Date = { Date() }) {
        self.secret = secret
        self.audience = audience
        subjectSource = { user.subject }
        emailSource = { _ in "\(user.name)@dev-test.invalid" }
        self.now = now
        self.user = user
    }

    var availableProviders: [CloudSignInProvider] { [.apple, .google] }

    func credential(_ provider: CloudSignInProvider, nonce: String, anchor: ASPresentationAnchor?) async throws -> CloudIdentityCredential {
        let email = emailSource(provider)
        return CloudIdentityCredential(provider: provider, idToken: token(nonce: nonce, email: email),
                                       authorizationCode: provider == .apple ? Self.authorizationCode : nil,
                                       email: email, appleUserID: nil)
    }

    func appleAuthorizationEnded(userID: String) async -> Bool { false }

    /// An HS256 JWT: `iss`, `aud`, `sub`, `nonce`, `iat`, `exp` (five minutes), `email`.
    func token(nonce: String, email: String?) -> String {
        let issued = Int(now().timeIntervalSince1970)
        var claims: [String: Any] = ["iss": Self.issuer, "aud": audience, "sub": subject, "nonce": nonce,
                                     "iat": issued, "exp": issued + 300]
        if let email { claims["email"] = email }
        let header = Self.base64URL(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = Self.base64URL((try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data())
        let input = "\(header).\(payload)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return "\(input).\(Self.base64URL(Data(signature)))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
