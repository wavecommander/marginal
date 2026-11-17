import Foundation
import ReaderBackup
import Security
import Testing
@testable import TactileTexts

/// `BackupKeyStore`: every operation with the in-memory store, the same operations and the item's
/// attributes with the Keychain store.
struct BackupCloudServiceKeyStoreTests {
    // MARK: Shared behaviour

    /// What every `BackupKeyStore` does, starting empty.
    static func exercise(_ store: any BackupKeyStore) async throws {
        #expect(try await store.load() == nil)
        await #expect(throws: BackupKeyStoreError.noKey) { _ = try await store.recoveryKey() }

        let created = try await store.createKey()
        #expect(try await store.load() == created)
        // Never overwritten by createKey.
        await #expect(throws: BackupKeyStoreError.keyAlreadyExists) { _ = try await store.createKey() }
        #expect(try await store.load() == created)

        // The recovery key stands for the stored key.
        let recovery = try await store.recoveryKey()
        #expect(recovery == created.recoveryKey)
        #expect(try BackupEncryptionKey(recoveryKey: recovery.formatted) == created)

        // Adopting another key replaces it; typed forms are read as BackupRecoveryKey reads them.
        let other = BackupEncryptionKey.generate()
        let typed = other.recoveryKey.formatted.lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(try await store.adoptKey(recoveryKey: typed) == other)
        #expect(try await store.load() == other)
        #expect(try await store.recoveryKey() == other.recoveryKey)

        // Recovery key errors come through as they are, and store nothing.
        let formatted = created.recoveryKey.formatted
        await #expect(throws: BackupError.recoveryKeyWrongLength) { _ = try await store.adoptKey(recoveryKey: String(formatted.dropLast(2))) }
        var badCharacter = Array(formatted)
        badCharacter[5] = "U"   // not in Crockford's alphabet; position 5 counting from 1, dashes skipped
        await #expect(throws: BackupError.recoveryKeyInvalidCharacter(position: 5)) {
            _ = try await store.adoptKey(recoveryKey: String(badCharacter))
        }
        await #expect(throws: BackupError.recoveryKeyTypo) { _ = try await store.adoptKey(recoveryKey: Self.typo(formatted)) }
        #expect(try await store.load() == other)

        try await store.removeKey()
        #expect(try await store.load() == nil)
        try await store.removeKey()   // removing nothing succeeds
        await #expect(throws: BackupKeyStoreError.noKey) { _ = try await store.recoveryKey() }

        // Adopting with no key stored adds it (a new device).
        #expect(try await store.adoptKey(recoveryKey: formatted) == created)
        #expect(try await store.load() == created)
        try await store.removeKey()
    }

    /// `formatted` with its first data character changed to another valid one.
    static func typo(_ formatted: String) -> String {
        var characters = Array(formatted)
        characters[0] = characters[0] == "A" ? "B" : "A"
        return String(characters)
    }

    @Test func inMemoryStore() async throws {
        try await Self.exercise(InMemoryBackupKeyStore())
        let key = BackupEncryptionKey.generate()
        let seeded = InMemoryBackupKeyStore(key: key)
        #expect(try await seeded.load() == key)
        await #expect(throws: BackupKeyStoreError.keyAlreadyExists) { _ = try await seeded.createKey() }
    }

    @Test func concurrentCreatesMakeOneKey() async throws {
        let store = InMemoryBackupKeyStore()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { (try? await store.createKey()) != nil } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.filter { $0 }.count == 1)
    }

    @Test func noKeyMaterialInDescriptionsOrErrors() async throws {
        let key = BackupEncryptionKey.generate()
        let store = InMemoryBackupKeyStore(key: key)
        let formatted = key.recoveryKey.formatted
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        var texts = [String(describing: store), String(reflecting: store), String(describing: KeychainBackupKeyStore())]
        var dumped = ""
        dump(store, to: &dumped)
        texts.append(dumped)
        let errors: [any Error] = [BackupKeyStoreError.keyAlreadyExists, BackupKeyStoreError.noKey,
                                   BackupKeyStoreError.storedKeyUnreadable, BackupKeyStoreError.keychain(status: errSecMissingEntitlement)]
        for error in errors { texts += [error.localizedDescription, String(describing: error)] }
        for text in texts {
            #expect(!text.contains(formatted))
            #expect(!text.contains(String(formatted.prefix(9))))
            #expect(!text.lowercased().contains(hex))
        }
        #expect(Set(errors.map(\.localizedDescription)).count == errors.count)
    }

    // MARK: Keychain

    /// The unsigned simulator test host (`CODE_SIGNING_ALLOWED = NO`: no `application-identifier`
    /// entitlement) gets `errSecMissingEntitlement` (-34018) from every `SecItem` call. That is
    /// recorded as a known issue; on a signed host the
    /// checks run in full and any other failure fails the test.
    private func withKeychain(_ body: () async throws -> Void) async throws {
        try await withKnownIssue("Unsigned simulator test host: Keychain returns errSecMissingEntitlement (-34018)",
                                 isIntermittent: true) {
            try await body()
        } matching: { issue in
            (issue.error as? BackupKeyStoreError) == .keychain(status: errSecMissingEntitlement)
        }
    }

    @Test func keychainStoreDoesEveryOperation() async throws {
        try await withKeychain {
            let store = KeychainBackupKeyStore(service: "software.tactile.texts.tests.\(UUID().uuidString)")
            defer { Task { try? await store.removeKey() } }
            try await Self.exercise(store)
        }
    }

    @Test func keychainItemSynchronisesAndIsReadableAfterFirstUnlock() async throws {
        try await withKeychain {
            let service = "software.tactile.texts.tests.\(UUID().uuidString)"
            let store = KeychainBackupKeyStore(service: service)
            defer { Task { try? await store.removeKey() } }
            let key = try await store.createKey()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
            let items = try #require(result as? [[String: Any]])
            #expect(items.count == 1)
            #expect((items[0][kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == true)
            #expect(items[0][kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
            #expect(items[0][kSecAttrAccount as String] as? String == KeychainBackupKeyStore.account)
            #expect(items[0][kSecValueData as String] as? Data == key.withUnsafeBytes { Data($0) })
            // A query that doesn't name the attribute doesn't see the item (Apple's documented
            // behaviour, the reason every query of the store names it).
            let unnamed: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                          kSecMatchLimit as String: kSecMatchLimitAll]
            #expect(SecItemCopyMatching(unnamed as CFDictionary, nil) == errSecItemNotFound)
        }
    }

    @Test func keychainStoreRefusesAnItemThatIsNotAKey() async throws {
        try await withKeychain {
            let service = "software.tactile.texts.tests.\(UUID().uuidString)"
            let store = KeychainBackupKeyStore(service: service)
            defer { Task { try? await store.removeKey() } }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: KeychainBackupKeyStore.account,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: Data("short".utf8),
            ]
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecMissingEntitlement { throw BackupKeyStoreError.keychain(status: status) }
            #expect(status == errSecSuccess)
            await #expect(throws: BackupKeyStoreError.storedKeyUnreadable) { _ = try await store.load() }
            await #expect(throws: BackupKeyStoreError.storedKeyUnreadable) { _ = try await store.createKey() }
            // Left in place, not deleted.
            await #expect(throws: BackupKeyStoreError.storedKeyUnreadable) { _ = try await store.load() }
        }
    }
}
