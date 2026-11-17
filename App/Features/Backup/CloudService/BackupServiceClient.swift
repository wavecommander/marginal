import CryptoKit
import Foundation
import S3Kit

// The app's side of the Tactile Texts backup service's HTTP contract
// (`Backend/backup-worker/README.md`, "HTTP contract", and `src/contract.ts`): typed requests,
// responses and errors, and the client that sends them.

// MARK: - Responses

/// Which S3 operations a session's credentials allow (`mode`).
nonisolated enum BackupServiceAccessMode: String, Hashable, Sendable, CaseIterable {
    /// Everything a backup needs.
    case readWrite = "read-write"
    /// Active but over the storage allowance: read and delete (to make room), no upload.
    case readDelete = "read-delete"
    /// The subscription ended less than `READ_ONLY_DAYS` ago: restore only.
    case readOnly = "read-only"

    var allowsUpload: Bool { self == .readWrite }
    var allowsDelete: Bool { self != .readOnly }
}

/// The subscription as the service sees it (`SubscriptionInfo`).
nonisolated struct BackupServiceSubscriptionInfo: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case active
        /// Apple's billing grace period: access continues.
        case gracePeriod
        /// Apple is retrying a failed renewal: access continues.
        case billingRetry
        case ended
        /// Refunded or revoked.
        case revoked
        /// A state this version of the app does not know.
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "active": self = .active
            case "grace-period": self = .gracePeriod
            case "billing-retry": self = .billingRetry
            case "ended": self = .ended
            case "revoked": self = .revoked
            default: self = .other(raw)
            }
        }
    }

    let state: State
    /// `Production`, `Sandbox` or `Xcode`.
    let environment: String
    let productID: String
    /// End of the paid period Apple last reported.
    let expiresAt: Date?
    /// When access ended; `nil` while active.
    let endedAt: Date?
    /// The last moment a restore is possible; `nil` while active.
    let readOnlyUntil: Date?
    /// When the backups are deleted unless the reader resubscribes; `nil` while active.
    let deleteAfter: Date?
}

/// Storage used under the reader's folder at the service's last count (`UsageInfo`).
nonisolated struct BackupServiceUsage: Hashable, Sendable {
    let bytes: Int64
    let allowanceBytes: Int64
    /// `bytes > allowanceBytes` (the mode is then `read-delete`).
    let overAllowance: Bool
    let countedAt: Date?
}

/// Where the session's credentials reach (`storage`).
nonisolated struct BackupServiceStorage: Hashable, Sendable {
    /// `https://<host>`.
    let endpoint: URL
    let host: String
    let region: String
    let bucket: String
    /// The only folder the credentials reach (`users/<key>/` or `sandbox/<key>/`).
    let prefix: String

    /// The S3 endpoint for this storage, or `nil` when the service named something S3Kit refuses.
    var s3Endpoint: S3Endpoint? {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host, !host.isEmpty else { return nil }
        let path = components.path == "/" ? "" : components.path
        return S3Endpoint(scheme: scheme, host: host.contains(":") ? "[\(host)]" : host, port: components.port,
                          basePath: path, region: region, bucket: bucket, prefix: prefix)
    }
}

/// An answer to `POST /v1/session`. The credentials never appear in a description, debug
/// description or mirror.
nonisolated struct BackupServiceSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let mode: BackupServiceAccessMode
    /// Temporary R2 credentials (with session token and expiry).
    let credentials: S3Credentials
    let storage: BackupServiceStorage
    let subscription: BackupServiceSubscriptionInfo
    let usage: BackupServiceUsage

    var description: String {
        "BackupServiceSession(mode: \(mode.rawValue), bucket: \(storage.bucket), "
            + "expires: \(credentials.expiration.map { "\($0)" } ?? "unknown"), credentials: <redacted>)"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["mode": mode, "storage": storage, "subscription": subscription, "usage": usage],
               displayStyle: .struct)
    }
}

/// An answer to `POST /v1/delete-my-data`.
nonisolated struct BackupServiceDeletion: Hashable, Sendable {
    /// Everything is gone (and the service's record of the subscription with it).
    let done: Bool
    /// Objects this call deleted.
    let deletedObjects: Int
}

/// The two ways of signing in to Tactile Texts Cloud (the account's `provider`).
nonisolated enum CloudSignInProvider: String, Hashable, Sendable, CaseIterable, Codable {
    case apple
    case google

    /// "Apple", "Google".
    var name: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }

    /// The other one (what Change to Sign in with … changes to).
    var other: CloudSignInProvider { self == .apple ? .google : .apple }
}

/// A single-use challenge from `/v1/challenge`, for a request whose ID tokens are bound to it.
nonisolated struct BackupServiceChallenge: Hashable, Sendable {
    /// As the service sent it (base64), to send back in the body.
    let text: String
    let bytes: Data

    /// What Apple's and Google's ID tokens must carry as `nonce`: the lower-case hex SHA-256 of
    /// the challenge's bytes.
    var nonce: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// One signed-in device of the account (`DeviceInfo`).
nonisolated struct BackupServiceDevice: Hashable, Sendable, Identifiable {
    let sessionID: String
    let createdAt: Date?
    let lastUsedAt: Date?
    /// The device's name, encrypted by the app with the backup key; `nil` when none was sent.
    let label: String?
    /// The device that asked.
    let isCurrent: Bool

    var id: String { sessionID }
}

/// The account as the service describes it (`AccountResponse`).
nonisolated struct BackupServiceAccountInfo: Hashable, Sendable {
    /// 32 hex digits, random. Names the account's Keychain item for the backup key.
    let accountID: String
    let provider: CloudSignInProvider
    /// Passed to StoreKit on every purchase, so the transaction names the account.
    let appAccountToken: UUID?
    let createdAt: Date?
    /// Oldest first.
    let devices: [BackupServiceDevice]
    let subscription: BackupServiceSubscriptionInfo?
    let usage: BackupServiceUsage?
}

/// An answer to sign-in. The session token never appears in a description, debug description or
/// mirror.
nonisolated struct BackupServiceSignIn: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let deviceSessionToken: String
    let sessionID: String
    let newAccount: Bool
    let account: BackupServiceAccountInfo

    var description: String { "BackupServiceSignIn(newAccount: \(newAccount), provider: \(account.provider.rawValue), token: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["newAccount": newAccount, "provider": account.provider], displayStyle: .struct) }
}

// MARK: - Errors

/// What the backup service refused, or why it could not be asked. One case per contract error
/// code (`ERRORS` in `src/contract.ts`), plus the client's own. `errorDescription` is
/// reader-facing; no case carries a token, credential or JWS.
nonisolated enum CloudServiceError: LocalizedError, Hashable, Sendable {
    // The contract's codes.
    case badRequest
    case notFound
    case methodNotAllowed
    case bodyTooLarge
    case unsupportedMediaType
    case challengeInvalid
    case attestationInvalid
    case deviceAlreadyAttested
    case deviceUnknown
    case assertionInvalid
    case transactionInvalid
    case productUnknown
    case environmentNotAccepted
    /// Refunded or revoked: no access. The data is deleted `DELETE_AFTER_DAYS` after the revocation.
    case subscriptionRevoked(BackupServiceSubscriptionInfo?)
    /// Ended long enough ago that there is no access, but the data is kept until
    /// `deleteAfter`; resubscribing restores access.
    case subscriptionLapsed(BackupServiceSubscriptionInfo?)
    /// Ended and the backups have been deleted.
    case dataDeleted(BackupServiceSubscriptionInfo?)
    case notificationInvalid
    case internalError
    /// An Apple or Google sign-in failed the service's checks (expired, or not for this app).
    case idTokenInvalid
    /// The service does not accept this way of signing in.
    case providerDisabled
    /// The service could not reach Apple or Google to check a sign-in.
    case providerUnreachable
    /// This device's session has ended (signed out here or everywhere, ended by Apple, or the
    /// account was deleted). The app becomes signed out; nothing on the iPad changes.
    case sessionInvalid
    /// The sign-in given as proof is not the one the account uses now.
    case identityMismatch
    /// Changing the sign-in: the new Apple or Google identity already has an account.
    case identityInUse
    /// The account is being deleted.
    case accountDeleting
    /// The subscription on this Apple Account was bought for another Tactile Texts Cloud account.
    case subscriptionOtherAccount
    /// The subscription on this Apple Account is in use by another account (moved less than 30
    /// days ago).
    case subscriptionInUse

    // The client's own.
    /// A status or code this app does not understand. `code` is for logs.
    case unexpectedResponse(status: Int, code: String?)
    /// The service could not be reached.
    case noNetwork
    /// This device has no App Attest (the simulator, for example) and the build has no
    /// development bypass, so the service cannot be used here.
    case appAttestUnavailable
    /// The account has no subscription (`not-subscribed`).
    case notSubscribed
    /// This device is not signed in; the service was not asked.
    case notSignedIn

    static let serviceName = "Tactile Texts Cloud"

    /// The case for a contract error code, or `nil` for an unknown code.
    init?(code: String, subscription: BackupServiceSubscriptionInfo?) {
        switch code {
        case "bad-request": self = .badRequest
        case "not-found": self = .notFound
        case "method-not-allowed": self = .methodNotAllowed
        case "body-too-large": self = .bodyTooLarge
        case "unsupported-media-type": self = .unsupportedMediaType
        case "challenge-invalid": self = .challengeInvalid
        case "attestation-invalid": self = .attestationInvalid
        case "device-already-attested": self = .deviceAlreadyAttested
        case "device-unknown": self = .deviceUnknown
        case "assertion-invalid": self = .assertionInvalid
        case "transaction-invalid": self = .transactionInvalid
        case "product-unknown": self = .productUnknown
        case "environment-not-accepted": self = .environmentNotAccepted
        case "subscription-revoked": self = .subscriptionRevoked(subscription)
        case "subscription-lapsed": self = .subscriptionLapsed(subscription)
        case "data-deleted": self = .dataDeleted(subscription)
        case "notification-invalid": self = .notificationInvalid
        case "internal": self = .internalError
        case "id-token-invalid": self = .idTokenInvalid
        case "provider-disabled": self = .providerDisabled
        case "provider-unreachable": self = .providerUnreachable
        case "session-invalid": self = .sessionInvalid
        case "identity-mismatch": self = .identityMismatch
        case "identity-in-use": self = .identityInUse
        case "account-deleting": self = .accountDeleting
        case "not-subscribed": self = .notSubscribed
        case "subscription-other-account": self = .subscriptionOtherAccount
        case "subscription-in-use": self = .subscriptionInUse
        default: return nil
        }
    }

    /// The contract's code, `nil` for the client's own cases.
    var code: String? {
        switch self {
        case .badRequest: "bad-request"
        case .notFound: "not-found"
        case .methodNotAllowed: "method-not-allowed"
        case .bodyTooLarge: "body-too-large"
        case .unsupportedMediaType: "unsupported-media-type"
        case .challengeInvalid: "challenge-invalid"
        case .attestationInvalid: "attestation-invalid"
        case .deviceAlreadyAttested: "device-already-attested"
        case .deviceUnknown: "device-unknown"
        case .assertionInvalid: "assertion-invalid"
        case .transactionInvalid: "transaction-invalid"
        case .productUnknown: "product-unknown"
        case .environmentNotAccepted: "environment-not-accepted"
        case .subscriptionRevoked: "subscription-revoked"
        case .subscriptionLapsed: "subscription-lapsed"
        case .dataDeleted: "data-deleted"
        case .notificationInvalid: "notification-invalid"
        case .internalError: "internal"
        case .idTokenInvalid: "id-token-invalid"
        case .providerDisabled: "provider-disabled"
        case .providerUnreachable: "provider-unreachable"
        case .sessionInvalid: "session-invalid"
        case .identityMismatch: "identity-mismatch"
        case .identityInUse: "identity-in-use"
        case .accountDeleting: "account-deleting"
        case .notSubscribed: "not-subscribed"
        case .subscriptionOtherAccount: "subscription-other-account"
        case .subscriptionInUse: "subscription-in-use"
        case .unexpectedResponse, .noNetwork, .appAttestUnavailable, .notSignedIn: nil
        }
    }

    /// The subscription dates the service sent with the error, if any.
    var subscription: BackupServiceSubscriptionInfo? {
        switch self {
        case .subscriptionRevoked(let info), .subscriptionLapsed(let info), .dataDeleted(let info): info
        default: nil
        }
    }

    var errorDescription: String? {
        let name = Self.serviceName
        switch self {
        case .badRequest, .notFound, .methodNotAllowed, .bodyTooLarge, .unsupportedMediaType, .notificationInvalid:
            return "\(name) didn’t understand this version of Tactile Texts. Check for an update to the app."
        case .challengeInvalid:
            return "The request to \(name) took too long and expired. Try again."
        case .attestationInvalid, .assertionInvalid:
            return "\(name) couldn’t confirm that this is the genuine Tactile Texts app. Try again later."
        case .deviceAlreadyAttested, .deviceUnknown:
            return DeviceKind.current.pick(iPad: "This iPad needs to register with \(name) again. Try again.",
                                           iPhone: "This iPhone needs to register with \(name) again. Try again.")
        case .transactionInvalid:
            return "\(name) couldn’t verify your subscription. Try Restore Purchases, or try again later."
        case .productUnknown:
            return "This purchase doesn’t include \(name)."
        case .environmentNotAccepted:
            return "\(name) doesn’t accept purchases from this kind of build of Tactile Texts."
        case .subscriptionRevoked(let info):
            if let date = info?.deleteAfter {
                return "Your \(name) subscription was refunded or revoked, so your backups can’t be used. They will be deleted on \(Self.day(date))."
            }
            return "Your \(name) subscription was refunded or revoked, so your backups can’t be used."
        case .subscriptionLapsed(let info):
            if let date = info?.deleteAfter {
                return "Your \(name) subscription has ended. Resubscribe before \(Self.day(date)) to get your backups back; after that they will be deleted."
            }
            return "Your \(name) subscription has ended. Resubscribe to get your backups back before they are deleted."
        case .dataDeleted:
            return "Your \(name) subscription ended and its backups have been deleted."
        case .internalError:
            return "\(name) isn’t working right now. Try again later."
        case .unexpectedResponse:
            return "\(name) gave an unexpected response. Try again later."
        case .noNetwork:
            return "Couldn’t reach \(name). Check your internet connection and try again."
        case .appAttestUnavailable:
            return "\(name) isn’t available on this device, because it can’t confirm that it’s running the genuine Tactile Texts app."
        case .notSubscribed:
            return "Subscribe to \(name) to back up there."
        case .notSignedIn:
            return "Sign in to \(name) to back up there."
        case .idTokenInvalid:
            return "\(name) couldn’t confirm your sign-in. Try again."
        case .providerDisabled:
            return "That way of signing in isn’t available for \(name)."
        case .providerUnreachable:
            return "\(name) couldn’t reach Apple or Google to check your sign-in. Try again later."
        case .sessionInvalid:
            return DeviceKind.current.pick(
                iPad: "You’ve been signed out of \(name). The books on this iPad are just as they were, but they aren’t backed up there until you sign in again.",
                iPhone: "You’ve been signed out of \(name). The books on this iPhone are just as they were, but they aren’t backed up there until you sign in again.")
        case .identityMismatch:
            return "That isn’t the sign-in your \(name) account uses now. Confirm with the account’s current sign-in."
        case .identityInUse:
            return "That sign-in already has a \(name) account of its own, so this account can’t change to it. If that account is yours, sign in with it and delete it first."
        case .accountDeleting:
            return "This \(name) account is being deleted."
        case .subscriptionOtherAccount:
            return "The subscription on this Apple Account was bought for a different \(name) account. Sign in with that account to use it."
        case .subscriptionInUse:
            return "The subscription on this Apple Account is being used by a different \(name) account. It can move to this account 30 days after it last moved, or you can sign in with that account."
        }
    }

    /// A date as the reader reads it ("15 December 2026").
    static func day(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }
}

// MARK: - Client

/// Talks to the backup service: health, App Attest registration, signing in and out, the
/// account, sessions and deletion.
///
/// **Authenticated requests** (everything but health): a fresh challenge (or the one given, for
/// a request carrying ID tokens bound to it), the JSON body built
/// once, and an App Attest assertion over **exactly those bytes**, which are then sent unchanged
/// with `X-App-Attest-Key-Id` and `X-App-Attest-Assertion`.
///
/// - The first time (the attest client has no attested key: its `assertion(for:)` throws
///   `AppAttestError.keyInvalidated`) the key is registered with `/v1/challenge` then
///   `/v1/attest`; `device-already-attested` counts as registered.
/// - When the service answers `device-unknown` or `assertion-invalid`, the attest client is
///   reset, a new key is registered and the request is sent again, **once**.
/// - Where App Attest is unsupported (the simulator), the request carries `X-App-Attest-Bypass`
///   when a bypass secret is configured (only the `dev` Worker honours it); otherwise it fails
///   with `appAttestUnavailable` without asking the service.
/// - Authenticated requests are sent one at a time, so assertion counters reach the service in
///   the order they were made.
///
/// Errors: `CloudServiceError` (every contract code, `noNetwork`, `unexpectedResponse`,
/// `appAttestUnavailable`), `AppAttestError` from App Attest itself, and `CancellationError`.
/// Nothing sensitive (JWS, credentials, assertions) is logged or described.
actor BackupServiceClient {
    static let keyIDHeader = "X-App-Attest-Key-Id"
    static let assertionHeader = "X-App-Attest-Assertion"
    static let bypassHeader = "X-App-Attest-Bypass"

    nonisolated let baseURL: URL
    private let attest: any AppAttestClient
    private let attestBypassSecret: String?
    private let urlSession: URLSession
    private var queueTail: Task<Void, Never>?
    private var registration: Task<Void, any Error>?

    /// - Parameters:
    ///   - baseURL: the service, `https://host[:port]` (no path).
    ///   - attest: App Attest (`DeviceAppAttestClient` in the app).
    ///   - attestBypassSecret: the `dev` Worker's bypass secret, used only where App Attest is
    ///     unsupported; `nil` for none.
    ///   - urlSession: every request (tests pass a stubbed one).
    init(baseURL: URL, attest: any AppAttestClient, attestBypassSecret: String? = nil, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.attest = attest
        self.attestBypassSecret = attestBypassSecret.flatMap { $0.isEmpty ? nil : $0 }
        self.urlSession = urlSession
    }

    init(configuration: BackupServiceConfiguration, attest: any AppAttestClient, urlSession: URLSession = .shared) {
        self.init(baseURL: configuration.baseURL, attest: attest, attestBypassSecret: configuration.attestBypassSecret,
                  urlSession: urlSession)
    }

    // MARK: Endpoints

    /// `GET /v1/health`: the deployment's environment (`dev` or `production`).
    func health() async throws -> String {
        let (data, status) = try await send(path: "/v1/health", method: "GET", body: nil, headers: [:])
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        return try Self.decode(HealthBody.self, data, status: status).environment
    }

    /// `POST /v1/challenge`, for a request whose ID tokens must carry its `nonce` (sign-in,
    /// changing the sign-in, deleting the account): fetch it first, ask Apple or Google with its
    /// `nonce`, then pass it to that request. Valid for five minutes, once.
    func challenge() async throws -> BackupServiceChallenge {
        let (text, bytes) = try await fetchChallenge()
        return BackupServiceChallenge(text: text, bytes: bytes)
    }

    /// `POST /v1/auth/apple` or `/v1/auth/google`: signs in to the identity's account (creating
    /// it on the first sign-in) and starts this device's session.
    func signIn(provider: CloudSignInProvider, challenge: BackupServiceChallenge, idToken: String,
                authorizationCode: String?, deviceLabel: String?) async throws -> BackupServiceSignIn {
        var body = RequestBody(action: provider == .apple ? "auth-apple" : "auth-google")
        body.idToken = idToken
        body.authorizationCode = provider == .apple ? authorizationCode : nil
        body.deviceLabel = deviceLabel
        let data = try await authenticated(body, challenge: challenge)
        return try Self.decode(SignInBody.self, data, status: 200).value()
    }

    /// `POST /v1/auth/change`: the account's sign-in becomes `newProvider`'s. Both ID tokens
    /// carry `challenge`'s nonce.
    func changeSignIn(sessionToken: String, challenge: BackupServiceChallenge, currentIdToken: String,
                      currentAuthorizationCode: String?, newProvider: CloudSignInProvider,
                      newIdToken: String) async throws -> BackupServiceAccountInfo {
        var body = RequestBody(action: "auth-change", deviceSessionToken: sessionToken)
        body.currentIdToken = currentIdToken
        body.currentAuthorizationCode = currentAuthorizationCode
        body.newProvider = newProvider.rawValue
        body.newIdToken = newIdToken
        let data = try await authenticated(body, challenge: challenge)
        return try Self.decode(AccountBody.self, data, status: 200).value()
    }

    /// `POST /v1/auth/signout` (`everywhere`: `/v1/auth/signout-all`). Returns the sessions ended.
    @discardableResult
    func signOut(sessionToken: String, everywhere: Bool) async throws -> Int {
        let data = try await authenticated(RequestBody(action: everywhere ? "auth-signout-all" : "auth-signout",
                                                       deviceSessionToken: sessionToken))
        return try Self.decode(SignOutBody.self, data, status: 200).endedSessions
    }

    /// `POST /v1/account`: the account screen (devices, subscription). `deviceLabel` sets this
    /// device's encrypted name.
    func account(sessionToken: String, deviceLabel: String? = nil) async throws -> BackupServiceAccountInfo {
        var body = RequestBody(action: "account", deviceSessionToken: sessionToken)
        body.deviceLabel = deviceLabel
        let data = try await authenticated(body)
        return try Self.decode(AccountBody.self, data, status: 200).value()
    }

    /// The proof the first call of `deleteAccount` needs: a fresh ID token from the account's
    /// current sign-in, bound to `challenge`, and for Apple its authorization code.
    struct DeletionProof: Sendable {
        let challenge: BackupServiceChallenge
        let idToken: String
        let authorizationCode: String?
    }

    /// `POST /v1/account/delete`: one step of deleting the account. The first call carries
    /// `proof`; later calls pass `nil`. Call until `done`.
    func deleteAccount(sessionToken: String, proof: DeletionProof?) async throws -> BackupServiceDeletion {
        var body = RequestBody(action: "account-delete", deviceSessionToken: sessionToken)
        body.idToken = proof?.idToken
        body.authorizationCode = proof?.authorizationCode
        let data = try await authenticated(body, challenge: proof?.challenge)
        let decoded = try Self.decode(DeletionBody.self, data, status: 200)
        return BackupServiceDeletion(done: decoded.done, deletedObjects: decoded.deletedObjects)
    }

    /// `POST /v1/session`: temporary credentials, the storage they reach, the mode, the
    /// subscription and the usage. The signed transaction is sent when the app has one.
    func session(sessionToken: String, signedTransaction: String?, signedRenewalInfo: String?) async throws -> BackupServiceSession {
        var body = RequestBody(action: "session", deviceSessionToken: sessionToken)
        body.signedTransaction = signedTransaction
        body.signedRenewalInfo = signedTransaction == nil ? nil : signedRenewalInfo
        let data = try await authenticated(body)
        return try Self.decode(SessionBody.self, data, status: 200).value()
    }

    /// `POST /v1/delete-my-data`: one bounded batch; call again until `done`.
    func deleteMyData(sessionToken: String) async throws -> BackupServiceDeletion {
        let data = try await authenticated(RequestBody(action: "delete-my-data", deviceSessionToken: sessionToken))
        let body = try Self.decode(DeletionBody.self, data, status: 200)
        return BackupServiceDeletion(done: body.done, deletedObjects: body.deletedObjects)
    }

    // MARK: Authenticated requests

    /// Sends `body` as an attested request. Without `challenge` a fresh one is fetched, and a
    /// `device-unknown` or `assertion-invalid` answer starts over with a new key, once. With a
    /// `challenge` (whose nonce is in ID tokens the body carries) the request is sent once: the
    /// service spends the challenge even when it refuses, so a retry would need new ID tokens;
    /// the key is reset for the reader's next try.
    private func authenticated(_ body: RequestBody, challenge: BackupServiceChallenge? = nil) async throws -> Data {
        try await serialized {
            do {
                return try await self.attempt(body, challenge: challenge)
            } catch let error as CloudServiceError where error == .deviceUnknown || error == .assertionInvalid {
                await self.attest.reset()
                if challenge != nil { throw error }
                return try await self.attempt(body, challenge: nil)
            }
        }
    }

    private func attempt(_ template: RequestBody, challenge given: BackupServiceChallenge?) async throws -> Data {
        var headers: [String: String] = [:]
        let useBypass = !attest.isSupported
        if useBypass {
            guard let attestBypassSecret else { throw CloudServiceError.appAttestUnavailable }
            headers[Self.bypassHeader] = attestBypassSecret
        }
        var request = template
        if let given {
            request.challenge = given.text
        } else {
            request.challenge = try await fetchChallenge().text
        }
        let body = try Self.encode(request)
        if !useBypass {
            let assertion: AppAttestAssertion
            do {
                assertion = try await attest.assertion(for: body)
            } catch AppAttestError.keyInvalidated {
                // No attested key yet (or it was lost): register one, then sign.
                try await register()
                assertion = try await attest.assertion(for: body)
            }
            headers[Self.keyIDHeader] = assertion.keyID
            headers[Self.assertionHeader] = assertion.assertionObject.base64EncodedString()
        }
        let (data, status) = try await send(path: Self.path(for: template.action), method: "POST", body: body, headers: headers)
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        return data
    }

    /// The endpoint each action names (`ENDPOINT_ACTIONS` in `src/contract.ts`).
    nonisolated static func path(for action: String) -> String {
        switch action {
        case "auth-apple": "/v1/auth/apple"
        case "auth-google": "/v1/auth/google"
        case "auth-change": "/v1/auth/change"
        case "auth-signout": "/v1/auth/signout"
        case "auth-signout-all": "/v1/auth/signout-all"
        case "account-delete": "/v1/account/delete"
        default: "/v1/\(action)"
        }
    }

    /// Registers the attest client's key (`/v1/challenge`, then `/v1/attest`). Concurrent callers
    /// share one registration.
    private func register() async throws {
        if let registration { return try await registration.value }
        let task = Task { try await self.performRegistration() }
        registration = task
        defer { registration = nil }
        try await task.value
    }

    private func performRegistration() async throws {
        let challenge = try await fetchChallenge()
        let attestation = try await attest.attest(challenge: challenge.bytes)
        let body = try Self.encode(AttestBody(keyId: attestation.keyID, challenge: challenge.text,
                                              attestation: attestation.attestationObject.base64EncodedString()))
        let (data, status) = try await send(path: "/v1/attest", method: "POST", body: body, headers: [:])
        if status == 201 || status == 200 { return }
        let error = Self.failure(status: status, data: data)
        if error as? CloudServiceError == .deviceAlreadyAttested { return } // registered already: use it
        throw error
    }

    private func fetchChallenge() async throws -> (text: String, bytes: Data) {
        let (data, status) = try await send(path: "/v1/challenge", method: "POST", body: Data("{}".utf8), headers: [:])
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let text = try Self.decode(ChallengeBody.self, data, status: status).challenge
        guard let bytes = Data(base64Encoded: text), !bytes.isEmpty else {
            throw CloudServiceError.unexpectedResponse(status: status, code: "challenge not base64")
        }
        return (text, bytes)
    }

    /// Runs authenticated requests one after another.
    private func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task<T, any Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await body()
        }
        queueTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: HTTP

    private func send(path: String, method: String, body: Data?, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudServiceError.unexpectedResponse(status: 0, code: "not HTTP")
            }
            return (data, http.statusCode)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw CloudServiceError.noNetwork
        }
    }

    /// The error a non-success answer stands for.
    static func failure(status: Int, data: Data) -> any Error {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            return CloudServiceError.unexpectedResponse(status: status, code: nil)
        }
        let info = body.subscription.flatMap { try? $0.value() }
        return CloudServiceError(code: body.error.code, subscription: info)
            ?? CloudServiceError.unexpectedResponse(status: status, code: body.error.code)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, status: Int) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CloudServiceError.unexpectedResponse(status: status, code: "undecodable \(type)")
        }
    }

    /// An ISO 8601 time with or without fractional seconds.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

// MARK: - Wire format

/// Every attested request's body: `action`, `challenge`, and the fields its endpoint takes (a
/// field left `nil` is not sent). Never described: it carries tokens.
nonisolated private struct RequestBody: Encodable, Sendable {
    var action: String
    var challenge: String?
    var deviceSessionToken: String?
    var signedTransaction: String?
    var signedRenewalInfo: String?
    var idToken: String?
    var authorizationCode: String?
    var deviceLabel: String?
    var currentIdToken: String?
    var currentAuthorizationCode: String?
    var newProvider: String?
    var newIdToken: String?

    init(action: String, deviceSessionToken: String? = nil) {
        self.action = action
        self.deviceSessionToken = deviceSessionToken
    }
}

nonisolated private struct SignOutBody: Decodable {
    let endedSessions: Int
}

nonisolated private struct AccountBody: Decodable {
    struct Device: Decodable {
        let sessionId: String
        let createdAt: String?
        let lastUsedAt: String?
        let label: String?
        let current: Bool
    }
    struct Usage: Decodable {
        let bytes: Int64
        let allowanceBytes: Int64
        let overAllowance: Bool
        let countedAt: String?
    }

    let accountId: String
    let provider: String
    let appAccountToken: String
    let createdAt: String?
    let devices: [Device]
    let subscription: SubscriptionBody?
    let usage: Usage?

    func value() throws -> BackupServiceAccountInfo {
        guard !accountId.isEmpty, accountId.count <= 64, accountId.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "account id")
        }
        guard let provider = CloudSignInProvider(rawValue: provider) else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "provider")
        }
        return BackupServiceAccountInfo(
            accountID: accountId.lowercased(), provider: provider, appAccountToken: UUID(uuidString: appAccountToken),
            createdAt: BackupServiceClient.date(createdAt),
            devices: devices.map {
                BackupServiceDevice(sessionID: $0.sessionId, createdAt: BackupServiceClient.date($0.createdAt),
                                    lastUsedAt: BackupServiceClient.date($0.lastUsedAt), label: $0.label, isCurrent: $0.current)
            },
            subscription: try subscription?.value(),
            usage: usage.map { BackupServiceUsage(bytes: $0.bytes, allowanceBytes: $0.allowanceBytes,
                                                  overAllowance: $0.overAllowance, countedAt: BackupServiceClient.date($0.countedAt)) })
    }
}

nonisolated private struct SignInBody: Decodable {
    let deviceSessionToken: String
    let sessionId: String
    let newAccount: Bool
    let account: AccountBody

    func value() throws -> BackupServiceSignIn {
        guard !deviceSessionToken.isEmpty else { throw CloudServiceError.unexpectedResponse(status: 200, code: "session token") }
        return BackupServiceSignIn(deviceSessionToken: deviceSessionToken, sessionID: sessionId, newAccount: newAccount,
                                   account: try account.value())
    }
}

nonisolated private struct AttestBody: Encodable {
    let keyId: String
    let challenge: String
    let attestation: String
}

nonisolated private struct HealthBody: Decodable {
    let environment: String
}

nonisolated private struct ChallengeBody: Decodable {
    let challenge: String
}

nonisolated private struct DeletionBody: Decodable {
    let done: Bool
    let deletedObjects: Int
}

nonisolated private struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
    }
    let error: Detail
    let subscription: SubscriptionBody?
}

nonisolated private struct SubscriptionBody: Decodable {
    let state: String
    let environment: String
    let productId: String
    let expiresAt: String?
    let endedAt: String?
    let readOnlyUntil: String?
    let deleteAfter: String?

    func value() throws -> BackupServiceSubscriptionInfo {
        BackupServiceSubscriptionInfo(state: .init(state), environment: environment, productID: productId,
                                      expiresAt: BackupServiceClient.date(expiresAt), endedAt: BackupServiceClient.date(endedAt),
                                      readOnlyUntil: BackupServiceClient.date(readOnlyUntil),
                                      deleteAfter: BackupServiceClient.date(deleteAfter))
    }
}

nonisolated private struct SessionBody: Decodable {
    struct Credentials: Decodable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String
        let expiresAt: String
    }
    struct Storage: Decodable {
        let endpoint: String
        let host: String
        let region: String
        let bucket: String
        let prefix: String
    }
    struct Usage: Decodable {
        let bytes: Int64
        let allowanceBytes: Int64
        let overAllowance: Bool
        let countedAt: String?
    }

    let mode: String
    let credentials: Credentials
    let storage: Storage
    let subscription: SubscriptionBody
    let usage: Usage

    func value() throws -> BackupServiceSession {
        guard let mode = BackupServiceAccessMode(rawValue: mode) else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "unknown mode")
        }
        guard let expiry = BackupServiceClient.date(credentials.expiresAt) else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "credentials expiry")
        }
        guard let endpoint = URL(string: storage.endpoint), endpoint.scheme != nil else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "storage endpoint")
        }
        let value = BackupServiceStorage(endpoint: endpoint, host: storage.host, region: storage.region,
                                         bucket: storage.bucket, prefix: storage.prefix)
        guard value.s3Endpoint != nil else { throw CloudServiceError.unexpectedResponse(status: 200, code: "storage") }
        return BackupServiceSession(
            mode: mode,
            credentials: S3Credentials(accessKeyID: credentials.accessKeyId, secretAccessKey: credentials.secretAccessKey,
                                       sessionToken: credentials.sessionToken, expiration: expiry),
            storage: value,
            subscription: try subscription.value(),
            usage: BackupServiceUsage(bytes: usage.bytes, allowanceBytes: usage.allowanceBytes,
                                      overAllowance: usage.overAllowance, countedAt: BackupServiceClient.date(usage.countedAt)))
    }
}
