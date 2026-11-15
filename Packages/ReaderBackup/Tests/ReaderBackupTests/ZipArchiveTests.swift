import Foundation
import Testing
@testable import ReaderBackup

struct ZipArchiveTests {
    /// Writes a sample archive: empty data, empty file, small data, a multi-chunk file and a
    /// Unicode name. Returns the expected contents by name.
    @discardableResult
    func writeSample(to url: URL, in dir: TemporaryDirectory, forceZIP64: Bool = false) throws -> [String: Data] {
        let big = pseudoRandomData(count: multiChunkSize, seed: 7)
        let bigURL = try dir.file("source/big.bin", big)
        let emptyURL = try dir.file("source/empty.bin", Data())
        let writer = try ZipArchiveWriter(url: url, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        writer.forceZIP64 = forceZIP64
        let unicode = "notes/Ünïcødé 笔记 📚.txt"
        var expected: [String: Data] = [:]
        try writer.addEntry(named: "empty-data", data: Data())
        expected["empty-data"] = Data()
        try writer.addEntry(named: "dir/empty-file", contentsOf: emptyURL)
        expected["dir/empty-file"] = Data()
        try writer.addEntry(named: "manifest.json", data: Data(#"{"hello":"world"}"#.utf8))
        expected["manifest.json"] = Data(#"{"hello":"world"}"#.utf8)
        let digest = try writer.addEntry(named: "dir/sub/big.bin", contentsOf: bigURL)
        #expect(digest == ContentDigest(sha256: ContentHash.sha256(of: big), size: Int64(big.count)))
        expected["dir/sub/big.bin"] = big
        try writer.addEntry(named: unicode, data: Data("ink".utf8))
        expected[unicode] = Data("ink".utf8)
        try writer.finish()
        return expected
    }

    func verifyReads(_ url: URL, expected: [String: Data], in dir: TemporaryDirectory) throws {
        let reader = try ZipArchiveReader(url: url)
        #expect(reader.entries.map(\.name) == ["empty-data", "dir/empty-file", "manifest.json", "dir/sub/big.bin", "notes/Ünïcødé 笔记 📚.txt"])
        for (name, data) in expected {
            let entry = try #require(reader.entry(named: name))
            #expect(entry.size == Int64(data.count))
            #expect(try reader.data(of: entry) == data)
            let out = dir.url.appendingPathComponent("out-\(UUID().uuidString)")
            let digest = try reader.extract(entry, to: out)
            #expect(try Data(contentsOf: out) == data)
            #expect(digest.sha256 == ContentHash.sha256(of: data))
        }
    }

    @Test func roundTrip() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("a.zip")
        let expected = try writeSample(to: url, in: dir)
        try verifyReads(url, expected: expected, in: dir)
        // Nothing that needs ZIP64, so none is written.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x06])) == nil)
    }

    @Test func forcedZIP64RoundTrip() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("a64.zip")
        let expected = try writeSample(to: url, in: dir, forceZIP64: true)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x06])) != nil, "ZIP64 end record")
        #expect(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x07])) != nil, "ZIP64 locator")
        try verifyReads(url, expected: expected, in: dir)
    }

    @Test func dataLargerThanTheLimitIsRefused() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("a.zip")
        try writeSample(to: url, in: dir)
        let reader = try ZipArchiveReader(url: url)
        let entry = try #require(reader.entry(named: "dir/sub/big.bin"))
        #expect(throws: BackupError.entryTooLarge(name: "dir/sub/big.bin")) { try reader.data(of: entry, maximumSize: 1024) }
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func systemUnzipAcceptsOurArchives(forceZIP64: Bool) throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("system.zip")
        let expected = try writeSample(to: url, in: dir, forceZIP64: forceZIP64)
        let test = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0, "\(test.output)")
        #expect(test.output.contains("No errors detected"), "\(test.output)")
        let info = try run("/usr/bin/zipinfo", [url.path])
        #expect(info.status == 0, "\(info.output)")
        #expect(info.output.contains("5 files"), "\(info.output)")
        // Extract with the system tool and compare bytes.
        let out = dir.url.appendingPathComponent("unzipped", isDirectory: true)
        let unzip = try run("/usr/bin/unzip", ["-q", url.path, "-d", out.path])
        #expect(unzip.status == 0, "\(unzip.output)")
        for (name, data) in expected {
            #expect(try Data(contentsOf: out.appendingPathComponent(name)) == data, "\(name)")
        }
    }

    @Test func readsAnArchiveMadeBySystemZip() throws {
        let dir = try TemporaryDirectory()
        let big = pseudoRandomData(count: multiChunkSize, seed: 3)
        try dir.file("src/books/A/ink/1.drawing", Data("one".utf8))
        try dir.file("src/books/A/big.bin", big)
        try dir.file("src/manifest.json", Data("{}".utf8))
        try dir.file("src/empty", Data())
        let url = dir.url.appendingPathComponent("system-made.zip")
        let made = try run("/usr/bin/zip", ["-0", "-r", "-X", "-q", url.path, "."], in: dir.url.appendingPathComponent("src"))
        #expect(made.status == 0, "\(made.output)")
        let reader = try ZipArchiveReader(url: url)
        let files = reader.entries.filter { !$0.isDirectory }.map(\.name).sorted()
        #expect(files == ["books/A/big.bin", "books/A/ink/1.drawing", "empty", "manifest.json"])
        #expect(reader.entries.contains { $0.isDirectory }, "zip -r writes directory entries")
        #expect(try reader.data(of: #require(reader.entry(named: "books/A/ink/1.drawing"))) == Data("one".utf8))
        let out = dir.url.appendingPathComponent("big.out")
        try reader.extract(#require(reader.entry(named: "books/A/big.bin")), to: out)
        #expect(try Data(contentsOf: out) == big)
    }

    @Test func compressedArchiveFromSystemZipIsRefused() throws {
        let dir = try TemporaryDirectory()
        try dir.file("src/text.txt", Data(String(repeating: "compress me ", count: 1000).utf8))
        let url = dir.url.appendingPathComponent("deflated.zip")
        let made = try run("/usr/bin/zip", ["-9", "-q", url.path, "text.txt"], in: dir.url.appendingPathComponent("src"))
        #expect(made.status == 0, "\(made.output)")
        #expect(throws: BackupError.compressedEntry(name: "text.txt")) { try ZipArchiveReader(url: url) }
    }
    #endif

    // MARK: - Hostile and damaged input

    /// A small archive with entries `names` (contents = name bytes).
    func smallArchive(_ names: [String], in dir: TemporaryDirectory) throws -> URL {
        let url = dir.url.appendingPathComponent("small-\(UUID().uuidString).zip")
        let writer = try ZipArchiveWriter(url: url, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        for name in names { try writer.addEntry(named: name, data: Data("contents of \(name)".utf8)) }
        try writer.finish()
        return url
    }

    @Test func truncatedArchivesAreRefused() throws {
        let dir = try TemporaryDirectory()
        let url = try smallArchive(["a.txt", "b/c.txt"], in: dir)
        let full = try Data(contentsOf: url)
        for length in [0, 1, 21, full.count / 2, full.count - 22, full.count - 1] {
            let cut = dir.url.appendingPathComponent("cut-\(length).zip")
            try full.prefix(length).write(to: cut)
            #expect(throws: BackupError.self, "length \(length)") { try ZipArchiveReader(url: cut) }
        }
        let cut = dir.url.appendingPathComponent("cut-last.zip")
        try full.dropLast().write(to: cut)
        #expect(throws: BackupError.archiveIncomplete) { try ZipArchiveReader(url: cut) }
    }

    @Test func flippedDataByteFailsTheChecksum() throws {
        let dir = try TemporaryDirectory()
        let url = try smallArchive(["a.txt"], in: dir)
        // The entry's data starts after the 30-byte local header and the 5-byte name.
        try flipByte(url, at: 30 + 5 + 3)
        let reader = try ZipArchiveReader(url: url)
        let entry = try #require(reader.entry(named: "a.txt"))
        #expect(throws: BackupError.entryChecksumMismatch(name: "a.txt")) { try reader.data(of: entry) }
        let out = dir.url.appendingPathComponent("a.out")
        #expect(throws: BackupError.entryChecksumMismatch(name: "a.txt")) { try reader.extract(entry, to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(dir.allPaths().filter { $0.hasSuffix(".partial") }.isEmpty)
    }

    /// Every single-byte flip in the central directory and end record either throws a
    /// `BackupError` or still reads back exactly the original bytes (fields such as times and
    /// attributes are not checked); it never crashes or returns wrong data.
    @Test(arguments: [false, true])
    func flippedDirectoryBytesNeverYieldWrongData(forceZIP64: Bool) throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("base.zip")
        let writer = try ZipArchiveWriter(url: url, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        writer.forceZIP64 = forceZIP64
        try writer.addEntry(named: "one.txt", data: Data("first entry".utf8))
        try writer.addEntry(named: "dir/two.txt", data: Data("second entry".utf8))
        try writer.finish()
        let original = try Data(contentsOf: url)
        let directoryStart = try centralDirectoryOffset(of: url)
        var detected = 0
        for offset in directoryStart..<original.count {
            var damaged = original
            damaged[offset] ^= 0xFF
            let copy = dir.url.appendingPathComponent("flip.zip")
            try damaged.write(to: copy)
            do {
                let reader = try ZipArchiveReader(url: copy)
                let contents = try reader.entries.map { try reader.data(of: $0) }
                #expect(reader.entries.map(\.name) == ["one.txt", "dir/two.txt"], "offset \(offset)")
                #expect(contents == [Data("first entry".utf8), Data("second entry".utf8)], "offset \(offset)")
            } catch is BackupError {
                detected += 1
            }
        }
        #expect(detected > (original.count - directoryStart) / 2)
    }

    @Test func compressedAndEncryptedEntriesAreRefused() throws {
        let dir = try TemporaryDirectory()
        // Method field (offset 10 in the central header) set to 8, deflate.
        let compressed = try smallArchive(["a.txt"], in: dir)
        let directory = try centralDirectoryOffset(of: compressed)
        var data = try Data(contentsOf: compressed)
        data[directory + 10] = 8
        try data.write(to: compressed)
        #expect(throws: BackupError.compressedEntry(name: "a.txt")) { try ZipArchiveReader(url: compressed) }

        // Flag bit 0 (offset 8 in the central header), encrypted.
        let encrypted = try smallArchive(["a.txt"], in: dir)
        data = try Data(contentsOf: encrypted)
        data[directory + 8] |= 1
        try data.write(to: encrypted)
        #expect(throws: BackupError.encryptedEntry(name: "a.txt")) { try ZipArchiveReader(url: encrypted) }
    }

    @Test(arguments: [
        ("zz/evil", "../evil"),
        ("zzzz/evil", "a/../evil"),
        ("Xabs", "/abs"),
        ("a_b", "a\\b"),
        ("a_b", "a\0b"),
        ("a/_/b", "a/./b"),
        ("a/_b", "a//b"),
    ])
    func unsafeNamesAreRefusedByTheReader(written: String, patched: String) throws {
        let dir = try TemporaryDirectory()
        let url = try smallArchive(["ok.txt", written], in: dir)
        // Patch the name in both the local and the central header (same length).
        let replaced = try patchFile(url, replacing: Data(written.utf8), with: Data(patched.utf8))
        #expect(replaced >= 2)
        #expect(throws: BackupError.unsafeEntryName(name: patched)) { try ZipArchiveReader(url: url) }
    }

    @Test(arguments: ["../evil", "/abs", "a\\b", "a\0b", "a/./b", "a//b", "", "dir/", "a/.."])
    func unsafeNamesAreRefusedByTheWriter(name: String) throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("w.zip")
        let writer = try ZipArchiveWriter(url: url)
        #expect(throws: BackupError.unsafeEntryName(name: name)) { try writer.addEntry(named: name, data: Data()) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "a failed writer removes its output")
        #expect(throws: BackupError.writerClosed) { try writer.addEntry(named: "ok", data: Data()) }
    }

    @Test func duplicateNamesAreRefused() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("dup.zip")
        let writer = try ZipArchiveWriter(url: url)
        try writer.addEntry(named: "same", data: Data())
        #expect(throws: BackupError.duplicateEntryName(name: "same")) { try writer.addEntry(named: "same", data: Data("x".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let patched = try smallArchive(["dup1", "dup2"], in: dir)
        try patchFile(patched, replacing: Data("dup2".utf8), with: Data("dup1".utf8))
        #expect(throws: BackupError.duplicateEntryName(name: "dup1")) { try ZipArchiveReader(url: patched) }
    }

    @Test func notAZipIsRefused() throws {
        let dir = try TemporaryDirectory()
        let url = try dir.file("plain.zip", Data(String(repeating: "not a zip ", count: 100).utf8))
        #expect(throws: BackupError.archiveIncomplete) { try ZipArchiveReader(url: url) }
    }

    // MARK: - Failure and cancellation clean-up

    @Test func cancellationRemovesThePartialArchive() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("big.bin", pseudoRandomData(count: multiChunkSize, seed: 1))
        let url = dir.url.appendingPathComponent("cancelled.zip")
        let error = await runCancelling { cancel in
            let writer = try ZipArchiveWriter(url: url)
            try writer.addEntry(named: "first", data: Data("x".utf8))
            try writer.addEntry(named: "big.bin", contentsOf: source, progress: { fraction in
                if fraction > 0 { cancel() }
            })
            try writer.finish()
        }
        #expect(error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aMissingSourceRemovesThePartialArchive() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("failed.zip")
        let writer = try ZipArchiveWriter(url: url)
        try writer.addEntry(named: "first", data: Data("x".utf8))
        #expect(throws: BackupError.fileNotFound(name: "nope.bin")) {
            try writer.addEntry(named: "nope", contentsOf: dir.url.appendingPathComponent("nope.bin"))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aWriterReleasedUnfinishedRemovesItsOutput() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("released.zip")
        do {
            let writer = try ZipArchiveWriter(url: url)
            try writer.addEntry(named: "first", data: Data("x".utf8))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelledExtractionLeavesNothing() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("big.bin", pseudoRandomData(count: multiChunkSize, seed: 2))
        let url = dir.url.appendingPathComponent("a.zip")
        let writer = try ZipArchiveWriter(url: url)
        try writer.addEntry(named: "big.bin", contentsOf: source)
        try writer.finish()
        let out = dir.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let reader = try ZipArchiveReader(url: url)
        let entry = try #require(reader.entry(named: "big.bin"))
        let error = await runCancelling { cancel in
            try reader.extract(entry, to: out.appendingPathComponent("big.bin"), progress: { if $0 > 0 { cancel() } })
        }
        #expect(error is CancellationError)
        #expect(dir.allPaths(under: "out").isEmpty)
    }

    @Test func dosTimestampIsUTCAndClamped() {
        let date = DOSDateTime(Date(timeIntervalSince1970: 1_700_000_000)) // 2023-11-14 22:13:20 UTC
        #expect(date.date == UInt16((2023 - 1980) << 9 | 11 << 5 | 14))
        #expect(date.time == UInt16(22 << 11 | 13 << 5 | 10))
        let early = DOSDateTime(Date(timeIntervalSince1970: 0))
        #expect(early.date == UInt16(0 << 9 | 1 << 5 | 1))
        #expect(early.time == 0)
    }
}
