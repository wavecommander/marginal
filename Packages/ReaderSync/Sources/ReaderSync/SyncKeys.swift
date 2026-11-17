import CryptoKit
import Foundation
import ReaderBackup

/// The sync sub-keys of a reader's `BackupEncryptionKey`.
///
/// Sync uses the same key as the encrypted backups (`docs/CLOUD_SYNC_PLAN.md` "The key") and
/// never encrypts with it directly. Its sub-keys are derived exactly as the backup sub-keys are
/// (`BackupEncryptionKey.derivedKey(info:)`: HKDF-SHA256, empty salt, 32 bytes) with their own
/// versioned info strings, so they are independent of the backup sub-keys and of each other:
///
/// | Purpose                                          | `info`                                |
/// |--------------------------------------------------|---------------------------------------|
/// | Content of heads, history and blobs              | `tactile-texts.sync.v1.content`       |
/// | Blob names                                       | `tactile-texts.sync.v1.blob-name`     |
/// | Book keys                                        | `tactile-texts.sync.v1.book-key`      |
/// | Device labels (device names the service stores) | `tactile-texts.sync.v1.device-label`  |
///
/// PDFs are not sync content: they are stored once for backups and sync under
/// `EncryptedBackupDestination`'s name and format, with the backup key itself.
///
/// Nothing here is ever described: descriptions and mirrors print `SyncKeys(redacted)`.
public struct SyncKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The HKDF info strings (frozen: data written with them must stay readable).
    public enum Info {
        public static let content = "tactile-texts.sync.v1.content"
        public static let blobName = "tactile-texts.sync.v1.blob-name"
        public static let bookKey = "tactile-texts.sync.v1.book-key"
        public static let deviceLabel = "tactile-texts.sync.v1.device-label"
    }

    /// The reader's key, for PDFs (shared with backups).
    let master: BackupEncryptionKey
    /// The content sub-key as a `BackupEncryptionKey`, so blobs can use `BackupFileEncryption`
    /// with it as their master key (see `EncryptedSyncStore`).
    let content: BackupEncryptionKey
    /// The same content sub-key, for the head envelope's per-object keys.
    let contentKey: SymmetricKey
    let blobName: SymmetricKey
    let bookKey: SymmetricKey
    let deviceLabel: SymmetricKey

    public init(key: BackupEncryptionKey) {
        master = key
        // 32 bytes by construction, which `BackupEncryptionKey(rawBytes:)` always accepts.
        contentKey = key.derivedKey(info: Info.content)
        content = try! BackupEncryptionKey(rawBytes: contentKey.withUnsafeBytes { Array($0) })
        blobName = key.derivedKey(info: Info.blobName)
        bookKey = key.derivedKey(info: Info.bookKey)
        deviceLabel = key.derivedKey(info: Info.deviceLabel)
    }

    public var description: String { "SyncKeys(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    // MARK: Names

    /// The book key of the book whose PDF has this SHA-256: `hex(HMAC-SHA256(K_book,
    /// <lower-case hex SHA-256>))`, 64 lower-case hex digits. Two iPads that imported the same
    /// PDF separately find the same book; the operator cannot tell which PDF it is.
    public func bookKey(pdfSHA256 sha256: String) throws -> String {
        try SyncLayout.keyedName(SyncLayout.validSHA256(sha256), key: bookKey)
    }

    /// The name of the blob whose plaintext has this SHA-256: `hex(HMAC-SHA256(K_blob,
    /// <lower-case hex SHA-256>))`, 64 lower-case hex digits.
    public func blobName(sha256: String) throws -> String {
        try SyncLayout.keyedName(SyncLayout.validSHA256(sha256), key: blobName)
    }

    // MARK: Device labels

    /// Longest device name kept, in UTF-8 bytes; longer names are cut at a character boundary.
    public static let deviceLabelNameBytes = 64

    /// The device name sealed for the service, which lists devices without being able to read
    /// them: base64url (no padding) of `nonce (12) ‖ ciphertext (64) ‖ tag (16)` from
    /// AES-256-GCM(K_device, random nonce, the name in UTF-8 cut to at most 64 bytes and padded
    /// with 0x00 to exactly 64 (so the length does not show), associated data the ASCII
    /// `tactile-texts.sync.v1.device-label`). 123 characters.
    public func sealDeviceLabel(_ name: String) -> String {
        sealDeviceLabel(name, nonce: SyncRandomness.system.bytes(12))
    }

    func sealDeviceLabel(_ name: String, nonce: [UInt8]) -> String {
        var padded = [UInt8](SyncLayout.cut(name, toUTF8Bytes: Self.deviceLabelNameBytes).utf8)
        padded += [UInt8](repeating: 0, count: Self.deviceLabelNameBytes - padded.count)
        // A 12-byte nonce and a 256-bit key: sealing cannot fail.
        let sealed = try! AES.GCM.seal(padded, using: deviceLabel, nonce: try! AES.GCM.Nonce(data: nonce),
                                       authenticating: Data(Info.deviceLabel.utf8))
        return SyncLayout.base64URL(nonce + [UInt8](sealed.ciphertext) + [UInt8](sealed.tag))
    }

    /// The device name in a label made by `sealDeviceLabel`, or `nil` when it is not one made
    /// with this key.
    public func openDeviceLabel(_ label: String) -> String? {
        guard let bytes = SyncLayout.bytes(fromBase64URL: label), bytes.count == 12 + Self.deviceLabelNameBytes + 16,
              let nonce = try? AES.GCM.Nonce(data: bytes[0..<12]),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes[12..<(bytes.count - 16)],
                                               tag: bytes[(bytes.count - 16)...]),
              let opened = try? AES.GCM.open(box, using: deviceLabel, authenticating: Data(Info.deviceLabel.utf8))
        else { return nil }
        let padded = [UInt8](opened)
        let end = (padded.lastIndex(where: { $0 != 0 }) ?? -1) + 1
        guard !padded[0..<end].contains(0) else { return nil }
        return String(bytes: padded[0..<end], encoding: .utf8)
    }
}

/// Where random bytes come from: the system's secure generator, or (only in the fixture
/// generator and tests) a fixed sequence.
struct SyncRandomness: Sendable {
    let bytes: @Sendable (Int) -> [UInt8]

    static let system = SyncRandomness { count in
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Array($0) }
    }
}
