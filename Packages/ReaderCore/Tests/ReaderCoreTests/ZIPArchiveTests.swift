import Foundation
import Testing
@testable import ReaderCore

@Suite("ZIP archive")
struct ZIPArchiveTests {
    let temp = TempDirectory()

    /// Compressible but not trivial: 1 MB of repeating text with a counter.
    static let bigText = Data((0..<40_000).map { "line \($0) of the page text\n" }.joined().utf8)

    @Test func crcMatchesKnownValues() {
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        var incremental = CRC32()
        incremental.update(Data("1234".utf8))
        incremental.update(Data("56789".utf8))
        #expect(incremental.value == 0xCBF4_3926)
    }

    @Test func storedAndDeflateRoundTrip() throws {
        let binary = noise(70_000, seed: 7)
        let zip = TestZIP([
            TestZIPEntry("a.txt", "hello"),
            TestZIPEntry("dir/", Data()),
            TestZIPEntry("dir/big.txt", Self.bigText, method: .deflate),
            TestZIPEntry("dir/noise.bin", binary, method: .deflate),
            TestZIPEntry("empty.txt", Data()),
        ]).build()
        let archive = try ZIPArchive(data: zip)
        #expect(archive.entries.map(\.path) == ["a.txt", "dir/", "dir/big.txt", "dir/noise.bin", "empty.txt"])
        #expect(archive.entries.map(\.isDirectory) == [false, true, false, false, false])
        #expect(archive.entries.allSatisfy { !$0.hasUnsafePath })
        #expect(try archive.data(at: "a.txt", maxSize: 100) == Data("hello".utf8))
        let big = try #require(archive.entry(at: "dir/big.txt"))
        #expect(big.compressionMethod == 8 && big.compressedSize < big.uncompressedSize)
        #expect(big.fileName == "big.txt")
        #expect(try archive.data(for: big, maxSize: 10 << 20) == Self.bigText)
        #expect(try archive.data(at: "dir/noise.bin", maxSize: 1 << 20) == binary)
        #expect(try archive.data(at: "empty.txt", maxSize: 0) == Data())
        #expect(try archive.data(at: "dir/", maxSize: 0) == Data())
        #expect(archive.entry(at: "missing") == nil)
        #expect(thrownError { _ = try archive.data(at: "missing", maxSize: 1) } as? ZIPError == .entryNotFound(path: "missing"))
    }

    @Test func fileBackedArchiveReadsLikeInMemory() throws {
        let zip = TestZIP([TestZIPEntry("x/big.txt", Self.bigText, method: .deflate), TestZIPEntry("y.txt", "why")]).build()
        let url = temp.file("archive.zip", zip)
        let archive = try ZIPArchive(url: url)
        #expect(archive.entries.map(\.path) == ["x/big.txt", "y.txt"])
        #expect(try archive.data(at: "x/big.txt", maxSize: 10 << 20) == Self.bigText)
        #expect(try archive.data(at: "y.txt", maxSize: 10) == Data("why".utf8))
        let missing = temp.url.appendingPathComponent("nope.zip")
        guard case .readFailed? = thrownError({ _ = try ZIPArchive(url: missing) }) as? ZIPError else {
            Issue.record("expected readFailed"); return
        }
    }

    @Test func streamingEqualsFullRead() throws {
        let binary = noise(300_000, seed: 3)
        let zip = TestZIP([
            TestZIPEntry("big.txt", Self.bigText, method: .deflate),
            TestZIPEntry("noise.bin", binary, method: .stored),
        ]).build()
        let archive = try ZIPArchive(url: temp.file("s.zip", zip))
        for entry in archive.entries {
            let full = try archive.data(for: entry, maxSize: .max)
            for chunkSize in [1, 1000, 4096, 65_536, 1 << 20] where !(chunkSize == 1 && entry.uncompressedSize > 400_000) {
                var streamed = Data()
                var largestChunk = 0
                try archive.read(entry, chunkSize: chunkSize) { chunk in
                    largestChunk = max(largestChunk, chunk.count)
                    streamed.append(chunk)
                }
                #expect(streamed == full, "\(entry.path) chunk \(chunkSize)")
                #expect(largestChunk <= chunkSize)
            }
        }
    }

    @Test func crcMismatchThrows() throws {
        var stored = TestZIPEntry("a.txt", "hello")
        stored.declaredCRC = 0x1234_5678
        var deflated = TestZIPEntry("b.txt", Self.bigText, method: .deflate)
        deflated.declaredCRC = 0
        let archive = try ZIPArchive(data: TestZIP([stored, deflated]).build())
        #expect(thrownError { _ = try archive.data(at: "a.txt", maxSize: 100) } as? ZIPError
            == .crcMismatch(path: "a.txt", expected: 0x1234_5678, actual: CRC32.checksum(Data("hello".utf8))))
        guard case .crcMismatch(path: "b.txt", _, _)? = thrownError({ _ = try archive.data(at: "b.txt", maxSize: .max) }) as? ZIPError else {
            Issue.record("expected crcMismatch"); return
        }
        // Streaming reports it at the end too.
        #expect(thrownError { try archive.read(archive.entries[0]) { _ in } } != nil)
    }

    @Test func zip64RecordsAndExtraFields() throws {
        var first = TestZIPEntry("one.txt", "first entry")
        first.zip64 = true
        var second = TestZIPEntry("two.txt", Self.bigText, method: .deflate)
        second.zip64 = true
        var zip = TestZIP([first, second, TestZIPEntry("three.txt", "plain")])
        zip.zip64EOCD = true
        let data = zip.build()
        let archive = try ZIPArchive(data: data)
        #expect(archive.entries.map(\.path) == ["one.txt", "two.txt", "three.txt"])
        #expect(archive.entries[1].uncompressedSize == UInt64(Self.bigText.count))
        #expect(archive.entries[1].localHeaderOffset > 0)
        #expect(try archive.data(at: "one.txt", maxSize: 100) == Data("first entry".utf8))
        #expect(try archive.data(at: "two.txt", maxSize: .max) == Self.bigText)
        #expect(try archive.data(at: "three.txt", maxSize: 100) == Data("plain".utf8))
    }

    @Test func zip64LocatorPointingOutsideTheFileThrows() throws {
        var zip = TestZIP([TestZIPEntry("a", "a")])
        zip.zip64EOCD = true
        var data = zip.build()
        // The locator's record offset sits 22 (EOCD) + 12 bytes from the end.
        let offsetField = data.count - 22 - 12
        data.replaceSubrange(offsetField..<(offsetField + 8), with: Data(repeating: 0xFF, count: 8))
        #expect(thrownError { _ = try ZIPArchive(data: data) } as? ZIPError == .corruptCentralDirectory)
    }

    @Test func archiveCommentIsReadAndSkipped() throws {
        let archive = try ZIPArchive(data: zipData([("a.txt", "A")], comment: "Scanned by someone. ✓"))
        #expect(archive.comment == "Scanned by someone. ✓")
        #expect(try archive.data(at: "a.txt", maxSize: 10) == Data("A".utf8))

        // A comment containing a fake end record still finds the real one.
        var fake = Data()
        fake.le32(0x0605_4B50)
        fake.append(Data(repeating: 0, count: 18))
        var zip = TestZIP([TestZIPEntry("b.txt", "B")])
        zip.comment = Data("x".utf8) + fake + Data("tail".utf8)
        let tricky = try ZIPArchive(data: zip.build())
        #expect(try tricky.data(at: "b.txt", maxSize: 10) == Data("B".utf8))
    }

    @Test func traversalAndOddNamesAreFlaggedAndNeverRead() throws {
        let hostile = ["../evil.txt", "a/../../evil.txt", "/etc/passwd", "\\windows\\evil", "..\\evil.txt",
                       "a\\..\\..\\evil", "C:\\evil.txt", "c:/evil.txt", "a/..", ""]
        let benign = ["a..b/c.txt", "..hidden", "dir/.../x", "ok/fine.txt"]
        var entries = (hostile + benign).map { TestZIPEntry($0, "x") }
        entries.append(TestZIPEntry(rawName: Array("nul\u{0}.txt".utf8), Data("x".utf8)))
        let archive = try ZIPArchive(data: TestZIP(entries).build())
        for entry in archive.entries {
            let shouldBeUnsafe = !benign.contains(entry.path)
            #expect(entry.hasUnsafePath == shouldBeUnsafe, "\(entry.path)")
            if shouldBeUnsafe {
                #expect(thrownError { _ = try archive.data(for: entry, maxSize: 10) } as? ZIPError
                    == .unsafeEntryName(path: entry.path))
                #expect(thrownError { try archive.read(entry) { _ in } } as? ZIPError == .unsafeEntryName(path: entry.path))
            } else {
                #expect(try archive.data(for: entry, maxSize: 10) == Data("x".utf8))
            }
        }
        // Names are never normalised.
        #expect(archive.entries.first?.path == "../evil.txt")
    }

    @Test func entryNamesUTF8AndCP437() throws {
        var utf8 = TestZIPEntry("Kapitel ü/Seite 1.jpg", "x")
        utf8.flags = 0x0800
        let unflaggedUTF8 = TestZIPEntry("日本語.png", "x")
        let cp437 = TestZIPEntry(rawName: [0x80, 0x61, 0x81, 0x2E, 0x74, 0x78, 0x74], Data("x".utf8)) // "Çaü.txt"
        let archive = try ZIPArchive(data: TestZIP([utf8, unflaggedUTF8, cp437]).build())
        #expect(archive.entries.map(\.path) == ["Kapitel ü/Seite 1.jpg", "日本語.png", "Çaü.txt"])
        #expect(ZIPText.cp437High.count == 128)
        #expect(ZIPText.cp437High[0xB0 - 0x80] == "░" && ZIPText.cp437High[0xFF - 0x80] == "\u{A0}")
    }

    @Test func entryCountTotalSizeAndDirectoryCaps() throws {
        let zip = zipData((0..<5).map { ("f\($0).txt", "0123456789") })
        #expect(thrownError { _ = try ZIPArchive(data: zip, limits: .init(maxEntryCount: 4)) } as? ZIPError
            == .tooManyEntries(declared: 5, limit: 4))
        #expect(throws: Never.self) { _ = try ZIPArchive(data: zip, limits: .init(maxEntryCount: 5)) }
        #expect(thrownError { _ = try ZIPArchive(data: zip, limits: .init(maxTotalUncompressedSize: 49)) } as? ZIPError
            == .totalUncompressedSizeTooLarge(limit: 49))
        #expect(throws: Never.self) { _ = try ZIPArchive(data: zip, limits: .init(maxTotalUncompressedSize: 50)) }
        guard case .centralDirectoryTooLarge? = thrownError({
            _ = try ZIPArchive(data: zip, limits: .init(maxCentralDirectorySize: 100))
        }) as? ZIPError else { Issue.record("expected centralDirectoryTooLarge"); return }

        // A lie in the sizes that sums past 4 GB is caught by the default limit.
        var huge = TestZIPEntry("bomb.txt", "x")
        huge.zip64 = true
        huge.declaredUncompressedSize = 5 << 30
        #expect(thrownError { _ = try ZIPArchive(data: TestZIP([huge]).build()) } as? ZIPError
            == .totalUncompressedSizeTooLarge(limit: 4 << 30))
        // Sizes that would overflow UInt64 when summed throw rather than trap.
        var a = TestZIPEntry("a", "x"); a.zip64 = true; a.declaredUncompressedSize = .max
        var b = TestZIPEntry("b", "x"); b.zip64 = true; b.declaredUncompressedSize = .max
        let overflowing = TestZIP([a, b]).build()
        #expect(thrownError { _ = try ZIPArchive(data: overflowing, limits: .init(maxTotalUncompressedSize: .max)) } as? ZIPError
            == .totalUncompressedSizeTooLarge(limit: .max))
    }

    @Test func inflatingPastTheDeclaredSizeStops() throws {
        var lie = TestZIPEntry("lie.txt", Self.bigText, method: .deflate)
        lie.declaredUncompressedSize = 1000
        var short = TestZIPEntry("short.txt", Self.bigText, method: .deflate)
        short.declaredUncompressedSize = UInt64(Self.bigText.count + 10)
        let archive = try ZIPArchive(data: TestZIP([lie, short]).build())
        var received = 0
        let error = thrownError { try archive.read(archive.entries[0], chunkSize: 4096) { received += $0.count } }
        #expect(error as? ZIPError == .uncompressedSizeExceeded(path: "lie.txt"))
        #expect(received <= 1000)
        #expect(thrownError { _ = try archive.data(at: "lie.txt", maxSize: .max) } as? ZIPError
            == .uncompressedSizeExceeded(path: "lie.txt"))
        #expect(thrownError { _ = try archive.data(at: "short.txt", maxSize: .max) } as? ZIPError
            == .sizeMismatch(path: "short.txt"))

        // A stored entry whose sizes disagree.
        var stored = TestZIPEntry("s.txt", "abc")
        stored.declaredUncompressedSize = 2
        let storedArchive = try ZIPArchive(data: TestZIP([stored]).build())
        #expect(thrownError { _ = try storedArchive.data(at: "s.txt", maxSize: 10) } as? ZIPError == .sizeMismatch(path: "s.txt"))
    }

    @Test func implausibleRatioAndMaxSizeAreCheckedBeforeReading() throws {
        var bomb = TestZIPEntry("bomb.bin", Data("x".utf8), method: .deflate)
        bomb.declaredUncompressedSize = 3 << 30
        let archive = try ZIPArchive(data: TestZIP([bomb, TestZIPEntry("ok.txt", Self.bigText, method: .deflate)]).build())
        #expect(thrownError { try archive.read(archive.entries[0]) { _ in } } as? ZIPError
            == .implausibleCompressionRatio(path: "bomb.bin"))
        #expect(thrownError { _ = try archive.data(at: "ok.txt", maxSize: 100) } as? ZIPError
            == .entryTooLarge(path: "ok.txt", size: UInt64(Self.bigText.count), limit: 100))
    }

    @Test func truncatedFilesThrow() throws {
        let zip = TestZIP([TestZIPEntry("a.txt", Self.bigText, method: .deflate), TestZIPEntry("b.txt", "bee")]).build()
        // Cut anywhere: opening throws (usually `truncated`), never traps.
        for cut in [0, 3, 10, 100, zip.count / 2, zip.count - 30, zip.count - 1] {
            let error = thrownError { _ = try ZIPArchive(data: zip.prefix(cut)) }
            #expect(error is ZIPError, "cut at \(cut)")
        }
        #expect(thrownError { _ = try ZIPArchive(data: zip.prefix(zip.count - 1)) } as? ZIPError == .truncated)
        #expect(thrownError { _ = try ZIPArchive(data: Data("hello, not a zip at all".utf8)) } as? ZIPError == .notAZIPArchive)

        // Entry data that runs past the end of the file.
        var long = TestZIPEntry("long.txt", "abc")
        long.declaredCompressedSize = 1 << 40
        long.declaredUncompressedSize = 1 << 40
        long.zip64 = true
        let archive = try ZIPArchive(data: TestZIP([long]).build(), limits: .init(maxTotalUncompressedSize: .max))
        #expect(thrownError { _ = try archive.data(at: "long.txt", maxSize: .max) } as? ZIPError == .truncated)
    }

    @Test func encryptedAndUnsupportedEntriesThrowForThatEntryOnly() throws {
        var encrypted = TestZIPEntry("secret.txt", "xxxx")
        encrypted.flags = 0x0001
        let bzip2 = TestZIPEntry("b.bz2", Data("BZh9".utf8), method: .raw(12))
        let archive = try ZIPArchive(data: TestZIP([encrypted, bzip2, TestZIPEntry("ok.txt", "ok")]).build())
        #expect(archive.entries[0].isEncrypted)
        #expect(thrownError { _ = try archive.data(at: "secret.txt", maxSize: 100) } as? ZIPError == .encryptedEntry(path: "secret.txt"))
        #expect(!archive.entries[1].isCompressionSupported)
        #expect(thrownError { _ = try archive.data(at: "b.bz2", maxSize: 100) } as? ZIPError
            == .unsupportedCompressionMethod(path: "b.bz2", method: 12))
        #expect(try archive.data(at: "ok.txt", maxSize: 100) == Data("ok".utf8))
    }

    @Test func corruptDeflateDataThrows() throws {
        var garbage = TestZIPEntry("g.txt", noise(5000, seed: 11), method: .raw(8))
        garbage.declaredUncompressedSize = 5000
        let archive = try ZIPArchive(data: TestZIP([garbage]).build())
        let error = thrownError { _ = try archive.data(at: "g.txt", maxSize: .max) }
        #expect(error is ZIPError)
    }

    @Test func hostileEndRecordsThrow() throws {
        func eocd(entries: UInt16, size: UInt32, offset: UInt32, disk: UInt16 = 0) -> Data {
            var d = Data()
            d.le32(0x0605_4B50); d.le16(disk); d.le16(0); d.le16(entries); d.le16(entries)
            d.le32(size); d.le32(offset); d.le16(0)
            return d
        }
        // Directory beyond the file.
        #expect(thrownError { _ = try ZIPArchive(data: eocd(entries: 1, size: 46, offset: 0xFFFF_FF00)) } as? ZIPError
            == .corruptCentralDirectory)
        // Many entries claimed in a tiny directory.
        #expect(thrownError { _ = try ZIPArchive(data: Data(repeating: 0, count: 100) + eocd(entries: 0xFFFF, size: 100, offset: 0)) }
            as? ZIPError == .corruptCentralDirectory)
        // Offset + size overflow 32 bits (fine in UInt64, still outside the file).
        #expect(thrownError { _ = try ZIPArchive(data: eocd(entries: 1, size: 0x0300_0000, offset: 0xFFFF_FFFE)) } as? ZIPError
            == .corruptCentralDirectory)
        // A huge claimed directory is refused by the cap before anything is read.
        #expect(thrownError { _ = try ZIPArchive(data: eocd(entries: 1, size: 0xFFFF_FFFE, offset: 0xFFFF_FFFE)) } as? ZIPError
            == .centralDirectoryTooLarge(size: 0xFFFF_FFFE, limit: 64 << 20))
        // A split archive.
        #expect(thrownError { _ = try ZIPArchive(data: eocd(entries: 0, size: 0, offset: 0, disk: 1)) } as? ZIPError
            == .multiDiskArchive)
        // An empty archive is fine.
        #expect(try ZIPArchive(data: eocd(entries: 0, size: 0, offset: 0)).entries.isEmpty)
        // Central entry whose name length runs past the directory.
        var bad = TestZIP([TestZIPEntry("a.txt", "a")]).build()
        let directoryStart = 30 + 5 + 1
        bad[directoryStart + 28] = 0xFF
        bad[directoryStart + 29] = 0xFF
        #expect(thrownError { _ = try ZIPArchive(data: bad) } as? ZIPError == .corruptCentralDirectory)
        // Local header offset pointing at garbage or past the end.
        var offsetLie = TestZIP([TestZIPEntry("a.txt", "a"), TestZIPEntry("b.txt", "b")]).build()
        let secondCentral = try #require(offsetLie.lastRange(of: Data("b.txt".utf8))).lowerBound - 46
        offsetLie.replaceSubrange((secondCentral + 42)..<(secondCentral + 46), with: [0xF0, 0xFF, 0xFF, 0x7F])
        let lying = try ZIPArchive(data: offsetLie)
        #expect(thrownError { _ = try lying.data(at: "b.txt", maxSize: 10) } as? ZIPError == .truncated)
        offsetLie.replaceSubrange((secondCentral + 42)..<(secondCentral + 46), with: [3, 0, 0, 0])
        #expect(thrownError { _ = try ZIPArchive(data: offsetLie).data(at: "b.txt", maxSize: 10) } as? ZIPError
            == .corruptLocalHeader(path: "b.txt"))
    }

    @Test func fuzzedArchivesNeverTrap() throws {
        var zip = TestZIP([
            TestZIPEntry("mimetype", "application/epub+zip"),
            TestZIPEntry("big.txt", Self.bigText.prefix(20_000), method: .deflate),
            TestZIPEntry("dir/", Data()),
            TestZIPEntry("dir/s.txt", "stored text"),
        ])
        zip.entries[3].zip64 = true
        zip.zip64EOCD = true
        let original = zip.build()
        var generator = SeededGenerator(state: 42)
        var opened = 0
        for _ in 0..<1500 {
            var mutated = original
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let index = Int.random(in: 0..<mutated.count, using: &generator)
                mutated[index] = UInt8.random(in: 0...255, using: &generator)
            }
            guard let archive = try? ZIPArchive(data: mutated, limits: .init(maxTotalUncompressedSize: 1 << 30)) else { continue }
            opened += 1
            for entry in archive.entries {
                _ = try? archive.data(for: entry, maxSize: 1 << 20)
                try? archive.read(entry, chunkSize: 512) { _ in }
            }
        }
        #expect(opened > 0)
    }
}

private extension Data {
    func lastRange(of needle: Data) -> Range<Int>? {
        range(of: needle, options: .backwards).map { $0.lowerBound..<$0.upperBound }
    }
}
