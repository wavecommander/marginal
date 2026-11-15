import Foundation
import CryptoKit
import Testing
@testable import ReaderBackup

/// The documented format (`BackupFileEncryption`), re-implemented from its doc comment with
/// CryptoKit primitives only, as a check that the code does what the documentation says.
func referenceEncrypt(_ plaintext: [UInt8], key: BackupEncryptionKey, metadataJSON: [UInt8], chunkSize: Int,
                      salt: [UInt8], prefix: [UInt8]) throws -> [UInt8] {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    let master = SymmetricKey(data: rawBytes(key))
    let contentKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(), info: Data("tactile-texts.backup.v1.content".utf8), outputByteCount: 32)
    let fileKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, salt: salt, info: Data("tactile-texts.backup.v1.file".utf8), outputByteCount: 32)
    var fixed: [UInt8] = [0x89, 0x54, 0x54, 0x45, 0x4E, 0x43, 0x0D, 0x0A, 1] + be32(chunkSize) + salt + prefix + be32(metadataJSON.count + 16)
    let meta = try AES.GCM.seal(metadataJSON, using: fileKey, nonce: AES.GCM.Nonce(data: prefix + be32(0) + [2]), authenticating: fixed)
    fixed += meta.ciphertext + meta.tag
    let header = fixed
    var out = header
    let count = max(1, (plaintext.count + chunkSize - 1) / chunkSize)
    for i in 0..<count {
        let chunk = Array(plaintext[(i * chunkSize)..<min(plaintext.count, (i + 1) * chunkSize)])
        let box = try AES.GCM.seal(chunk, using: fileKey, nonce: AES.GCM.Nonce(data: prefix + be32(i) + [i == count - 1 ? 1 : 0]),
                                   authenticating: header)
        out += box.ciphertext + box.tag
    }
    return out
}

func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func bytes(fromHex hex: String) -> [UInt8] {
    let digits = Array(hex.utf8)
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
}

struct BackupFileEncryptionTests {
    static let smallChunk = 64

    /// Encrypts `plaintext` with the test hooks; returns the encrypted file's URL.
    func encrypt(_ dir: TemporaryDirectory, _ plaintext: Data, key: BackupEncryptionKey = sequentialKey, chunkSize: Int = smallChunk,
                 metadata: [String: String] = ["kind": "test"], name: String = "enc") throws -> URL {
        let source = try dir.file("\(name).plain", plaintext)
        let encrypted = dir.url.appendingPathComponent(name)
        try BackupFileEncryption.encrypt(source, to: encrypted, key: key, metadata: metadata, progress: nil,
                                         chunkSize: chunkSize, salt: nil, noncePrefix: nil)
        return encrypted
    }

    @Test(arguments: [0, 1, smallChunk - 1, smallChunk, smallChunk + 1, 2 * smallChunk, 5 * smallChunk + 17])
    func roundTripsWithSmallChunks(size: Int) throws {
        let dir = try TemporaryDirectory()
        let plaintext = pseudoRandomData(count: size, seed: UInt64(size))
        let metadata = ["kind": "test", "quote\"back\\slash": "line\nbreak\u{1} é ☃"]
        let encrypted = try encrypt(dir, plaintext, metadata: metadata)
        let json = BackupFileEncryption.canonicalJSON(metadata)
        #expect(Int64(try Data(contentsOf: encrypted).count)
                == BackupFileEncryption.encryptedSize(plaintextSize: Int64(size), metadataSize: json.count, chunkSize: Self.smallChunk))
        let output = dir.url.appendingPathComponent("out")
        let result = try BackupFileEncryption.decrypt(encrypted, to: output, key: sequentialKey)
        #expect(try Data(contentsOf: output) == plaintext)
        #expect(result.metadata == metadata)
        #expect(result.plaintext == ContentDigest(sha256: ContentHash.sha256(of: plaintext), size: Int64(size)))
    }

    @Test(arguments: [0, 1, BackupFileEncryption.chunkSize - 1, BackupFileEncryption.chunkSize, BackupFileEncryption.chunkSize + 1, multiChunkSize])
    func roundTripsWithTheRealChunkSize(size: Int) throws {
        let dir = try TemporaryDirectory()
        let plaintext = pseudoRandomData(count: size, seed: 77)
        let source = try dir.file("plain", plaintext)
        let encrypted = dir.url.appendingPathComponent("enc")
        let log = ProgressLog()
        let digest = try BackupFileEncryption.encrypt(source, to: encrypted, key: sequentialKey, metadata: ["kind": "x"], progress: log.callback)
        #expect(log.isWellFormed)
        #expect(digest.size == Int64(size))
        let encryptedSize = Int64(try Data(contentsOf: encrypted).count)
        #expect(encryptedSize == BackupFileEncryption.encryptedSize(plaintextSize: Int64(size), metadata: ["kind": "x"]))
        let chunks = max(1, (size + BackupFileEncryption.chunkSize - 1) / BackupFileEncryption.chunkSize)
        #expect(encryptedSize == Int64(56 + 12 + 16 + size + 16 * chunks), "the documented formula")
        let output = dir.url.appendingPathComponent("out")
        let decryptLog = ProgressLog()
        try BackupFileEncryption.decrypt(encrypted, to: output, key: sequentialKey, progress: decryptLog.callback)
        #expect(decryptLog.isWellFormed)
        #expect(try Data(contentsOf: output) == plaintext)
    }

    // MARK: - Pinned vectors

    static let pinnedSalt = (0x40..<0x60).map { UInt8($0) }
    static let pinnedPrefix: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]
    static let pinnedPlaintext = Data("Tactile Texts pinned vector: notes stay private.".utf8)

    /// 48-byte plaintext in 16-byte chunks (three chunks, the last full), metadata {"kind":"test"}.
    static let pinnedSmallChunks = """
    895454454e430d0a0100000010404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5fa0a1a2a3a4a5a60000001f\
    ecb43cae84a900ec3128aae86eb1ff615becbf4d12266c0d2d83417f802abc0eee435b46b159ae6ebdb5e51eaabeb8ffc20e7c4d7ed64215\
    a7e9cb747fe49397def3066199a9b0b88b083192e3b1643008cdba8525deae0eb09c8e39add9f4cc08f1e8d4b69e7b5795baa8c8d941a994\
    f3e893d71db6a4c81edf715e299bf0
    """
    /// The same plaintext in one 4 MiB chunk, no metadata (`{}`).
    static let pinnedOneChunk = """
    895454454e430d0a0100400000404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5fa0a1a2a3a4a5a600000012\
    ecebe675929690a8e92ce9925916b3fe6a89621141dc73fe9bcc1713db07ba379585b9470bf0de1f11a785f6210d88ed16d5d11c561ee102\
    6f900e41ea6189ad82c5b67b313eba4600137a1cddbd2612c404
    """

    func pinned(chunkSize: Int, metadata: [String: String]) throws -> [UInt8] {
        let dir = try TemporaryDirectory()
        let source = try dir.file("plain", Self.pinnedPlaintext)
        let encrypted = dir.url.appendingPathComponent("enc")
        try BackupFileEncryption.encrypt(source, to: encrypted, key: sequentialKey, metadata: metadata, progress: nil,
                                         chunkSize: chunkSize, salt: Self.pinnedSalt, noncePrefix: Self.pinnedPrefix)
        return [UInt8](try Data(contentsOf: encrypted))
    }

    @Test func pinnedVectorsMatchTheDocumentedFormat() throws {
        for (chunkSize, metadata, expected) in [(16, ["kind": "test"], Self.pinnedSmallChunks), (BackupFileEncryption.chunkSize, [:], Self.pinnedOneChunk)] {
            let produced = try pinned(chunkSize: chunkSize, metadata: metadata)
            let reference = try referenceEncrypt([UInt8](Self.pinnedPlaintext), key: sequentialKey,
                                                 metadataJSON: [UInt8](BackupFileEncryption.canonicalJSON(metadata)),
                                                 chunkSize: chunkSize, salt: Self.pinnedSalt, prefix: Self.pinnedPrefix)
            #expect(produced == reference, "the code and the documented format agree")
            #expect(hexString(produced) == expected, "a change here breaks existing backups")
        }
    }

    @Test func pinnedVectorsStillDecrypt() throws {
        let dir = try TemporaryDirectory()
        for (index, hex) in [Self.pinnedSmallChunks, Self.pinnedOneChunk].enumerated() {
            let file = try dir.file("fixture\(index)", Data(bytes(fromHex: hex)))
            let output = dir.url.appendingPathComponent("out\(index)")
            let result = try BackupFileEncryption.decrypt(file, to: output, key: sequentialKey)
            #expect(try Data(contentsOf: output) == Self.pinnedPlaintext)
            #expect(result.metadata == (index == 0 ? ["kind": "test"] : [:]))
        }
    }

    // MARK: - Tampering

    /// Decrypting `bytes` throws `encryptedObjectDamaged` and leaves no output or partial file.
    func expectDamaged(_ dir: TemporaryDirectory, _ bytes: [UInt8], key: BackupEncryptionKey = sequentialKey, _ comment: Comment,
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let file = try dir.file("tampered", Data(bytes))
        let output = dir.url.appendingPathComponent("out")
        #expect(throws: BackupError.encryptedObjectDamaged(name: "tampered"), comment, sourceLocation: sourceLocation) {
            try BackupFileEncryption.decrypt(file, to: output, key: key)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path), comment, sourceLocation: sourceLocation)
        #expect(dir.allPaths().filter { $0.contains("partial") }.isEmpty, comment, sourceLocation: sourceLocation)
    }

    @Test func everyKindOfTamperingIsDetected() throws {
        let dir = try TemporaryDirectory()
        let c = Self.smallChunk
        let plaintext = pseudoRandomData(count: 3 * c + 20, seed: 5)
        let original = [UInt8](try Data(contentsOf: try encrypt(dir, plaintext)))
        let headerSize = 56 + 15 + 16 // {"kind":"test"} is 15 bytes
        let stride = c + 16
        let chunkStarts = (0..<4).map { headerSize + $0 * stride }
        #expect(original.count == headerSize + 3 * stride + 20 + 16)
        func chunk(_ i: Int, of bytes: [UInt8] = original) -> [UInt8] {
            Array(bytes[chunkStarts[i]..<min(bytes.count, chunkStarts[i] + stride)])
        }
        func flipped(_ offset: Int) -> [UInt8] {
            var bytes = original
            bytes[offset] ^= 0xFF
            return bytes
        }

        // Every byte of the header (fixed part, metadata ciphertext, metadata tag).
        for offset in 0..<headerSize { try expectDamaged(dir, flipped(offset), "header byte \(offset)") }
        // A byte of each chunk's ciphertext and of each chunk's tag; the last byte of the file.
        for i in 0..<4 {
            try expectDamaged(dir, flipped(chunkStarts[i] + 3), "chunk \(i) ciphertext")
            try expectDamaged(dir, flipped(min(chunkStarts[i] + stride, original.count) - 1), "chunk \(i) tag")
        }
        // Truncation: at each chunk boundary (drops the final chunk), mid-chunk, inside the
        // header, to nothing.
        for i in 1..<4 { try expectDamaged(dir, Array(original[0..<chunkStarts[i]]), "cut at boundary \(i)") }
        try expectDamaged(dir, Array(original[0..<(chunkStarts[3] + 10)]), "cut inside the final chunk")
        try expectDamaged(dir, Array(original[0..<(chunkStarts[1] + 10)]), "cut inside a middle chunk")
        try expectDamaged(dir, Array(original[0..<headerSize]), "header only")
        try expectDamaged(dir, Array(original[0..<40]), "cut inside the fixed header")
        try expectDamaged(dir, Array(original.dropLast(1)), "last byte missing")
        try expectDamaged(dir, [], "empty")
        // Dropping the final chunk while keeping a full-size chunk last.
        try expectDamaged(dir, Array(original[0..<chunkStarts[3]]), "final chunk dropped")
        // Dropping a middle chunk.
        try expectDamaged(dir, Array(original[0..<chunkStarts[1]]) + Array(original[chunkStarts[2]...]), "middle chunk dropped")
        // Duplicating a chunk, and swapping two.
        try expectDamaged(dir, Array(original[0..<chunkStarts[2]]) + chunk(1) + Array(original[chunkStarts[2]...]), "chunk 1 duplicated")
        try expectDamaged(dir, Array(original[0..<chunkStarts[0]]) + chunk(1) + chunk(0) + Array(original[chunkStarts[2]...]), "chunks 0 and 1 swapped")
        // Appending.
        try expectDamaged(dir, original + [0], "one byte appended")
        try expectDamaged(dir, original + chunk(3), "final chunk appended again")
        try expectDamaged(dir, original + chunk(1), "a middle chunk appended")

        // Splicing: a chunk from another file with the same key, plaintext and chunk size.
        let other = [UInt8](try Data(contentsOf: try encrypt(dir, plaintext, name: "other")))
        #expect(other != original, "two encryptions of the same plaintext differ")
        for i in 0..<4 {
            var spliced = original
            spliced.replaceSubrange(chunkStarts[i]..<min(original.count, chunkStarts[i] + stride), with: chunk(i, of: other))
            try expectDamaged(dir, spliced, "chunk \(i) from another file")
        }
        try expectDamaged(dir, Array(other[0..<headerSize]) + Array(original[headerSize...]), "another file's header")

        // The wrong key, for a lone file, is indistinguishable from damage.
        try expectDamaged(dir, original, key: BackupEncryptionKey.generate(), "wrong key")

        // The untouched file still decrypts.
        let file = try dir.file("intact", Data(original))
        try BackupFileEncryption.decrypt(file, to: dir.url.appendingPathComponent("intact.out"), key: sequentialKey)
        #expect(try Data(contentsOf: dir.url.appendingPathComponent("intact.out")) == plaintext)
    }

    @Test func aNewerVersionIsReportedAsSuch() throws {
        let dir = try TemporaryDirectory()
        var bytes = [UInt8](try Data(contentsOf: try encrypt(dir, Data("x".utf8))))
        bytes[8] = 2
        let file = try dir.file("v2", Data(bytes))
        #expect(throws: BackupError.newerFormatVersion(2)) {
            try BackupFileEncryption.decrypt(file, to: dir.url.appendingPathComponent("out"), key: sequentialKey)
        }
    }

    @Test func twoEncryptionsDifferButBothDecrypt() throws {
        let dir = try TemporaryDirectory()
        let plaintext = pseudoRandomData(count: 1000, seed: 3)
        let a = try encrypt(dir, plaintext, name: "a")
        let b = try encrypt(dir, plaintext, name: "b")
        let aBytes = try Data(contentsOf: a), bBytes = try Data(contentsOf: b)
        #expect(aBytes != bBytes)
        #expect(aBytes.count == bBytes.count)
        #expect(aBytes[13..<52] != bBytes[13..<52], "fresh salt and nonce prefix")
        for file in [a, b] {
            let output = dir.url.appendingPathComponent(file.lastPathComponent + ".out")
            try BackupFileEncryption.decrypt(file, to: output, key: sequentialKey)
            #expect(try Data(contentsOf: output) == plaintext)
        }
    }

    @Test func callerChecksCanRefuseAndLeaveNothing() throws {
        let dir = try TemporaryDirectory()
        let encrypted = try encrypt(dir, pseudoRandomData(count: 500, seed: 1))
        let output = dir.url.appendingPathComponent("out")
        #expect(throws: BackupError.notABackup) {
            try BackupFileEncryption.decrypt(encrypted, to: output, key: sequentialKey, checkMetadata: { _ in throw BackupError.notABackup })
        }
        #expect(throws: BackupError.contentMismatch(name: "x")) {
            try BackupFileEncryption.decrypt(encrypted, to: output, key: sequentialKey, checkPlaintext: { _ in throw BackupError.contentMismatch(name: "x") })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(dir.allPaths().filter { $0.contains("partial") }.isEmpty)
    }

    @Test func cancellationRemovesPartialOutput() async throws {
        let dir = try TemporaryDirectory()
        let plaintext = pseudoRandomData(count: multiChunkSize, seed: 6)
        let source = try dir.file("plain", plaintext)
        let encrypted = dir.url.appendingPathComponent("enc")
        let error = await runCancelling { cancel in
            try BackupFileEncryption.encrypt(source, to: encrypted, key: sequentialKey, progress: { if $0 > 0 { cancel() } })
        }
        #expect(error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: encrypted.path))

        try BackupFileEncryption.encrypt(source, to: encrypted, key: sequentialKey)
        let output = dir.url.appendingPathComponent("out")
        let decryptError = await runCancelling { cancel in
            try BackupFileEncryption.decrypt(encrypted, to: output, key: sequentialKey, progress: { if $0 > 0 { cancel() } })
        }
        #expect(decryptError is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(dir.allPaths().filter { $0.contains("partial") }.isEmpty)
    }
}
