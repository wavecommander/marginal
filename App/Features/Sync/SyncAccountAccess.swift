import Foundation
import ReaderBackup
import ReaderSync
import S3Kit

/// What a sync round may use: the account, its storage, the key and how it may write.
nonisolated struct SyncAccountAccess: Sendable {
    /// The signed-in account (names the engine's directory).
    var accountID: String
    /// The account's folder, holding only ciphertext.
    var store: any SyncObjectStore
    var key: BackupEncryptionKey
    /// `.pullOnly` when the session is read-only or over the allowance.
    var mode: SyncMode
    /// The account folder's backup objects (snapshots, `PDFs/`, the key check), for
    /// housekeeping's PDF rule: no PDF a kept snapshot refers to is removed. `nil`: no PDF is.
    var backupStore: (any BackupBlobStore)? = nil
}

/// Where sync stands with the account before a round.
nonisolated enum SyncAccessOutcome: Sendable {
    case ready(SyncAccountAccess)
    /// Nobody is signed in.
    case signedOut
    /// The account holds data and this device has no key, or another key: the reader enters the
    /// recovery key (the Tactile Texts Cloud page). Never a round.
    case needsKey(accountID: String, CloudBackupKeyNeed)
    /// No key yet and the account is empty, and this round may not write (pull-only): there is
    /// nothing to sync.
    case nothingToSync(accountID: String)
}

/// The account side of sync: who is signed in, and everything a round needs, after the key check.
nonisolated protocol SyncAccountProvider: Sendable {
    /// The signed-in account, without asking the service.
    func currentAccountID() async -> String?
    /// A session, the key check and the storage for one round.
    func prepareRound() async throws -> SyncAccessOutcome
}

/// The key check before any round (`EncryptedBackupDestination.checkKey` semantics, as backups):
/// - no key here and the account holds data: `needsKey(.noKeyOnThisDevice)` (the key may still
///   be on its way through iCloud Keychain; a new one is never made while data exists);
/// - no key and nothing held: a key is made only when the round may write (`createKey`, which
///   tells the account so it offers the recovery key), else `nothingToSync`;
/// - a key that is not the account's: `needsKey(.differentKey)`;
/// - before a round that may write, the key check object is written if absent
///   (`prepareForWriting`), so another device with another key is told so rather than finding
///   everything damaged.
nonisolated enum SyncKeyGate {
    static func evaluate(accountID: String, mode: SyncMode, keyStore: any BackupKeyStore, blobStore: any BackupBlobStore,
                         temporaryDirectory: URL,
                         createKey: @Sendable () async throws -> BackupEncryptionKey) async throws -> SyncKeyGateResult {
        var key = try await keyStore.load()
        if key == nil {
            guard try await CloudBackupConnection.holdsNothing(blobStore) else { return .needsKey(.noKeyOnThisDevice) }
            guard mode == .full else { return .nothingToSync }
            do {
                key = try await createKey()
            } catch BackupKeyStoreError.keyAlreadyExists {
                key = try await keyStore.load()
            }
        }
        guard let key else { return .needsKey(.noKeyOnThisDevice) }
        let destination = EncryptedBackupDestination(id: "sync-key-check", displayName: "", store: blobStore, key: key,
                                                     temporaryDirectory: temporaryDirectory)
        if try await destination.checkKey() == .differentKey { return .needsKey(.differentKey) }
        if mode == .full {
            do {
                try await destination.prepareForWriting()
            } catch BackupError.wrongEncryptionKey {
                return .needsKey(.differentKey)
            }
        }
        return .ready(key)
    }
}

nonisolated enum SyncKeyGateResult: Sendable {
    case ready(BackupEncryptionKey)
    case needsKey(CloudBackupKeyNeed)
    case nothingToSync
}

// MARK: - Tactile Texts Cloud

/// The account side over Tactile Texts Cloud: the signed-in account, the session's temporary
/// credentials (refreshed before they expire), its storage and its mode, and the account's key.
nonisolated struct TactileCloudSyncAccess: SyncAccountProvider {
    let connection: CloudBackupConnection
    let accountID: @Sendable () async -> String?
    var s3Session: URLSession = .shared
    var retryPolicy: S3RetryPolicy = .standard
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TactileSync", isDirectory: true)

    func currentAccountID() async -> String? { await accountID() }

    func prepareRound() async throws -> SyncAccessOutcome {
        guard let account = await accountID() else { return .signedOut }
        let session: BackupServiceSession
        do {
            session = try await connection.currentSession()
        } catch CloudServiceError.notSignedIn {
            return .signedOut
        }
        guard let endpoint = session.storage.s3Endpoint else {
            throw CloudServiceError.unexpectedResponse(status: 200, code: "storage endpoint")
        }
        let mode: SyncMode = session.mode.allowsUpload ? .full : .pullOnly
        let blobStore = try connection.blobStore(for: session.storage)
        let connection = connection
        let result = try await SyncKeyGate.evaluate(
            accountID: account, mode: mode, keyStore: connection.keyStore, blobStore: blobStore,
            temporaryDirectory: temporaryDirectory,
            createKey: {
                // Through the connection, which tells the account a key was made (the recovery
                // key is then offered), as the first backup does.
                _ = try await connection.encryptedDestination(for: session, forWriting: true)
                guard let key = try await connection.keyStore.load() else { throw BackupKeyStoreError.noKey }
                return key
            })
        switch result {
        case .needsKey(let need): return .needsKey(accountID: account, need)
        case .nothingToSync: return .nothingToSync(accountID: account)
        case .ready(let key):
            let client = S3Client(endpoint: endpoint, credentialsProvider: connection.credentials, session: s3Session,
                                  retryPolicy: retryPolicy)
            return .ready(SyncAccountAccess(accountID: account, store: SyncS3ObjectStore(client: client), key: key, mode: mode,
                                            backupStore: blobStore))
        }
    }
}

// MARK: - A local stand-in (tests, `-syncTestFolder`)

/// The account side with no service: a store standing in for the account's folder (a folder or
/// memory), a key store and a mode, signed in as `accountID` (or signed out when `nil`).
nonisolated final class LocalSyncAccess: SyncAccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _accountID: String?
    private var _mode: SyncMode
    let store: any SyncObjectStore
    /// Stands in for the account folder's backup objects (the key check lives there).
    let blobStore: any BackupBlobStore
    let keyStore: any BackupKeyStore
    let temporaryDirectory: URL

    init(accountID: String?, store: any SyncObjectStore, blobStore: any BackupBlobStore, keyStore: any BackupKeyStore,
         mode: SyncMode = .full, temporaryDirectory: URL) {
        _accountID = accountID
        _mode = mode
        self.store = store
        self.blobStore = blobStore
        self.keyStore = keyStore
        self.temporaryDirectory = temporaryDirectory
    }

    var accountID: String? {
        get { lock.withLock { _accountID } }
        set { lock.withLock { _accountID = newValue } }
    }

    var mode: SyncMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    func currentAccountID() async -> String? { accountID }

    func prepareRound() async throws -> SyncAccessOutcome {
        guard let account = accountID else { return .signedOut }
        let mode = mode
        let keyStore = keyStore
        switch try await SyncKeyGate.evaluate(accountID: account, mode: mode, keyStore: keyStore, blobStore: blobStore,
                                              temporaryDirectory: temporaryDirectory,
                                              createKey: { try await keyStore.createKey() }) {
        case .needsKey(let need): return .needsKey(accountID: account, need)
        case .nothingToSync: return .nothingToSync(accountID: account)
        case .ready(let key):
            return .ready(SyncAccountAccess(accountID: account, store: store, key: key, mode: mode, backupStore: blobStore))
        }
    }
}
