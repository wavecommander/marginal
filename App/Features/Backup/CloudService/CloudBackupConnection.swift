import Foundation
import ReaderBackup
import S3Kit

/// Temporary R2 credentials from the backup service: an `S3RefreshingCredentialsProvider` whose
/// fetch asks the service for a session.
///
/// - One session request at a time: callers that ask while one is under way wait for it.
/// - Credentials are reused until `refreshMargin` before they expire, or until R2 rejects them
///   (S3Kit then asks again and retries once).
/// - Whatever the fetch throws (the service's refusals, `notSubscribed`, no network) reaches
///   the caller unchanged; `S3BackupBlobStore` passes it through to whoever used the store.
nonisolated struct BackupServiceCredentialsProvider: S3CredentialsProvider, CustomStringConvertible, CustomReflectable {
    /// Two minutes: a multipart part started just before the refresh still finishes in time.
    static let defaultRefreshMargin: Duration = .seconds(120)

    private let base: S3RefreshingCredentialsProvider

    /// - Parameter fetchSession: asks the service for a session (and reports it to the account).
    init(refreshMargin: Duration = defaultRefreshMargin, now: @escaping @Sendable () -> Date = { Date() },
         fetchSession: @escaping @Sendable () async throws -> BackupServiceSession) {
        base = S3RefreshingCredentialsProvider(refreshMargin: refreshMargin, now: now) {
            try await fetchSession().credentials
        }
    }

    func credentials() async throws -> S3Credentials {
        try await base.credentials()
    }

    func credentialsRejected(_ credentials: S3Credentials) async {
        await base.credentialsRejected(credentials)
    }

    /// Session requests started so far (for tests and diagnostics).
    var fetches: Int {
        get async { await base.fetches }
    }

    var description: String { "BackupServiceCredentialsProvider(refreshMargin: \(base.refreshMargin))" }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Why this device cannot use the backups in its folder until the reader enters the recovery key.
nonisolated enum CloudBackupKeyNeed: Hashable, Sendable {
    /// Backups exist but this device has no key (it may not have arrived through iCloud
    /// Keychain yet).
    case noKeyOnThisDevice
    /// The key on this device is not the one the backups were made with.
    case differentKey
}

/// What `CloudBackupConnection` tells the account as it happens.
nonisolated enum CloudBackupConnectionEvent: Sendable {
    /// The service answered a session request.
    case session(BackupServiceSession)
    /// A session request failed (the service's refusal, no subscription, no network).
    case sessionFailed(any Error)
    /// A new backup key was made for an empty folder (the first backup).
    case keyCreated
}

/// The working parts behind the Tactile Texts Cloud destination, shared by the account and the
/// destination: the service client, the credentials provider, the key store, and the encrypted
/// destination over the session's storage (built lazily after the first session and rebuilt
/// when the storage or the key changes).
///
/// **Keys.** A new key is made only for a first upload into a folder that holds nothing: no key
/// check object and nothing in `Backups/` or `PDFs/`. Where backups exist and this device has no
/// key (a new iPad whose key has not arrived through iCloud Keychain yet), every call that needs
/// the key throws `TactileCloudError.needsRecoveryKey(.noKeyOnThisDevice)`; nothing is created.
nonisolated final class CloudBackupConnection: @unchecked Sendable {
    /// The reader's subscription, signed (`nil`: never subscribed; the service is not asked).
    typealias Identity = @Sendable () async -> BackupSignedTransaction?
    typealias Observer = @Sendable (CloudBackupConnectionEvent) async -> Void

    let client: BackupServiceClient
    let keyStore: any BackupKeyStore
    let destinationID: String
    let displayName: String
    /// Temporary credentials from the service; every S3 request of the destination uses them.
    let credentials: BackupServiceCredentialsProvider

    private let identity: Identity
    private let s3Session: URLSession
    private let retryPolicy: S3RetryPolicy
    private let partSize: Int64
    private let temporaryDirectory: URL
    private let availableCapacity: EncryptedBackupDestination.AvailableCapacity
    private let lock = NSLock()
    private var observer: Observer?
    private var lastSession: BackupServiceSession?
    private var cached: (storage: BackupServiceStorage, key: BackupEncryptionKey, destination: EncryptedBackupDestination)?

    /// - Parameters:
    ///   - client: the backup service.
    ///   - keyStore: where the backup key is kept (the Keychain in the app).
    ///   - identity: the signed subscription to send.
    ///   - s3Session, retryPolicy, partSize: as for `S3BackupBlobStore`.
    ///   - temporaryDirectory, availableCapacity: as for `EncryptedBackupDestination`.
    ///   - now: the clock credentials expiry is judged by.
    init(client: BackupServiceClient, keyStore: any BackupKeyStore, identity: @escaping Identity,
         destinationID: String, displayName: String, s3Session: URLSession = .shared,
         retryPolicy: S3RetryPolicy = .standard, partSize: Int64 = S3Client.defaultPartSize,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TactileCloud", isDirectory: true),
         availableCapacity: @escaping EncryptedBackupDestination.AvailableCapacity = EncryptedBackupDestination.volumeAvailableCapacity,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.keyStore = keyStore
        self.identity = identity
        self.destinationID = destinationID
        self.displayName = displayName
        self.s3Session = s3Session
        self.retryPolicy = retryPolicy
        self.partSize = partSize
        self.temporaryDirectory = temporaryDirectory
        self.availableCapacity = availableCapacity
        let target = CloudBackupWeakConnection()
        credentials = BackupServiceCredentialsProvider(now: now) {
            guard let connection = target.value else { throw CancellationError() }
            return try await connection.fetchSession()
        }
        target.value = self
    }

    /// Who hears about sessions, failures and new keys (the account).
    func setObserver(_ observer: Observer?) {
        lock.withLock { self.observer = observer }
    }

    /// The last session the service gave (its credentials may have expired since).
    var latestSession: BackupServiceSession? { lock.withLock { lastSession } }

    // MARK: Sessions

    /// Asks the service for a session now. Used by the credentials provider (which makes sure
    /// only one runs at a time); call `currentSession` instead.
    func fetchSession() async throws -> BackupServiceSession {
        do {
            guard let signed = await identity() else { throw CloudServiceError.notSubscribed }
            let session = try await client.session(signedTransaction: signed.jws, signedRenewalInfo: signed.signedRenewalInfo)
            lock.withLock { lastSession = session }
            await notify(.session(session))
            return session
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await notify(.sessionFailed(error))
            throw error
        }
    }

    /// A session whose credentials are current: the cached one while it is fresh, otherwise a
    /// new one from the service. `forceNew` asks the service whatever is cached (a refresh the
    /// reader asked for, after resubscribing for example).
    func currentSession(forceNew: Bool = false) async throws -> BackupServiceSession {
        if forceNew, let last = latestSession { await credentials.credentialsRejected(last.credentials) }
        _ = try await credentials.credentials()
        guard let session = latestSession else { throw CloudServiceError.unexpectedResponse(status: 0, code: "no session") }
        return session
    }

    /// One `/v1/delete-my-data` batch for the reader's subscription.
    func deleteMyData() async throws -> BackupServiceDeletion {
        guard let signed = await identity() else { throw CloudServiceError.notSubscribed }
        return try await client.deleteMyData(signedTransaction: signed.jws, signedRenewalInfo: signed.signedRenewalInfo)
    }

    // MARK: Storage

    /// The session's folder as a blob store, using the service's credentials.
    func blobStore(for storage: BackupServiceStorage) throws -> S3BackupBlobStore {
        guard let endpoint = storage.s3Endpoint else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "storage endpoint")
        }
        return S3BackupBlobStore(endpoint: endpoint, credentialsProvider: credentials, displayName: displayName,
                                 session: s3Session, retryPolicy: retryPolicy, partSize: partSize)
    }

    /// The encrypted destination for `session`'s storage and this device's key.
    ///
    /// With no key stored: a folder that holds anything throws `needsRecoveryKey`. An empty
    /// folder gets a new key when `forWriting` (reported as `keyCreated`); for reading, a key
    /// that is never stored stands in, so listing shows nothing and nothing is written.
    func encryptedDestination(for session: BackupServiceSession, forWriting: Bool) async throws -> EncryptedBackupDestination {
        if let key = try await keyStore.load() { return try destination(storage: session.storage, key: key) }
        let store = try blobStore(for: session.storage)
        guard try await Self.holdsNothing(store) else { throw TactileCloudError.needsRecoveryKey(.noKeyOnThisDevice) }
        guard forWriting else { return try makeDestination(storage: session.storage, key: .generate()) }
        let key: BackupEncryptionKey
        do {
            key = try await keyStore.createKey()
            await notify(.keyCreated)
        } catch BackupKeyStoreError.keyAlreadyExists {
            // Another task (or iCloud Keychain) stored one meanwhile: use it.
            guard let stored = try await keyStore.load() else { throw BackupKeyStoreError.noKey }
            key = stored
        }
        return try destination(storage: session.storage, key: key)
    }

    /// Whether the folder is ready for this device's key, needs the recovery key, or has no key
    /// yet (and nothing stored, so the first backup will make one).
    enum KeyState: Hashable, Sendable {
        case ready
        case noKeyYet
        case needsRecoveryKey(CloudBackupKeyNeed)
    }

    /// Reads the key check (or the folder) to say whether this device's key fits.
    func keyState(for session: BackupServiceSession) async throws -> KeyState {
        guard let key = try await keyStore.load() else {
            return try await Self.holdsNothing(try blobStore(for: session.storage)) ? .noKeyYet : .needsRecoveryKey(.noKeyOnThisDevice)
        }
        switch try await destination(storage: session.storage, key: key).checkKey() {
        case .matches, .nothingStored: return .ready
        case .differentKey: return .needsRecoveryKey(.differentKey)
        }
    }

    /// What the folder's key check says about `key` (not stored, not cached).
    func check(_ key: BackupEncryptionKey, storage: BackupServiceStorage) async throws -> BackupKeyCheckResult {
        try await makeDestination(storage: storage, key: key).checkKey()
    }

    /// Forgets the built destination (after the key changed or was removed).
    func invalidateDestinations() {
        lock.withLock { cached = nil }
    }

    /// `true` when the folder holds no key check object and nothing in `Backups/` or `PDFs/`.
    static func holdsNothing(_ store: any BackupBlobStore) async throws -> Bool {
        if try await store.size(of: .control(EncryptedBackupDestination.keyCheckObjectName)) != nil { return false }
        if !(try await store.list(.backups)).isEmpty { return false }
        return try await store.list(.pdfs).isEmpty
    }

    // MARK: Internals

    /// The cached destination when storage and key are unchanged, otherwise a new one (cached).
    private func destination(storage: BackupServiceStorage, key: BackupEncryptionKey) throws -> EncryptedBackupDestination {
        if let cached = lock.withLock({ cached }), cached.storage == storage, cached.key == key { return cached.destination }
        let made = try makeDestination(storage: storage, key: key)
        lock.withLock { cached = (storage, key, made) }
        return made
    }

    private func makeDestination(storage: BackupServiceStorage, key: BackupEncryptionKey) throws -> EncryptedBackupDestination {
        EncryptedBackupDestination(id: destinationID, displayName: displayName, store: try blobStore(for: storage), key: key,
                                   temporaryDirectory: temporaryDirectory, availableCapacity: availableCapacity)
    }

    private func notify(_ event: CloudBackupConnectionEvent) async {
        let observer = lock.withLock { self.observer }
        await observer?(event)
    }
}

/// A weak reference to the connection for its credentials provider's fetch (no retain cycle).
nonisolated private final class CloudBackupWeakConnection: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: CloudBackupConnection?
    var value: CloudBackupConnection? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
