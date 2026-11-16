import Foundation
import CryptoKit
import Testing
@testable import ReaderBackup

/// A key with bytes 0, 1, 2, … 31.
let sequentialKey = try! BackupEncryptionKey(rawBytes: (0..<32).map { UInt8($0) })

func rawBytes(_ key: BackupEncryptionKey) -> [UInt8] { key.withUnsafeBytes { Array($0) } }

struct EncryptionKeyTests {
    @Test func generatedKeysAre256RandomBits() throws {
        let a = BackupEncryptionKey.generate()
        let b = BackupEncryptionKey.generate()
        #expect(rawBytes(a).count == 32)
        #expect(a != b)
        #expect(a == (try BackupEncryptionKey(rawBytes: rawBytes(a))))
        #expect(throws: BackupError.invalidEncryptionKey) { try BackupEncryptionKey(rawBytes: [UInt8](repeating: 1, count: 31)) }
        #expect(throws: BackupError.invalidEncryptionKey) { try BackupEncryptionKey(rawBytes: [UInt8](repeating: 1, count: 33)) }
    }

    @Test func subkeysAreIndependentAndPinned() {
        let purposes = BackupEncryptionKey.Purpose.allCases
        let subkeys = purposes.map { sequentialKey.subkey($0).withUnsafeBytes { Data($0) } }
        #expect(Set(subkeys).count == purposes.count)
        #expect(!subkeys.contains(Data(rawBytes(sequentialKey))))
        // HKDF-SHA256(IKM = 00…1f, salt = empty, info = "tactile-texts.backup.v1.content", L = 32),
        // computed independently with CryptoKit's HKDF primitive pieces (extract, then expand).
        let prk = HMAC<SHA256>.authenticationCode(for: rawBytes(sequentialKey), using: SymmetricKey(data: [UInt8](repeating: 0, count: 32)))
        var block = Data("tactile-texts.backup.v1.content".utf8)
        block.append(1)
        let okm = Data(HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: Data(prk))))
        #expect(subkeys[0] == okm)
    }

    @Test func recoveryKeyRoundTripsExactly() throws {
        for _ in 0..<50 {
            let key = BackupEncryptionKey.generate()
            let text = key.recoveryKey.formatted
            #expect(try BackupEncryptionKey(recoveryKey: text) == key)
        }
        let edgeKeys = [[UInt8](repeating: 0, count: 32), [UInt8](repeating: 0xFF, count: 32), rawBytes(sequentialKey)]
        for bytes in edgeKeys {
            let key = try BackupEncryptionKey(rawBytes: bytes)
            #expect(rawBytes(try BackupEncryptionKey(recoveryKey: key.recoveryKey.formatted)) == bytes)
        }
    }

    @Test func recoveryKeyFormat() throws {
        let text = sequentialKey.recoveryKey.formatted
        let groups = text.split(separator: "-")
        #expect(groups.count == 14)
        #expect(groups.allSatisfy { $0.count == 4 })
        #expect(text.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ-".contains($0) })
        // Pinned (computed independently from the documented format): the text form of a known key
        // must never change, or saved recovery keys break.
        #expect(text == "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG-3MQA")
    }

    @Test func recoveryKeyIgnoresCaseGroupingAndLookAlikes() throws {
        let key = BackupEncryptionKey.generate()
        let text = key.recoveryKey.formatted
        let compact = text.replacingOccurrences(of: "-", with: "")
        let variants = [
            text.lowercased(),
            compact,
            "  " + compact.enumerated().map { "\($0.offset % 7 == 0 ? " " : "")\($0.element)" }.joined() + "\n",
            text.replacingOccurrences(of: "-", with: " – "),
            text.replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l"),
            text.replacingOccurrences(of: "1", with: "I"),
        ]
        for variant in variants {
            #expect(try BackupEncryptionKey(recoveryKey: variant) == key, "\(variant)")
        }
    }

    @Test func everySingleCharacterTypoIsDetected() throws {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for sample in 0..<3 {
            let key = sample == 0 ? sequentialKey : BackupEncryptionKey.generate()
            let characters = Array(key.recoveryKey.formatted.replacingOccurrences(of: "-", with: ""))
            #expect(characters.count == 56)
            for position in characters.indices {
                for replacement in alphabet where replacement != characters[position] {
                    var typo = characters
                    typo[position] = replacement
                    #expect(throws: BackupError.recoveryKeyTypo, "position \(position) → \(replacement)") {
                        try BackupEncryptionKey(recoveryKey: String(typo))
                    }
                }
                // Swapping neighbours is caught too.
                if position + 1 < characters.count, characters[position] != characters[position + 1] {
                    var swapped = characters
                    swapped.swapAt(position, position + 1)
                    #expect(throws: BackupError.recoveryKeyTypo) { try BackupEncryptionKey(recoveryKey: String(swapped)) }
                }
            }
        }
    }

    @Test func malformedRecoveryKeysSayWhatIsWrong() {
        let compact = sequentialKey.recoveryKey.formatted.replacingOccurrences(of: "-", with: "")
        #expect(throws: BackupError.recoveryKeyWrongLength) { try BackupEncryptionKey(recoveryKey: String(compact.dropLast())) }
        #expect(throws: BackupError.recoveryKeyWrongLength) { try BackupEncryptionKey(recoveryKey: compact + "0") }
        #expect(throws: BackupError.recoveryKeyWrongLength) { try BackupEncryptionKey(recoveryKey: "") }
        #expect(throws: BackupError.recoveryKeyInvalidCharacter(position: 3)) {
            try BackupEncryptionKey(recoveryKey: "00U" + compact.dropFirst(3))
        }
        #expect(throws: BackupError.recoveryKeyInvalidCharacter(position: 5)) {
            try BackupEncryptionKey(recoveryKey: "000G-*" + compact.dropFirst(5))
        }
        #expect(throws: BackupError.recoveryKeyInvalidCharacter(position: 1)) { try BackupEncryptionKey(recoveryKey: "é") }
    }

    @Test func keyMaterialNeverAppearsInDescriptions() throws {
        let key = BackupEncryptionKey.generate()
        let recovery = key.recoveryKey
        let compact = recovery.formatted.replacingOccurrences(of: "-", with: "")
        let hex = rawBytes(key).map { String(format: "%02x", $0) }.joined()
        let base64 = Data(rawBytes(key)).base64EncodedString()
        let decimalList = rawBytes(key).map(String.init).joined(separator: ", ")
        let destination = EncryptedBackupDestination(id: "cloud", displayName: "Cloud", store: FolderBackupBlobStore(root: URL(fileURLWithPath: "/nonexistent")), key: key)

        var texts: [String] = []
        for value in [key as Any, recovery as Any, destination as Any, ObjectNames(key: key) as Any] {
            texts.append(String(describing: value))
            texts.append(String(reflecting: value))
            var dumped = ""
            dump(value, to: &dumped)
            texts.append(dumped)
            texts.append(Mirror(reflecting: value).children.map { "\($0.label ?? ""): \(String(reflecting: $0.value))" }.joined())
        }
        texts.append("\(key) \(recovery) \(destination)")
        let errors: [BackupError] = [.wrongEncryptionKey, .encryptedObjectDamaged(name: "x"), .invalidEncryptionKey,
                                     .recoveryKeyWrongLength, .recoveryKeyInvalidCharacter(position: 3), .recoveryKeyTypo]
        texts += errors.map { $0.localizedDescription } + errors.map { String(reflecting: $0) }

        let secrets = [hex, hex.uppercased(), base64, decimalList, compact, recovery.formatted, compact.lowercased(), String(compact.prefix(12))]
        for text in texts {
            for secret in secrets {
                #expect(!text.contains(secret), "key material in: \(text)")
            }
        }
        #expect(String(describing: key) == "BackupEncryptionKey(redacted)")
        #expect(String(describing: recovery) == "BackupRecoveryKey(redacted)")
    }
}
