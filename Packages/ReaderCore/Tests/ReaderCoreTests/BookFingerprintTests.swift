import Foundation
import Testing
import ReaderCore

/// `BookFingerprint` (`sha256-v1`). The pinned digests were computed independently of this code
/// (Python `hashlib` over the documented scheme); stored fingerprints of existing books depend on
/// them, so a failure here means the scheme changed, not that the test needs updating.
@Suite("Book fingerprint")
struct BookFingerprintTests {
    /// A scratch directory removed when the test ends.
    final class Scratch {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ data: Data, as name: String) throws -> URL {
            let file = url.appendingPathComponent(name)
            try data.write(to: file)
            return file
        }
    }

    /// 3 MiB + 12,345 bytes, byte `i` = `((i * 31 + 7) >> 3) & 0xFF`: large enough to be sampled.
    static let generatedSize = 3 * 1024 * 1024 + 12_345
    static func generated() -> Data {
        Data((0..<generatedSize).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ 7) >> 3) })
    }

    @Test func pinnedDigestsOfWholeFiles() throws {
        let scratch = try Scratch()
        #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(Data("hello".utf8), as: "hello.bin"))
                == "sha256-v1:7e3e9bd9882c94bcdaa6c58a231b1e3ac24ecc2e8d6418698e63eb628a607e7f")
        #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(Data(), as: "empty.bin"))
                == "sha256-v1:117883de2bae9251a58af1e5921a3a32934d395b9c8be159f647f5c4fa3457a1")
    }

    @Test func pinnedDigestOfASampledFile() throws {
        let scratch = try Scratch()
        let url = try scratch.write(Self.generated(), as: "generated.bin")
        #expect(!BookFingerprint.hashesWholeFile(size: Int64(Self.generatedSize)))
        #expect(try BookFingerprint.fingerprint(ofFileAt: url)
                == "sha256-v1:4c44ddbfcfd34b679d5f5522c3d27a1836b9374d31f2048bf50fc503be9f9e36")
    }

    @Test func constantsAndOffsets() {
        #expect(BookFingerprint.prefix == "sha256-v1:")
        #expect(BookFingerprint.chunkSize == 65_536)
        #expect(BookFingerprint.sampleCount == 32)
        // The whole-file limit is exactly 2 MiB.
        #expect(BookFingerprint.hashesWholeFile(size: 2 * 1024 * 1024))
        #expect(!BookFingerprint.hashesWholeFile(size: 2 * 1024 * 1024 + 1))
        #expect(BookFingerprint.sampleOffsets(forSize: 2 * 1024 * 1024).isEmpty)

        let size = Int64(Self.generatedSize)
        let offsets = BookFingerprint.sampleOffsets(forSize: size)
        #expect(offsets.count == 32)
        #expect(offsets[0] == 0 && offsets[1] == 99_759 && offsets[2] == 199_518)
        #expect(offsets[31] == 3_092_537)
        #expect(offsets.last == size - 65_536)
        #expect(offsets == offsets.sorted())

        let huge = BookFingerprint.sampleOffsets(forSize: 600 * 1024 * 1024)
        #expect(huge.count == 32 && huge.first == 0 && huge.last == 600 * 1024 * 1024 - 65_536)
    }

    @Test func wholeFileIsContentSensitiveAndNameBlind() throws {
        let scratch = try Scratch()
        var data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        let a = try BookFingerprint.fingerprint(ofFileAt: scratch.write(data, as: "a.pdf"))
        #expect(a.hasPrefix("sha256-v1:") && a.count == "sha256-v1:".count + 64)
        #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(data, as: "other name.pdf")) == a)
        data[50_000] ^= 0xFF
        #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(data, as: "b.pdf")) != a)
        // The size is part of the digest: one more zero byte changes it.
        data[50_000] ^= 0xFF
        data.append(0)
        #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(data, as: "c.pdf")) != a)
    }

    @Test func sampledFileSeesSampledBytesOnly() throws {
        let scratch = try Scratch()
        let original = Self.generated()
        let base = try BookFingerprint.fingerprint(ofFileAt: scratch.write(original, as: "base.bin"))
        let offsets = BookFingerprint.sampleOffsets(forSize: Int64(Self.generatedSize))

        // Inside a sampled chunk (the last byte of the file and a middle chunk): the digest changes.
        for index in [Self.generatedSize - 1, Int(offsets[16]) + 100] {
            var changed = original
            changed[index] ^= 0xFF
            #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(changed, as: "s\(index).bin")) != base)
        }
        // Between two sampled chunks: by design, the same fingerprint.
        let gap = Int(offsets[1]) - 1
        #expect(gap >= BookFingerprint.chunkSize)
        var unsampled = original
        unsampled[gap] ^= 0xFF
        #expect(try BookFingerprint.fingerprint(ofFileAt: scratch.write(unsampled, as: "gap.bin")) == base)
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try BookFingerprint.fingerprint(ofFileAt: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf"))
        }
    }
}
