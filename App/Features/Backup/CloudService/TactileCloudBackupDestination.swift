import AuthenticationServices
import Foundation
import GoogleSignInKit
import ReaderBackup
import S3Kit
import UIKit

/// Tactile Texts Cloud: the paid backup service, as a backup destination. Backups are encrypted
/// on the iPad (`EncryptedBackupDestination`) and kept in the owner's R2 bucket under the
/// reader's folder (`S3BackupBlobStore`), reached with temporary credentials from the backup
/// service. The S3 endpoint comes from the session, so the encrypted destination is built after
/// the first session and rebuilt when the storage or the key changes (`CloudBackupConnection`).
///
/// - `availability()` reads `CloudBackupAccount`'s state, asking the service only when nothing
///   is known yet, the App Store's view changed or the sign-in changed: automatic backups skip
///   quietly when the reader is signed out or not subscribed. Read-only and over-allowance are available (restores, deletes).
/// - In read-only or over-allowance mode an upload is refused before anything is sent
///   (`TactileCloudError.readOnly`, `.overAllowance`); a delete is refused in read-only mode.
///   Restores work in every mode that has access.
/// - Errors: as `EncryptedBackupDestination` and `S3BackupBlobStore`, plus the service's
///   (`CloudServiceError`, unchanged) and `TactileCloudError`.
nonisolated struct TactileCloudBackupDestination: BackupDestination {
    static let destinationID = "tactile-cloud"
    static let name = "Tactile Texts Cloud"

    let id = TactileCloudBackupDestination.destinationID
    let displayName = TactileCloudBackupDestination.name
    let account: CloudBackupAccount
    let connection: CloudBackupConnection

    @concurrent
    func availability() async -> BackupDestinationAvailability {
        await account.availability()
    }

    @concurrent
    func listSnapshots() async throws -> [BackupSnapshotInfo] {
        try await prepared(.read).listSnapshots()
    }

    @discardableResult @concurrent
    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        try await prepared(.upload).uploadSnapshot(from: file, name: name, progress: progress)
    }

    @concurrent
    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        try await prepared(.read).downloadSnapshot(snapshot, to: file, progress: progress)
    }

    @concurrent
    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        try await prepared(.delete).deleteSnapshot(snapshot)
    }

    @concurrent
    func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        try await prepared(.read).hasPDF(sha256: sha256, size: size)
    }

    @concurrent
    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        try await prepared(.upload).uploadPDF(from: file, sha256: sha256, size: size, progress: progress)
    }

    @concurrent
    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        try await prepared(.read).downloadPDF(sha256: sha256, to: file, progress: progress)
    }

    // MARK: - Internals

    private enum Intent { case read, upload, delete }

    /// A current session (from the cache while fresh), the mode checked for `intent`, and the
    /// encrypted destination over its storage.
    private func prepared(_ intent: Intent) async throws -> EncryptedBackupDestination {
        let session = try await connection.currentSession()
        switch intent {
        case .upload where !session.mode.allowsUpload:
            throw TactileCloudError.uploadRefused(session)
        case .delete where !session.mode.allowsDelete:
            throw TactileCloudError.uploadRefused(session)
        default:
            break
        }
        return try await connection.encryptedDestination(for: session, forWriting: intent == .upload)
    }
}

/// The parts of Tactile Texts Cloud the app creates when the build is configured for it: the
/// subscription, the sign-in, the account and the destination.
@MainActor
struct TactileCloudBackup {
    let configuration: BackupServiceConfiguration
    let subscription: BackupSubscription
    let signIn: CloudBackupSignIn
    let account: CloudBackupAccount
    let destination: TactileCloudBackupDestination

    /// The service for this build, or `nil` when `BackupServiceConfiguration` finds no host or
    /// product IDs (the default): then nothing is created and nothing changes for the reader.
    /// With neither way of signing in configured the service is created but reports itself not
    /// available.
    static func make(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> TactileCloudBackup? {
        guard let configuration = BackupServiceConfiguration.fromInfoDictionary(infoDictionary) else { return nil }
        return make(configuration: configuration, store: AppStoreBackupStore(), attest: DeviceAppAttestClient(),
                    keyStore: KeychainBackupKeyStores(), sessionStore: KeychainCloudDeviceSessionStore(),
                    identity: identityProvider(for: configuration))
    }

    /// Apple and Google as this build is configured (in a debug build with
    /// `BACKUP_SERVICE_DEV_SIGNIN`, the `dev` Worker's test issuer stands in for both).
    static func identityProvider(for configuration: BackupServiceConfiguration) -> any CloudIdentityProviding {
        #if DEBUG
        if let secret = configuration.devSignInSecret {
            return DevTestCloudIdentityProvider(secret: secret, audience: Bundle.main.bundleIdentifier ?? "software.tactile.texts",
                                                subject: devTestSubject())
        }
        #endif
        return SystemCloudIdentityProvider(appleEnabled: configuration.signInWithApple,
                                           google: configuration.googleClientID.flatMap { GoogleSignInConfiguration(clientID: $0) })
    }

    #if DEBUG
    /// A test identity per install, so a simulator keeps its account across launches.
    private static func devTestSubject() -> String {
        let key = "software.tactile.texts.cloud-backup.dev-test-subject"
        if let subject = UserDefaults.standard.string(forKey: key) { return subject }
        let made = "simulator-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(made, forKey: key)
        return made
    }
    #endif

    /// The service with every dependency given (tests pass fakes and stubbed sessions).
    ///
    /// - Parameters:
    ///   - keyStore: each account's backup key (`InMemoryBackupKeyStore` stands for one key
    ///     shared by every account).
    ///   - sessionStore: this device's session (signed in when it holds one).
    ///   - identity: Apple's and Google's sign-in.
    static func make(configuration: BackupServiceConfiguration, store: any BackupStoreKit, attest: any AppAttestClient,
                     keyStore: any BackupKeyStoreFactory, sessionStore: any CloudDeviceSessionStore,
                     identity: any CloudIdentityProviding, urlSession: URLSession = .shared, s3Session: URLSession = .shared,
                     retryPolicy: S3RetryPolicy = .standard, partSize: Int64 = S3Client.defaultPartSize,
                     temporaryDirectory: URL? = nil, defaults: UserDefaults = .standard,
                     deviceName: @escaping () -> String = { UIDevice.current.name },
                     now: @escaping @Sendable () -> Date = { Date() }) -> TactileCloudBackup {
        let subscription = BackupSubscription(productIDs: configuration.productIDs, store: store, now: now)
        let client = BackupServiceClient(configuration: configuration, attest: attest, urlSession: urlSession)
        let signIn = CloudBackupSignIn(client: client, identity: identity, store: sessionStore, keyStores: keyStore,
                                       deviceName: deviceName)
        let accountKeyStore = AccountScopedBackupKeyStore(factory: keyStore) { [weak signIn] in
            await MainActor.run { signIn?.accountID }
        }
        let connection = CloudBackupConnection(
            client: client, keyStore: accountKeyStore,
            identity: { [weak subscription, weak signIn] in
                let token = await MainActor.run { signIn?.sessionToken }
                guard token != nil else { return CloudBackupIdentity() }
                return CloudBackupIdentity(sessionToken: token, transaction: await subscription?.signedTransaction())
            },
            destinationID: TactileCloudBackupDestination.destinationID, displayName: TactileCloudBackupDestination.name,
            s3Session: s3Session, retryPolicy: retryPolicy, partSize: partSize,
            temporaryDirectory: temporaryDirectory
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("TactileCloud", isDirectory: true),
            now: now)
        let account = CloudBackupAccount(subscription: subscription, connection: connection, signIn: signIn, defaults: defaults)
        signIn.onChange = { [weak account] in account?.signInChanged() }
        return TactileCloudBackup(configuration: configuration, subscription: subscription, signIn: signIn, account: account,
                                  destination: TactileCloudBackupDestination(account: account, connection: connection))
    }

    /// Loads the products and works out the subscription (its transaction listener runs from
    /// creation), and checks a Sign in with Apple authorization.
    func start() {
        let subscription = subscription
        signIn.start()
        Task { await subscription.load() }
    }

    /// Deletes the account (see `CloudBackupSignIn.deleteAccount`), then removes its backup key,
    /// which is of no use without the account.
    func deleteAccount(anchor: ASPresentationAnchor?, progress: ((Int) -> Void)? = nil) async throws {
        let keyStore = account.connection?.keyStore
        try await signIn.deleteAccount(anchor: anchor, progress: progress) { _ in
            try? await keyStore?.removeKey()
        }
    }
}
