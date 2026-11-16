import Foundation
import CryptoKit

/// The key that encrypts a reader's cloud backups: 256 random bits.
///
/// Nothing is ever encrypted with this key directly. Independent sub-keys are derived from it
/// with HKDF-SHA256 (RFC 5869), with an empty salt (the input is already uniformly random) and
/// a distinct, versioned ASCII `info` string per purpose, each 32 bytes:
///
/// | Purpose                                  | `info`                                             |
/// |------------------------------------------|----------------------------------------------------|
/// | File contents (`BackupFileEncryption`)   | `tactile-texts.backup.v1.content`                  |
/// | Snapshot device name, encryption         | `tactile-texts.backup.v1.snapshot-name.encryption` |
/// | Snapshot device name, synthetic nonce    | `tactile-texts.backup.v1.snapshot-name.siv`        |
/// | PDF object names                         | `tactile-texts.backup.v1.pdf-name`                 |
/// | Key check object                         | `tactile-texts.backup.v1.key-check`                |
///
/// The key never appears in a description, debug description, mirror (`dump`) or error: they
/// all print `BackupEncryptionKey(redacted)`. Use `recoveryKey` to show it to the reader and
/// `withUnsafeBytes` to store it (the Keychain code, in another package).
public struct BackupEncryptionKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Length of the key in bytes.
    public static let byteCount = 32

    let master: SymmetricKey

    private init(master: SymmetricKey) {
        self.master = master
    }

    /// A new random key from CryptoKit's secure random number generator.
    public static func generate() -> BackupEncryptionKey {
        BackupEncryptionKey(master: SymmetricKey(size: .bits256))
    }

    /// The key with these 32 raw bytes (as stored by the Keychain). Throws `invalidEncryptionKey`
    /// for any other length.
    public init(rawBytes: some ContiguousBytes) throws {
        let count = rawBytes.withUnsafeBytes { $0.count }
        guard count == Self.byteCount else { throw BackupError.invalidEncryptionKey }
        master = SymmetricKey(data: rawBytes)
    }

    /// The key a recovery key stands for. Throws the recovery key errors of `BackupRecoveryKey`.
    public init(recoveryKey text: String) throws {
        self = try BackupRecoveryKey(text).encryptionKey
    }

    /// Gives `body` the 32 raw key bytes, for storing the key. Do not log or keep them.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try master.withUnsafeBytes(body)
    }

    /// The recovery key the reader writes down or saves; `BackupEncryptionKey(recoveryKey:)`
    /// turns it back into this key exactly.
    public var recoveryKey: BackupRecoveryKey {
        withUnsafeBytes { BackupRecoveryKey(keyBytes: Array($0)) }
    }

    /// Compares in constant time.
    public static func == (a: BackupEncryptionKey, b: BackupEncryptionKey) -> Bool {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in constantTimeEqual(x, y) } }
    }

    public var description: String { "BackupEncryptionKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    // MARK: - Sub-keys

    /// The purposes of the derived sub-keys; the raw value is the HKDF `info` string.
    enum Purpose: String, CaseIterable {
        case content = "tactile-texts.backup.v1.content"
        case snapshotNameEncryption = "tactile-texts.backup.v1.snapshot-name.encryption"
        case snapshotNameSIV = "tactile-texts.backup.v1.snapshot-name.siv"
        case pdfName = "tactile-texts.backup.v1.pdf-name"
        case keyCheck = "tactile-texts.backup.v1.key-check"
    }

    /// The 256-bit sub-key for `purpose`.
    func subkey(_ purpose: Purpose) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(), info: Data(purpose.rawValue.utf8), outputByteCount: 32)
    }
}

/// The text form of a `BackupEncryptionKey` that the reader can write down, save, and type back.
///
/// **Format.** 56 characters from Crockford's base-32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
/// (no I, L, O or U), shown in 14 groups of 4 joined by `-`:
///
/// - Characters 1 to 52 are the 32 key bytes read as a big-endian bit string, 5 bits per
///   character, followed by 4 zero bits.
/// - Characters 53 to 56 are a check value: the 52 data characters read as one base-32 number,
///   modulo the prime 1,048,573 (the largest prime below 2²⁰), written as 4 base-32 digits,
///   most significant first.
///
/// Because the modulus is a prime larger than 31 and coprime to 32, changing any one data
/// character changes the number by `d × 32^k` with `0 < |d| < 32`, which the prime cannot
/// divide, so every single-character typo is caught; so is swapping two adjacent characters
/// (`d × 31 × 32^k`). Other mistakes go unnoticed about once in a million.
///
/// **Reading.** Case does not matter; spaces, line breaks and dashes are ignored; `O` is read
/// as `0` and `I` and `L` as `1`, the characters they are mistaken for. Errors say whether the
/// length is wrong (`recoveryKeyWrongLength`), a character cannot occur
/// (`recoveryKeyInvalidCharacter`) or the check fails (`recoveryKeyTypo`); none of them says
/// "wrong key", because this text alone cannot know that.
///
/// The value never appears in a description, debug description or mirror; show `formatted`.
public struct BackupRecoveryKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Characters in a recovery key, not counting dashes.
    public static let characterCount = 56
    static let dataCharacterCount = 52
    static let checkCharacterCount = 4
    static let checkModulus: UInt32 = 1_048_573
    static let groupSize = 4

    /// The canonical form to show or save: 14 groups of 4 upper-case characters joined by `-`.
    public let formatted: String

    private let symbols: [UInt8]

    /// Reads a recovery key the reader typed or pasted (see the type's reading rules).
    public init(_ text: String) throws {
        var symbols: [UInt8] = []
        var position = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || Self.dashes.contains(scalar) { continue }
            position += 1
            guard let value = Self.symbolValue(scalar) else {
                throw BackupError.recoveryKeyInvalidCharacter(position: position)
            }
            symbols.append(value)
        }
        guard symbols.count == Self.characterCount else { throw BackupError.recoveryKeyWrongLength }
        let data = Array(symbols[0..<Self.dataCharacterCount])
        guard Array(symbols[Self.dataCharacterCount...]) == Self.checkSymbols(for: data),
              Base32.bytes(fromSymbols: data, byteCount: BackupEncryptionKey.byteCount) != nil else {
            throw BackupError.recoveryKeyTypo
        }
        self.init(symbols: symbols)
    }

    init(keyBytes: [UInt8]) {
        precondition(keyBytes.count == BackupEncryptionKey.byteCount)
        let data = Base32.symbols(fromBytes: keyBytes)
        self.init(symbols: data + Self.checkSymbols(for: data))
    }

    private init(symbols: [UInt8]) {
        self.symbols = symbols
        var text = ""
        for (index, symbol) in symbols.enumerated() {
            if index > 0, index % Self.groupSize == 0 { text.append("-") }
            text.append(Character(Unicode.Scalar(Base32.alphabet[Int(symbol)])))
        }
        formatted = text
    }

    /// The key this recovery key stands for.
    public var encryptionKey: BackupEncryptionKey {
        let bytes = Base32.bytes(fromSymbols: Array(symbols[0..<Self.dataCharacterCount]), byteCount: BackupEncryptionKey.byteCount)!
        // Exactly 32 bytes by construction.
        return try! BackupEncryptionKey(rawBytes: bytes)
    }

    public var description: String { "BackupRecoveryKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    public static func == (a: BackupRecoveryKey, b: BackupRecoveryKey) -> Bool {
        a.symbols.withUnsafeBytes { x in b.symbols.withUnsafeBytes { y in constantTimeEqual(x, y) } }
    }

    // MARK: - Internals

    private static let dashes: Set<Unicode.Scalar> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"]

    /// The value of a typed character, with Crockford's look-alike readings.
    private static func symbolValue(_ scalar: Unicode.Scalar) -> UInt8? {
        guard scalar.isASCII else { return nil }
        var byte = UInt8(scalar.value)
        if (97...122).contains(byte) { byte -= 32 } // upper-case
        switch byte {
        case UInt8(ascii: "O"): byte = UInt8(ascii: "0")
        case UInt8(ascii: "I"), UInt8(ascii: "L"): byte = UInt8(ascii: "1")
        default: break
        }
        return Base32.alphabet.firstIndex(of: byte).map(UInt8.init)
    }

    /// The four check symbols for the 52 data symbols.
    static func checkSymbols(for data: [UInt8]) -> [UInt8] {
        var remainder: UInt64 = 0
        for symbol in data {
            remainder = (remainder * 32 + UInt64(symbol)) % UInt64(checkModulus)
        }
        return (0..<checkCharacterCount).reversed().map { UInt8((remainder >> (5 * UInt64($0))) & 31) }
    }
}

/// Crockford base 32 (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`), as 5-bit symbols over a big-endian
/// bit string.
enum Base32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    static let lowercaseAlphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)

    /// The bytes as 5-bit symbols; the last symbol is padded with zero bits.
    static func symbols(fromBytes bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity((bytes.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(UInt8((buffer >> UInt32(bits)) & 31))
            }
        }
        if bits > 0 { result.append(UInt8((buffer << UInt32(5 - bits)) & 31)) }
        return result
    }

    /// The inverse of `symbols(fromBytes:)`: `nil` unless there are exactly the symbols for
    /// `byteCount` bytes and the padding bits are zero (so every byte string has one encoding).
    static func bytes(fromSymbols symbols: [UInt8], byteCount: Int) -> [UInt8]? {
        guard symbols.count == (byteCount * 8 + 4) / 5 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(byteCount)
        var buffer: UInt32 = 0
        var bits = 0
        for symbol in symbols {
            guard symbol < 32 else { return nil }
            buffer = (buffer << 5) | UInt32(symbol)
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        guard buffer == 0 else { return nil }
        return result
    }

    /// Lower-case text for object names.
    static func lowercaseString(_ bytes: [UInt8]) -> String {
        String(decoding: symbols(fromBytes: bytes).map { lowercaseAlphabet[Int($0)] }, as: UTF8.self)
    }

    /// The bytes of lower-case text made by `lowercaseString`, or `nil` for anything else.
    static func bytes(fromLowercase string: Substring, byteCount: Int) -> [UInt8]? {
        var symbols: [UInt8] = []
        for byte in string.utf8 {
            guard let index = lowercaseAlphabet.firstIndex(of: byte) else { return nil }
            symbols.append(UInt8(index))
        }
        return bytes(fromSymbols: symbols, byteCount: byteCount)
    }
}

/// `true` when the buffers are equal, taking time that depends only on their lengths.
func constantTimeEqual(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<a.count { difference |= a[index] ^ b[index] }
    return difference == 0
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    a.withUnsafeBytes { x in b.withUnsafeBytes { y in constantTimeEqual(x, y) } }
}
