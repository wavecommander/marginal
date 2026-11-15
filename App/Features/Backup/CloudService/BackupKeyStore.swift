import Foundation
import ReaderBackup
import Security

/// Holds the one `BackupEncryptionKey` that encrypts the reader's cloud backups.
///
/// Conforming types never log or describe key material: errors carry only Keychain status codes,
/// and the key and recovery key types print `redacted`.
nonisolated protocol BackupKeyStore: Sendable {
    /// The stored key, or `nil` when there is none.
    func load() async throws -> BackupEncryptionKey?

    /// Makes and stores a new random key. Throws `BackupKeyStoreError.keyAlreadyExists` when a
    /// key is already stored (it is never overwritten this way).
    func createKey() async throws -> BackupEncryptionKey

    /// Stores the key a recovery key stands for, **replacing** any stored key (this is how a
    /// device that has the wrong key, or none, takes up the key its backups were made with).
    /// Throws `BackupError.recoveryKeyWrongLength`, `.recoveryKeyInvalidCharacter(position:)`
    /// or `.recoveryKeyTypo` as `BackupRecoveryKey` reports them, storing nothing.
    func adoptKey(recoveryKey text: String) async throws -> BackupEncryptionKey

    /// The recovery key for the stored key. Throws `BackupKeyStoreError.noKey` when none.
    func recoveryKey() async throws -> BackupRecoveryKey

    /// Removes the stored key. Removing nothing succeeds.
    func removeKey() async throws
}

/// Failures of a `BackupKeyStore` (the recovery key errors are `BackupError`'s own).
nonisolated enum BackupKeyStoreError: LocalizedError, Hashable, Sendable {
    /// `createKey()` found a key already stored.
    case keyAlreadyExists
    /// There is no stored key.
    case noKey
    /// The stored item is not a key (wrong length). It is left in place, not deleted.
    case storedKeyUnreadable
    /// A Keychain call failed with this `OSStatus` (for diagnostics; never key material).
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyAlreadyExists:
            "This iPad already has a backup encryption key."
        case .noKey:
            "This iPad doesn’t have the key for your cloud backups. Enter your recovery key to use them."
        case .storedKeyUnreadable:
            "The backup encryption key saved on this iPad can’t be read. Enter your recovery key to use your cloud backups."
        case .keychain(let status):
            "Tactile Texts couldn’t use the Keychain to keep your backup encryption key (error \(status))."
        }
    }
}

// MARK: - Keychain

/// The backup key as one Keychain generic-password item that **synchronises through iCloud
/// Keychain**, so the reader's other iPads (and a replacement iPad) get it without typing the
/// recovery key.
///
/// - `kSecAttrSynchronizable` true. Apple's documentation for that key: a query that does not
///   name it (or names it false) neither adds nor returns synchronisable items, so every query
///   here names it; and updating or deleting a synchronisable item affects every copy, so
///   `removeKey()` removes the key from all the reader's devices.
/// - `kSecAttrAccessibleAfterFirstUnlock`: readable after the first unlock since the device
///   started, so an automatic backup in a background task can use it while the iPad is locked.
///   The `ThisDeviceOnly` classes are not allowed with synchronisation (same documentation), and
///   this is the background-capable class that is.
/// - The value is the key's 32 raw bytes.
///
/// iCloud Keychain may be off; the item is then kept on this device only until it is turned on.
/// Without the app's `application-identifier` entitlement (the unsigned simulator test host)
/// every call fails with `errSecMissingEntitlement` (-34018).
nonisolated struct KeychainBackupKeyStore: BackupKeyStore, CustomStringConvertible {
    /// The item's service attribute in the app.
    static let defaultService = "software.tactile.marginal.cloud-backup"
    static let account = "backup-encryption-key"
    /// The accessibility class of the item.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    let service: String

    /// - Parameter service: the item's `kSecAttrService`; tests pass their own so they never touch
    ///   the app's item.
    init(service: String = KeychainBackupKeyStore.defaultService) {
        self.service = service
    }

    var description: String { "KeychainBackupKeyStore(service: \(service))" }

    @concurrent
    func load() async throws -> BackupEncryptionKey? {
        try readKey()
    }

    @concurrent
    func createKey() async throws -> BackupEncryptionKey {
        if try readKey() != nil { throw BackupKeyStoreError.keyAlreadyExists }
        let key = BackupEncryptionKey.generate()
        var item = baseQuery
        item[kSecValueData as String] = Self.data(of: key)
        item[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw BackupKeyStoreError.keyAlreadyExists }
        guard status == errSecSuccess else { throw BackupKeyStoreError.keychain(status: status) }
        return key
    }

    @concurrent
    func adoptKey(recoveryKey text: String) async throws -> BackupEncryptionKey {
        let key = try BackupEncryptionKey(recoveryKey: text)
        let attributes: [String: Any] = [
            kSecValueData as String: Self.data(of: key),
            kSecAttrAccessible as String: Self.accessibility,
        ]
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return key }
        guard update == errSecItemNotFound else { throw BackupKeyStoreError.keychain(status: update) }
        let add = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else { throw BackupKeyStoreError.keychain(status: add) }
        return key
    }

    @concurrent
    func recoveryKey() async throws -> BackupRecoveryKey {
        guard let key = try readKey() else { throw BackupKeyStoreError.noKey }
        return key.recoveryKey
    }

    @concurrent
    func removeKey() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackupKeyStoreError.keychain(status: status)
        }
    }

    // MARK: Internals

    private func readKey() throws -> BackupEncryptionKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BackupKeyStoreError.keychain(status: status) }
        do {
            return try BackupEncryptionKey(rawBytes: data)
        } catch {
            throw BackupKeyStoreError.storedKeyUnreadable
        }
    }

    private static func data(of key: BackupEncryptionKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// Identifies the one item: class, service, account, synchronisable.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }
}

// MARK: - In memory

/// A `BackupKeyStore` in memory, for tests and previews. Each instance holds its own key.
nonisolated final class InMemoryBackupKeyStore: BackupKeyStore, CustomStringConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var key: BackupEncryptionKey?

    init(key: BackupEncryptionKey? = nil) {
        self.key = key
    }

    var description: String { "InMemoryBackupKeyStore(\(lock.withLock { key == nil } ? "empty" : "holding a key"))" }

    func load() async throws -> BackupEncryptionKey? { lock.withLock { key } }

    func createKey() async throws -> BackupEncryptionKey {
        try lock.withLock {
            guard key == nil else { throw BackupKeyStoreError.keyAlreadyExists }
            let new = BackupEncryptionKey.generate()
            key = new
            return new
        }
    }

    func adoptKey(recoveryKey text: String) async throws -> BackupEncryptionKey {
        let adopted = try BackupEncryptionKey(recoveryKey: text)
        lock.withLock { key = adopted }
        return adopted
    }

    func recoveryKey() async throws -> BackupRecoveryKey {
        guard let key = lock.withLock({ key }) else { throw BackupKeyStoreError.noKey }
        return key.recoveryKey
    }

    func removeKey() async throws { lock.withLock { key = nil } }
}
