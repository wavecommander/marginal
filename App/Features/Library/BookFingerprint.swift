import CryptoKit
import Foundation

/// The content fingerprint stored in `Book.fingerprint`.
///
/// **Scheme (`sha256-v1`)**: SHA-256 over
///
///     "marginal-fingerprint-v1\0" ‖ file size (8 bytes, big endian) ‖ sampled chunks
///
/// where the sampled chunks are 64 KiB each. A file of at most 2 MiB (32 chunks) is hashed whole.
/// A larger file contributes 32 chunks at offsets `i * (size - 64 KiB) / 31` for `i` in `0...31`,
/// so the first and last 64 KiB are always included. The cost is a fixed 2 MiB of reads and 32
/// seeks however large the file is (a 600 MB textbook fingerprints in a few milliseconds).
/// The digest is written as `"sha256-v1:"` followed by 64 lower-case hex digits.
///
/// Two files with the same size and the same bytes in every sampled chunk get the same
/// fingerprint even if they differ elsewhere. For textbook PDFs, which carry a cross-reference
/// table and trailer at the end and change size when edited, that does not happen in practice;
/// the cost of a false match is that the second import opens the first book.
nonisolated enum BookFingerprint {
    static let prefix = "sha256-v1:"
    static let chunkSize = 64 * 1024
    static let sampleCount = 32

    /// `true` when the whole file is read (size at most `chunkSize * sampleCount`).
    static func hashesWholeFile(size: Int64) -> Bool {
        size <= Int64(chunkSize * sampleCount)
    }

    /// Start offsets of the sampled chunks for a file of `size` bytes (empty when the whole file
    /// is hashed).
    static func sampleOffsets(forSize size: Int64) -> [Int64] {
        guard !hashesWholeFile(size: size) else { return [] }
        let span = size - Int64(chunkSize)
        return (0..<sampleCount).map { span * Int64($0) / Int64(sampleCount - 1) }
    }

    /// Fingerprint of the file at `url`. Reads at most 2 MiB. Throws if it cannot be read.
    static func fingerprint(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        var hasher = SHA256()
        hasher.update(data: Data("marginal-fingerprint-v1\0".utf8))
        withUnsafeBytes(of: UInt64(size).bigEndian) { hasher.update(bufferPointer: $0) }
        if hashesWholeFile(size: size) {
            try handle.seek(toOffset: 0)
            if let data = try handle.read(upToCount: Int(size)) { hasher.update(data: data) }
        } else {
            for offset in sampleOffsets(forSize: size) {
                try handle.seek(toOffset: UInt64(offset))
                if let data = try handle.read(upToCount: chunkSize) { hasher.update(data: data) }
            }
        }
        return prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
