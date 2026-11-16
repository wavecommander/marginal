import Foundation
import GoogleDriveKit
import Security

/// Keeps the reader's Google tokens in one Keychain generic-password item.
///
/// - Accessible after the first unlock since the device started
///   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so an automatic backup in a background
///   task can read it while the iPad is locked; Apple recommends this class for items background
///   work needs.
/// - This device only: the `ThisDeviceOnly` class never migrates to another device through a
///   backup or a device transfer, and the item is explicitly not synchronizable
///   (`kSecAttrSynchronizable` false), so it never goes to iCloud Keychain. A restored or new iPad
///   signs in again.
/// - The value is the JSON of `GoogleTokenSet`. Token values are never logged, and no error this
///   type throws contains them (only the Keychain's status code).
nonisolated final class GoogleDriveKeychainTokenStore: GoogleTokenStore {
    /// The item's service attribute in the app.
    static let defaultService = "software.tactile.texts.google-drive"
    static let account = "oauth-tokens"

    let service: String

    /// - Parameter service: the item's `kSecAttrService`; tests pass their own so they never touch
    ///   the app's item.
    init(service: String = GoogleDriveKeychainTokenStore.defaultService) {
        self.service = service
    }

    /// A Keychain call that failed. `status` is the `OSStatus`, for diagnostics.
    struct KeychainError: LocalizedError, Hashable, Sendable {
        let status: OSStatus
        var errorDescription: String? {
            "Tactile Texts couldn’t use the Keychain to keep your Google sign-in (error \(status))."
        }
    }

    @concurrent
    func load() async throws -> GoogleTokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        guard let tokens = try? JSONDecoder().decode(GoogleTokenSet.self, from: data) else {
            // Unreadable (written by an incompatible build): treat as signed out.
            SecItemDelete(baseQuery as CFDictionary)
            return nil
        }
        return tokens
    }

    @concurrent
    func save(_ tokens: GoogleTokenSet) async throws {
        let data: Data
        do { data = try JSONEncoder().encode(tokens) } catch { throw KeychainError(status: errSecParam) }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        let add = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    @concurrent
    func clear() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Identifies the one item: class, service, account, never synchronizable.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
