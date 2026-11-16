import Foundation
import CryptoKit

/// A file's full-content identity: its SHA-256 (lower-case hex) and its size in bytes.
///
/// This is the hash a PDF must match to be linked to a book (the `document.sha256` sidecar holds
/// the same two values), and what the manifest records for every backed-up file.
public struct ContentDigest: Hashable, Codable, Sendable {
    /// 64 lower-case hex digits.
    public var sha256: String
    /// Size in bytes.
    public var size: Int64

    public init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

/// Full-content SHA-256 hashing, streamed so a 600 MB PDF is never held in memory.
public enum ContentHash {
    /// Lower-case hex SHA-256 of `data`.
    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// SHA-256 and size of the file at `url`, read in 4 MiB chunks. Checks for task cancellation
    /// between chunks (throwing `CancellationError`) and reports progress by bytes read.
    /// Blocking: call it off the main actor.
    public static func digest(ofFileAt url: URL, progress: BackupProgress? = nil) throws -> ContentDigest {
        progress?(0)
        let digest = try digest(ofFileAt: url) { done, total in
            if total > 0 { progress?(Double(done) / Double(total)) }
        }
        progress?(1)
        return digest
    }

    /// `digest(ofFileAt:progress:)` with a byte-count callback `(read, total)`.
    static func digest(ofFileAt url: URL, onBytes: (Int64, Int64) -> Void) throws -> ContentDigest {
        let file = try ReadOnlyFile(url: url)
        var hasher = ContentHasher()
        let total = Int64(file.size)
        try file.streamWholeFile { chunk in
            hasher.update(chunk)
            onBytes(hasher.byteCount, total)
        }
        return hasher.finalize()
    }

    /// Lower-case hex SHA-256 of the file at `url` (see `digest(ofFileAt:progress:)`).
    public static func sha256(ofFileAt url: URL, progress: BackupProgress? = nil) throws -> String {
        try digest(ofFileAt: url, progress: progress).sha256
    }

    /// `true` when `string` has the form of a hash this package writes: 64 lower-case hex digits.
    /// Used to validate names built from hashes (`pdfs/<sha256>.pdf`) before touching files.
    public static func isValidSHA256(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// An incremental SHA-256, so a file can be hashed in the same pass that copies, archives or
/// extracts it (reading a multi-gigabyte file once instead of twice).
///
///     var hasher = ContentHasher()
///     hasher.update(chunk)            // for each chunk, in order
///     let digest = hasher.finalize()  // sha256 + byte count
public struct ContentHasher: Sendable {
    private var hash = SHA256()
    /// Bytes fed in so far.
    public private(set) var byteCount: Int64 = 0

    public init() {}

    /// Feeds the next bytes.
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        hash.update(bufferPointer: bytes)
        byteCount += Int64(bytes.count)
    }

    /// Feeds the next bytes.
    public mutating func update(_ data: Data) {
        hash.update(data: data)
        byteCount += Int64(data.count)
    }

    /// The digest of everything fed in. The hasher itself is unchanged, so it can be finalised
    /// again or fed more.
    public func finalize() -> ContentDigest {
        ContentDigest(sha256: ContentHash.hex(hash.finalize()), size: byteCount)
    }
}
