import Foundation
import Security

/// What this device keeps about its sign-in to Tactile Texts Cloud: the device session the
/// service issued and what the account screen shows. Kept in the Keychain on this device only
/// (never synchronised): a session belongs to one device, and the email shown on the account
/// screen never leaves the device.
///
/// The session token and the Apple user ID never appear in a description, debug description or
/// mirror; neither does the email.
nonisolated struct CloudDeviceSession: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The account's random ID (32 hex digits). Names the backup key's Keychain item.
    var accountID: String
    /// This device's session in the account's device list.
    var sessionID: String
    /// The account's one sign-in.
    var provider: CloudSignInProvider
    /// The bearer token for every signed-in request. Shown once by the service.
    var deviceSessionToken: String
    /// The email in the ID token this device signed in with, for the account screen only. Never
    /// sent to the service.
    var email: String?
    /// Sign in with Apple's user identifier (from the credential), to ask Apple at launch whether
    /// the authorization still holds. `nil` for Google.
    var appleUserID: String?
    /// The account's StoreKit `appAccountToken`, passed on every purchase.
    var appAccountToken: UUID?

    var description: String {
        "CloudDeviceSession(account: \(accountID.prefix(8))…, provider: \(provider.rawValue), token: <redacted>)"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["accountID": String(accountID.prefix(8)) + "…", "provider": provider], displayStyle: .struct)
    }
}

/// Holds this device's `CloudDeviceSession`.
nonisolated protocol CloudDeviceSessionStore: Sendable {
    /// The stored session, or `nil` when signed out.
    func load() throws -> CloudDeviceSession?
    /// Stores `session`, replacing any other.
    func save(_ session: CloudDeviceSession) throws
    /// Forgets the session. Removing nothing succeeds.
    func remove() throws
}

/// The session as one Keychain generic-password item, **this device only**: not synchronised
/// (`kSecAttrSynchronizable` false) and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it
/// is never in a backup restored to another device and an automatic backup in a background task
/// can still use it while the device is locked. The value is the session as JSON.
nonisolated struct KeychainCloudDeviceSessionStore: CloudDeviceSessionStore, CustomStringConvertible {
    static let defaultService = "software.tactile.texts.cloud-account"
    static let account = "device-session"

    let service: String

    /// - Parameter service: the item's `kSecAttrService`; tests pass their own.
    init(service: String = KeychainCloudDeviceSessionStore.defaultService) {
        self.service = service
    }

    var description: String { "KeychainCloudDeviceSessionStore(service: \(service))" }

    func load() throws -> CloudDeviceSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BackupKeyStoreError.keychain(status: status) }
        // An item this version cannot read is treated as signed out (the reader signs in again).
        return try? JSONDecoder().decode(CloudDeviceSession.self, from: data)
    }

    func save(_ session: CloudDeviceSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw BackupKeyStoreError.keychain(status: update) }
        let add = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else { throw BackupKeyStoreError.keychain(status: add) }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackupKeyStoreError.keychain(status: status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

/// A `CloudDeviceSessionStore` in memory, for tests, previews and the UI test fakes.
nonisolated final class InMemoryCloudDeviceSessionStore: CloudDeviceSessionStore, CustomStringConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CloudDeviceSession?

    init(_ session: CloudDeviceSession? = nil) {
        stored = session
    }

    var description: String { "InMemoryCloudDeviceSessionStore(\(lock.withLock { stored == nil } ? "signed out" : "signed in"))" }

    func load() throws -> CloudDeviceSession? { lock.withLock { stored } }
    func save(_ session: CloudDeviceSession) throws { lock.withLock { stored = session } }
    func remove() throws { lock.withLock { stored = nil } }
}
