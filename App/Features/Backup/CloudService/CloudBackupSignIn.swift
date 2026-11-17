import AuthenticationServices
import Foundation
import Observation
import ReaderBackup
import ReaderSync
import UIKit

/// Signing in to Tactile Texts Cloud: this device's session with the service, the account screen's
/// information, and every change of sign-in (sign in, change to the other provider, sign out here
/// or everywhere, delete the account, a session that has ended).
///
/// **None of it touches the library** (owner decision 7, 17 November 2026). The books, notes and
/// ink on the iPad are ordinary local data; signing out, a session that ended, a revoked Apple
/// authorization or a deleted account only stop the service (automatic cloud backup stops and
/// the page says the books are no longer backed up).
///
/// One instance per app (`AppEnvironment.cloudBackup`), observed by every window, so every window
/// shows the same account state.
@MainActor @Observable
final class CloudBackupSignIn {
    /// Why the device became signed out without the reader asking here, for the page to say.
    enum SignedOutReason: Hashable, Sendable {
        /// The service ended the session (signed out on another device, everywhere, or by Apple).
        case sessionEnded
        /// Apple says this app's Sign in with Apple authorization was revoked.
        case appleRevoked
        /// The account was deleted here.
        case accountDeleted
    }

    /// What is under way, for every window's buttons.
    enum Activity: Hashable, Sendable {
        case signingIn(CloudSignInProvider)
        case changing(to: CloudSignInProvider)
        case signingOut(everywhere: Bool)
        case deletingAccount
    }

    /// This device's session; `nil` when signed out.
    private(set) var session: CloudDeviceSession?
    /// The account as the service last described it (devices, subscription); `nil` until asked.
    private(set) var accountInfo: BackupServiceAccountInfo?
    /// The devices' names opened with the account's backup key, by session ID. A device whose
    /// label can't be opened (no key here yet, or none sent) is missing.
    private(set) var deviceNames: [String: String] = [:]
    /// The last failure to fetch the account screen (cleared by the next success).
    private(set) var accountError: (any Error)?
    private(set) var activity: Activity?
    private(set) var signedOutReason: SignedOutReason?
    /// Moves on at every sign-in and sign-out, so the account knows its state is stale.
    private(set) var generation = 0

    @ObservationIgnored let client: BackupServiceClient
    @ObservationIgnored let identity: any CloudIdentityProviding
    @ObservationIgnored private let store: any CloudDeviceSessionStore
    @ObservationIgnored private let keyStores: any BackupKeyStoreFactory
    @ObservationIgnored private let deviceName: () -> String
    /// Called after every sign-in and sign-out, synchronously (the account resets its state).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var deletionStarted = false
    @ObservationIgnored private var revocationObserver: (any NSObjectProtocol)?

    /// Delete Account gives up after this many unfinished batches.
    static let maxDeletionRounds = 200

    init(client: BackupServiceClient, identity: any CloudIdentityProviding, store: any CloudDeviceSessionStore,
         keyStores: any BackupKeyStoreFactory, deviceName: @escaping () -> String = { UIDevice.current.name }) {
        self.client = client
        self.identity = identity
        self.store = store
        self.keyStores = keyStores
        self.deviceName = deviceName
        session = try? store.load()
    }

    /// The ways of signing in this build offers. Empty: the service is not available.
    var availableProviders: [CloudSignInProvider] { identity.availableProviders }
    var isAvailable: Bool { !availableProviders.isEmpty }
    var isSignedIn: Bool { session != nil }
    var accountID: String? { session?.accountID }
    var sessionToken: String? { session?.deviceSessionToken }
    /// The account's StoreKit token, passed on every purchase.
    var appAccountToken: UUID? { session?.appAccountToken ?? accountInfo?.appAccountToken }

    /// What the account screen calls a device: its name when its label opens with this account's
    /// key, otherwise "This iPad" or "Another device".
    func name(of device: BackupServiceDevice) -> String {
        if let name = deviceNames[device.sessionID], !name.isEmpty { return name }
        return device.isCurrent ? "This iPad" : "Another device"
    }

    // MARK: Launch

    /// At launch: asks Apple whether a Sign in with Apple authorization still holds (signing out
    /// here if not), and listens for Apple's revocation while the app runs.
    func start() {
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkAppleAuthorization() }
        }
        Task { await checkAppleAuthorization() }
    }

    /// Signs out here when the session is Apple's and Apple says the authorization ended.
    func checkAppleAuthorization() async {
        guard let session, session.provider == .apple, let user = session.appleUserID else { return }
        guard await identity.appleAuthorizationEnded(userID: user), self.session == session else { return }
        let token = session.deviceSessionToken
        endLocally(.appleRevoked)
        // Tell the service too; the session is gone here either way.
        _ = try? await client.signOut(sessionToken: token, everywhere: false)
    }

    // MARK: Signing in

    /// Signs in with `provider`: a challenge from the service, Apple's or Google's sign-in with
    /// its nonce, then the service's sign-in. Throws `CloudSignInError.cancelled` when the reader
    /// backed out, and the service's errors.
    func signIn(with provider: CloudSignInProvider, anchor: ASPresentationAnchor?) async throws {
        guard activity == nil else { return }
        activity = .signingIn(provider)
        defer { activity = nil }
        let challenge = try await client.challenge()
        let credential = try await identity.credential(provider, nonce: challenge.nonce, anchor: anchor)
        let result = try await client.signIn(provider: provider, challenge: challenge, idToken: credential.idToken,
                                             authorizationCode: credential.authorizationCode, deviceLabel: nil)
        let session = CloudDeviceSession(accountID: result.account.accountID, sessionID: result.sessionID, provider: provider,
                                         deviceSessionToken: result.deviceSessionToken, email: credential.email,
                                         appleUserID: credential.appleUserID, appAccountToken: result.account.appAccountToken)
        try store.save(session)
        self.session = session
        accountInfo = result.account
        accountError = nil
        signedOutReason = nil
        deletionStarted = false
        changed()
        await refreshAccount()
    }

    // MARK: The account screen

    /// Asks the service for the account screen (devices, the sign-in), sending this device's
    /// encrypted name the first time the account's key is here to make it. A session that has
    /// ended signs out here.
    func refreshAccount() async {
        guard let session else { return }
        do {
            // The key is made by the first backup; until then devices have no names.
            let key = try? await keyStores.keyStore(forAccount: session.accountID).load()
            var info = try await client.account(sessionToken: session.deviceSessionToken)
            guard self.session?.accountID == info.accountID else { return }
            if let key, let current = info.devices.first(where: \.isCurrent),
               current.label.flatMap({ SyncKeys(key: key).openDeviceLabel($0) }) == nil {
                info = try await client.account(sessionToken: session.deviceSessionToken,
                                                deviceLabel: SyncKeys(key: key).sealDeviceLabel(deviceName()))
            }
            apply(info)
            deviceNames = Self.open(info.devices, key: key)
            accountError = nil
        } catch CloudServiceError.sessionInvalid {
            endLocally(.sessionEnded)
        } catch is CancellationError {
        } catch {
            accountError = error
        }
    }

    /// Takes in what the service says about the account (another device may have changed the
    /// sign-in: the email this device knew no longer applies).
    private func apply(_ info: BackupServiceAccountInfo) {
        accountInfo = info
        guard var session, session.accountID == info.accountID else { return }
        var updated = false
        if session.provider != info.provider {
            session.provider = info.provider
            session.email = nil
            session.appleUserID = nil
            updated = true
        }
        if let token = info.appAccountToken, session.appAccountToken != token {
            session.appAccountToken = token
            updated = true
        }
        if updated {
            try? store.save(session)
            self.session = session
        }
    }

    private static func open(_ devices: [BackupServiceDevice], key: BackupEncryptionKey?) -> [String: String] {
        guard let key else { return [:] }
        let keys = SyncKeys(key: key)
        var names: [String: String] = [:]
        for device in devices {
            if let label = device.label, let name = keys.openDeviceLabel(label) { names[device.sessionID] = name }
        }
        return names
    }

    // MARK: Changing the sign-in

    /// Change to Sign in with the other provider: the reader confirms with the current sign-in,
    /// then signs in with the new one (both bound to one challenge), and the service swaps the
    /// account's identity in one step. Throws `CloudServiceError.identityInUse` when the new
    /// identity has an account of its own; nothing changes on any failure.
    func changeSignIn(anchor: ASPresentationAnchor?) async throws {
        guard let session, activity == nil else { return }
        let target = session.provider.other
        guard availableProviders.contains(target) else { throw CloudSignInError.unavailable(target) }
        activity = .changing(to: target)
        defer { activity = nil }
        let challenge = try await client.challenge()
        let current = try await identity.credential(session.provider, nonce: challenge.nonce, anchor: anchor)
        let next = try await identity.credential(target, nonce: challenge.nonce, anchor: anchor)
        do {
            let info = try await client.changeSignIn(sessionToken: session.deviceSessionToken, challenge: challenge,
                                                     currentIdToken: current.idToken,
                                                     currentAuthorizationCode: current.authorizationCode,
                                                     newProvider: target, newIdToken: next.idToken)
            var changed = session
            changed.provider = target
            changed.email = next.email
            changed.appleUserID = next.appleUserID
            try? store.save(changed)
            self.session = changed
            apply(info)
        } catch CloudServiceError.sessionInvalid {
            endLocally(.sessionEnded)
            throw CloudServiceError.sessionInvalid
        }
    }

    // MARK: Signing out

    /// Sign Out: ends this device's session. Always signs out here, even when the service can't
    /// be reached (its copy of the session is then left to Sign Out of All Devices).
    func signOut() async {
        guard let session, activity == nil else { return }
        activity = .signingOut(everywhere: false)
        defer { activity = nil }
        _ = try? await client.signOut(sessionToken: session.deviceSessionToken, everywhere: false)
        endLocally(nil)
    }

    /// Sign Out of All Devices: ends every session of the account, this one included. When the
    /// service can't be asked, nothing changes here and the error is thrown.
    func signOutEverywhere() async throws {
        guard let session, activity == nil else { return }
        activity = .signingOut(everywhere: true)
        defer { activity = nil }
        do {
            try await client.signOut(sessionToken: session.deviceSessionToken, everywhere: true)
        } catch CloudServiceError.sessionInvalid {
            // Already ended (another device did this first).
        }
        endLocally(nil)
    }

    /// Becomes signed out here without asking the service (it ended the session, or Apple ended
    /// the authorization). Nothing else on the iPad changes.
    func endLocally(_ reason: SignedOutReason?) {
        guard session != nil else { return }
        try? store.remove()
        session = nil
        accountInfo = nil
        deviceNames = [:]
        accountError = nil
        signedOutReason = reason
        deletionStarted = false
        changed()
    }

    // MARK: Deleting the account

    /// Delete Account: the reader signs in again with the account's sign-in, then the service
    /// empties the account's folders and removes it, one batch per call. When it is done this
    /// device is signed out and `removeKey` is called with the account's ID (its backup key is
    /// of no use any more). The subscription is not cancelled.
    ///
    /// - Parameter progress: objects deleted so far.
    func deleteAccount(anchor: ASPresentationAnchor?, progress: ((Int) -> Void)? = nil,
                       removeKey: (String) async -> Void) async throws {
        guard let session, activity == nil else { return }
        activity = .deletingAccount
        defer { activity = nil }
        var proof: BackupServiceClient.DeletionProof?
        if !deletionStarted {
            let challenge = try await client.challenge()
            let credential = try await identity.credential(session.provider, nonce: challenge.nonce, anchor: anchor)
            proof = .init(challenge: challenge, idToken: credential.idToken, authorizationCode: credential.authorizationCode)
        }
        var deleted = 0
        for _ in 0..<Self.maxDeletionRounds {
            try Task.checkCancellation()
            let step = try await client.deleteAccount(sessionToken: session.deviceSessionToken, proof: proof)
            proof = nil
            deletionStarted = true
            deleted += step.deletedObjects
            progress?(deleted)
            if step.done {
                await removeKey(session.accountID)
                endLocally(.accountDeleted)
                return
            }
        }
        throw TactileCloudError.deletionUnfinished
    }

    // MARK: Internals

    private func changed() {
        generation += 1
        onChange?()
    }
}
