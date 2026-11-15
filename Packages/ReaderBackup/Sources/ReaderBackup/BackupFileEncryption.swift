import Foundation
import CryptoKit

/// The encrypted file format of cloud backups (version 1): streaming authenticated encryption
/// with AES-256-GCM in fixed-size plaintext chunks, so a 1 GB PDF is encrypted and decrypted
/// with one chunk in memory.
///
/// ## Layout
///
/// All integers are unsigned big-endian. Offsets are in bytes.
///
///     offset  size  field
///     0       8     magic: 89 54 54 45 4E 43 0D 0A  ("\x89TTENC\r\n")
///     8       1     format version: 1
///     9       4     chunk size C: plaintext bytes per chunk, 1 … 4,194,304 (writers use 4,194,304)
///     13      32    file salt: random
///     45      7     nonce prefix: random
///     52      4     M: length of the encrypted metadata, 16 … 4,112
///     56      M     encrypted metadata: ciphertext ‖ 16-byte tag
///     56+M    …     chunks
///
/// The first 56 bytes are the **fixed header**; the first `H = 56 + M` bytes are the **header**.
///
/// ## Keys and nonces
///
/// - Content key `K_c` = HKDF-SHA256(master key, salt: empty, info:
///   `"tactile-texts.backup.v1.content"`, 32 bytes) (see `BackupEncryptionKey`).
/// - File key `K_f` = HKDF-SHA256(`K_c`, salt: the 32-byte file salt, info:
///   `"tactile-texts.backup.v1.file"`, 32 bytes). Every file has its own key.
/// - Every nonce is 12 bytes: `nonce prefix (7) ‖ counter (4) ‖ flag (1)`.
///
/// ## Metadata
///
/// A JSON object whose keys and values are strings, written canonically: keys sorted by their
/// UTF-8 bytes, no spaces, `"` and `\` escaped with a backslash, control characters below
/// U+0020 as `\u00xx` (lower-case hex), everything else as raw UTF-8; at most 4,096 bytes.
/// `{}` when there is none. It is encrypted as AES-256-GCM(`K_f`, nonce: prefix ‖ 0x00000000 ‖
/// 0x02, associated data: the fixed header). It is confidential and authenticated.
///
/// ## Chunks
///
/// The plaintext is cut into `n = max(1, ⌈P / C⌉)` chunks of C bytes, the last holding the rest
/// (1 … C bytes, or 0 bytes only when the whole plaintext is empty). Chunk `i` (from 0) is stored
/// as `ciphertext ‖ 16-byte tag` of AES-256-GCM(`K_f`, nonce: prefix ‖ i ‖ flag, associated
/// data: the whole header), where flag is `0x01` for the last chunk and `0x00` for the others.
/// Hence:
///
///     encrypted size = 56 + (metadata bytes + 16) + P + 16 × max(1, ⌈P / C⌉)
///
/// A reader finds the last chunk from the file's length: every chunk but the last is `C + 16`
/// bytes, and the last is `16 … C + 16` bytes (exactly 16 only when it is the only chunk).
///
/// ## What is detected
///
/// - **Header tampering:** the whole header is the associated data of every chunk (and the
///   fixed header that of the metadata), so changing any header byte fails authentication. The
///   chunk size, salt and prefix cannot be altered without detection either.
/// - **Reordering, duplication, dropping a middle chunk:** the chunk index is in the nonce, so a
///   chunk only opens at its own position.
/// - **Truncation:** the last chunk present must open with the "last" flag; a chunk written
///   without it does not, so a file cut at a chunk boundary fails, and one cut mid-chunk fails
///   on the shortened chunk. **Appending:** the old last chunk is then read as a middle chunk,
///   with the wrong flag, and fails.
/// - **Splicing between files:** each file has its own key (from its salt) and its own header,
///   so a chunk from another file does not open.
/// - **Wrong key:** indistinguishable from damage for a lone file (the metadata fails to open)
///   and reported as `encryptedObjectDamaged`. `EncryptedBackupDestination` tells the reader
///   about a wrong key separately, with its key check.
///
/// ## Why a nonce is never reused under one key
///
/// Within a file, each chunk has a distinct counter (at most 2³² chunks, enforced), and the
/// metadata uses flag `0x02`, which no chunk uses, so all of a file's nonces differ. Across
/// files, the key itself differs: `K_f` is derived from a fresh 256-bit random salt, so two
/// files share a key only if two salts collide (probability about `files² / 2²⁵⁷`); even then
/// their random 56-bit nonce prefixes would also have to collide. Rewriting a file always draws
/// a new salt and prefix.
///
/// ## Decryption
///
/// Every chunk is authenticated before any of its plaintext is written, and the plaintext goes
/// to a hidden temporary file beside the destination that is renamed into place only after the
/// last chunk has been authenticated (and any caller checks have passed). On any failure or
/// cancellation the temporary file is removed, so unauthenticated or incomplete plaintext is
/// never released as a finished file.
public enum BackupFileEncryption {
    /// `89 54 54 45 4E 43 0D 0A`
    public static let magic: [UInt8] = [0x89, 0x54, 0x54, 0x45, 0x4E, 0x43, 0x0D, 0x0A]
    /// The version this code writes and reads.
    public static let formatVersion: UInt8 = 1
    /// Plaintext bytes per chunk: 4 MiB.
    public static let chunkSize = 4 * 1024 * 1024
    /// AES-GCM tag length.
    public static let tagSize = 16
    /// Bytes before the encrypted metadata.
    public static let fixedHeaderSize = 56
    /// Largest metadata JSON, in bytes.
    public static let maximumMetadataSize = 4096

    static let saltSize = 32
    static let noncePrefixSize = 7
    static let fileKeyInfo = Data("tactile-texts.backup.v1.file".utf8)
    static let maximumChunkCount = UInt64(UInt32.max) + 1
    /// Versions after this one but up to this value are reported as "made by a newer version";
    /// any other unknown version byte is damage.
    static let highestPlausibleVersion: UInt8 = 15

    private enum NonceFlag: UInt8 {
        case middleChunk = 0x00
        case lastChunk = 0x01
        case metadata = 0x02
    }

    /// What decryption found: the authenticated metadata and the plaintext's digest.
    public struct DecryptedFile: Hashable, Sendable {
        public var metadata: [String: String]
        public var plaintext: ContentDigest
    }

    // MARK: - Sizes

    /// The exact size of the encrypted file for a plaintext of `plaintextSize` bytes with this
    /// metadata, in the chunk size writers use.
    public static func encryptedSize(plaintextSize: Int64, metadata: [String: String] = [:]) -> Int64 {
        encryptedSize(plaintextSize: plaintextSize, metadataSize: canonicalJSON(metadata).count, chunkSize: chunkSize)
    }

    static func encryptedSize(plaintextSize: Int64, metadataSize: Int, chunkSize: Int) -> Int64 {
        let chunks = max(1, (plaintextSize + Int64(chunkSize) - 1) / Int64(chunkSize))
        return Int64(fixedHeaderSize + metadataSize + tagSize) + plaintextSize + Int64(tagSize) * chunks
    }

    // MARK: - Encrypting

    /// Encrypts the file at `source` into `destination` (replacing any file there, atomically:
    /// a hidden temporary sibling is renamed into place when complete). Streams in chunks,
    /// checks for task cancellation before each, and reports progress by bytes read. Returns the
    /// SHA-256 and size of the plaintext it encrypted. On any failure nothing is left at
    /// `destination`. Throws `sourceFileChanged` if the source changes size while being read.
    /// Blocking: call it off the main actor.
    @discardableResult
    public static func encrypt(_ source: URL, to destination: URL, key: BackupEncryptionKey,
                               metadata: [String: String] = [:], progress: BackupProgress? = nil) throws -> ContentDigest {
        try encrypt(source, to: destination, key: key, metadata: metadata, progress: progress,
                    chunkSize: chunkSize, salt: nil, noncePrefix: nil)
    }

    /// `encrypt` with a chosen chunk size, salt and nonce prefix (tests only: pinned vectors
    /// and small chunks).
    @discardableResult
    static func encrypt(_ source: URL, to destination: URL, key: BackupEncryptionKey, metadata: [String: String],
                        progress: BackupProgress?, chunkSize: Int, salt: [UInt8]?, noncePrefix: [UInt8]?) throws -> ContentDigest {
        precondition((1...Self.chunkSize).contains(chunkSize))
        let metadataJSON = canonicalJSON(metadata)
        guard metadataJSON.count <= maximumMetadataSize else { throw BackupError.entryTooLarge(name: "metadata") }
        let salt = salt ?? randomBytes(saltSize)
        let prefix = noncePrefix ?? randomBytes(noncePrefixSize)
        precondition(salt.count == saltSize && prefix.count == noncePrefixSize)

        let fileKey = self.fileKey(key, salt: salt)
        var header = magic
        header.append(formatVersion)
        header.append(contentsOf: bigEndian(UInt32(chunkSize)))
        header.append(contentsOf: salt)
        header.append(contentsOf: prefix)
        header.append(contentsOf: bigEndian(UInt32(metadataJSON.count + tagSize)))
        let sealedMetadata = try AES.GCM.seal(metadataJSON, using: fileKey, nonce: nonce(prefix, 0, .metadata), authenticating: header)
        header.append(contentsOf: sealedMetadata.ciphertext)
        header.append(contentsOf: sealedMetadata.tag)

        let input = try ReadOnlyFile(url: source)
        let plaintextSize = input.size
        let chunkCount = max(1, (plaintextSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        guard chunkCount <= maximumChunkCount else { throw BackupError.entryTooLarge(name: source.lastPathComponent) }
        let changed = BackupError.sourceFileChanged(name: source.lastPathComponent)

        let temporary = FileOps.temporarySibling(of: destination)
        do {
            let output = try WritableFile(creatingAt: temporary)
            try output.write(Data(header))
            var hasher = ContentHasher()
            progress?(0)
            for index in 0..<chunkCount {
                try Task.checkCancellation()
                let offset = index * UInt64(chunkSize)
                let length = Int(min(UInt64(chunkSize), plaintextSize - offset))
                let chunk = try input.readExactly(at: offset, count: length, incomplete: changed)
                hasher.update(chunk)
                let flag: NonceFlag = index == chunkCount - 1 ? .lastChunk : .middleChunk
                let sealed = try AES.GCM.seal(chunk, using: fileKey, nonce: nonce(prefix, UInt32(index), flag), authenticating: header)
                try output.write(sealed.ciphertext)
                try output.write(sealed.tag)
                if plaintextSize > 0 { progress?(Double(hasher.byteCount) / Double(plaintextSize)) }
            }
            if try input.hasBytes(at: plaintextSize) { throw changed }
            try output.synchronize()
            try output.close()
            try FileOps.rename(temporary, to: destination)
            progress?(1)
            return hasher.finalize()
        } catch {
            FileOps.removeQuietly(temporary)
            throw error
        }
    }

    // MARK: - Decrypting

    /// Decrypts the file at `source` into `destination` (replacing any file there only on
    /// success; see "Decryption" above). Any authentication or format failure throws
    /// `encryptedObjectDamaged(name:)` with `name` (default: the source's file name); a version
    /// from a newer app throws `newerFormatVersion`.
    ///
    /// - `checkMetadata` runs as soon as the metadata is authenticated, before any chunk is
    ///   read, and may throw to stop (a wrong kind of object, say).
    /// - `checkPlaintext` runs after the last chunk is authenticated with the plaintext's digest,
    ///   before the file is renamed into place, and may throw to refuse it (a hash mismatch).
    ///
    /// Checks for task cancellation before each chunk and reports progress by bytes read.
    /// Blocking: call it off the main actor.
    @discardableResult
    public static func decrypt(_ source: URL, to destination: URL, key: BackupEncryptionKey, name: String? = nil,
                               progress: BackupProgress? = nil,
                               checkMetadata: (([String: String]) throws -> Void)? = nil,
                               checkPlaintext: ((ContentDigest) throws -> Void)? = nil) throws -> DecryptedFile {
        let damaged = BackupError.encryptedObjectDamaged(name: name ?? source.lastPathComponent)
        let input = try ReadOnlyFile(url: source)
        let total = input.size

        // Fixed header.
        guard total >= UInt64(fixedHeaderSize) else { throw damaged }
        let fixed = [UInt8](try input.readExactly(at: 0, count: fixedHeaderSize, incomplete: damaged))
        guard Array(fixed[0..<8]) == magic else { throw damaged }
        let version = fixed[8]
        guard version == formatVersion else {
            if version > formatVersion, version <= highestPlausibleVersion { throw BackupError.newerFormatVersion(Int(version)) }
            throw damaged
        }
        let chunkSize = Int(readBigEndian(fixed, at: 9))
        let salt = Array(fixed[13..<45])
        let prefix = Array(fixed[45..<52])
        let metadataLength = Int(readBigEndian(fixed, at: 52))
        guard (1...Self.chunkSize).contains(chunkSize),
              (tagSize...(maximumMetadataSize + tagSize)).contains(metadataLength),
              total >= UInt64(fixedHeaderSize + metadataLength) else { throw damaged }

        // Metadata.
        let sealedMetadata = [UInt8](try input.readExactly(at: UInt64(fixedHeaderSize), count: metadataLength, incomplete: damaged))
        let header = fixed + sealedMetadata
        let fileKey = self.fileKey(key, salt: salt)
        let metadataJSON = try open(sealedMetadata, fileKey: fileKey, nonce: nonce(prefix, 0, .metadata), header: fixed, damaged: damaged)
        guard let metadata = (try? JSONSerialization.jsonObject(with: metadataJSON)) as? [String: String] else { throw damaged }
        try checkMetadata?(metadata)

        // Chunk geometry, from the length.
        let headerSize = UInt64(header.count)
        let stride = UInt64(chunkSize + tagSize)
        let body = total - headerSize
        guard body >= UInt64(tagSize) else { throw damaged }
        let chunkCount = (body + stride - 1) / stride
        let lastLength = body - (chunkCount - 1) * stride
        guard lastLength >= UInt64(tagSize), chunkCount == 1 || lastLength > UInt64(tagSize),
              chunkCount <= maximumChunkCount else { throw damaged }

        let temporary = FileOps.temporarySibling(of: destination)
        do {
            let output = try WritableFile(creatingAt: temporary)
            var hasher = ContentHasher()
            progress?(0)
            for index in 0..<chunkCount {
                try Task.checkCancellation()
                let isLast = index == chunkCount - 1
                let length = isLast ? lastLength : stride
                let offset = headerSize + index * stride
                let sealed = [UInt8](try input.readExactly(at: offset, count: Int(length), incomplete: damaged))
                let plaintext = try open(sealed, fileKey: fileKey, nonce: nonce(prefix, UInt32(index), isLast ? .lastChunk : .middleChunk),
                                         header: header, damaged: damaged)
                try output.write(plaintext)
                hasher.update(plaintext)
                progress?(Double(offset + length) / Double(total))
            }
            // The file grew while it was read: not the file whose length we split.
            if try input.hasBytes(at: total) { throw damaged }
            let digest = hasher.finalize()
            try checkPlaintext?(digest)
            try output.synchronize()
            try output.close()
            try FileOps.rename(temporary, to: destination)
            progress?(1)
            return DecryptedFile(metadata: metadata, plaintext: digest)
        } catch {
            FileOps.removeQuietly(temporary)
            throw error
        }
    }

    // MARK: - Internals

    static func fileKey(_ key: BackupEncryptionKey, salt: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key.subkey(.content), salt: salt, info: fileKeyInfo, outputByteCount: 32)
    }

    private static func nonce(_ prefix: [UInt8], _ counter: UInt32, _ flag: NonceFlag) -> AES.GCM.Nonce {
        // 12 bytes, which `Nonce(data:)` always accepts.
        try! AES.GCM.Nonce(data: prefix + bigEndian(counter) + [flag.rawValue])
    }

    /// Opens `ciphertext ‖ tag`, mapping every failure to `damaged`.
    private static func open(_ sealed: [UInt8], fileKey: SymmetricKey, nonce: AES.GCM.Nonce, header: [UInt8],
                             damaged: BackupError) throws -> Data {
        guard sealed.count >= tagSize else { throw damaged }
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(tagSize), tag: sealed.suffix(tagSize))
            return try AES.GCM.open(box, using: fileKey, authenticating: header)
        } catch {
            throw damaged
        }
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Array($0) }
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func readBigEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The canonical JSON described in "Metadata".
    static func canonicalJSON(_ object: [String: String]) -> Data {
        func append(_ string: String, to out: inout [UInt8]) {
            out.append(UInt8(ascii: "\""))
            for byte in string.utf8 {
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                    out.append(UInt8(ascii: "\\"))
                    out.append(byte)
                case 0..<0x20:
                    let hex = Array("0123456789abcdef".utf8)
                    out.append(contentsOf: Array("\\u00".utf8))
                    out.append(hex[Int(byte >> 4)])
                    out.append(hex[Int(byte & 0x0F)])
                default:
                    out.append(byte)
                }
            }
            out.append(UInt8(ascii: "\""))
        }
        var out: [UInt8] = [UInt8(ascii: "{")]
        for (index, key) in object.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }).enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            append(key, to: &out)
            out.append(UInt8(ascii: ":"))
            append(object[key]!, to: &out)
        }
        out.append(UInt8(ascii: "}"))
        return Data(out)
    }
}
