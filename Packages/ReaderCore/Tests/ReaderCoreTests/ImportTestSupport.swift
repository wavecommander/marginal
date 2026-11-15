import Compression
import Foundation
@testable import ReaderCore

/// One entry for `TestZIP`. The `declared…` overrides write lies into both headers.
struct TestZIPEntry {
    enum Method { case stored, deflate, raw(UInt16) }

    var rawName: [UInt8]
    var data: Data
    var method: Method = .stored
    var flags: UInt16 = 0
    var declaredCRC: UInt32?
    var declaredUncompressedSize: UInt64?
    var declaredCompressedSize: UInt64?
    /// Write saturated 32-bit fields and a ZIP64 extra field.
    var zip64 = false

    init(_ name: String, _ data: Data, method: Method = .stored) {
        rawName = Array(name.utf8)
        self.data = data
        self.method = method
    }

    init(_ name: String, _ text: String, method: Method = .stored) {
        self.init(name, Data(text.utf8), method: method)
    }

    init(rawName: [UInt8], _ data: Data) {
        self.rawName = rawName
        self.data = data
    }
}

/// A tiny ZIP writer for fixtures: stored and deflate entries, optional ZIP64 records,
/// comments, and hooks for writing lies.
struct TestZIP {
    var entries: [TestZIPEntry]
    var comment = Data()
    /// Write a ZIP64 EOCD record and locator (with saturated fields in the classic EOCD).
    var zip64EOCD = false
    var declaredEntryCount: UInt16?

    init(_ entries: [TestZIPEntry]) { self.entries = entries }

    func build() -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt64(out.count)
            let payload: Data
            let method: UInt16
            switch entry.method {
            case .stored: payload = entry.data; method = 0
            case .deflate: payload = deflate(entry.data); method = 8
            case let .raw(value): payload = entry.data; method = value
            }
            let crc = entry.declaredCRC ?? CRC32.checksum(entry.data)
            let usize = entry.declaredUncompressedSize ?? UInt64(entry.data.count)
            let csize = entry.declaredCompressedSize ?? UInt64(payload.count)
            let isDirectory = entry.rawName.last == UInt8(ascii: "/")

            var localExtra = Data()
            if entry.zip64 {
                localExtra.le16(0x0001); localExtra.le16(16); localExtra.le64(usize); localExtra.le64(csize)
            }
            out.le32(0x0403_4B50)
            out.le16(entry.zip64 ? 45 : 20)
            out.le16(entry.flags)
            out.le16(method)
            out.le16(0); out.le16(0x21)
            out.le32(crc)
            out.le32(entry.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: csize))
            out.le32(entry.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: usize))
            out.le16(UInt16(entry.rawName.count))
            out.le16(UInt16(localExtra.count))
            out.append(contentsOf: entry.rawName)
            out.append(localExtra)
            out.append(payload)

            var centralExtra = Data()
            if entry.zip64 {
                centralExtra.le16(0x0001); centralExtra.le16(24)
                centralExtra.le64(usize); centralExtra.le64(csize); centralExtra.le64(offset)
            }
            central.le32(0x0201_4B50)
            central.le16(0x031E)
            central.le16(entry.zip64 ? 45 : 20)
            central.le16(entry.flags)
            central.le16(method)
            central.le16(0); central.le16(0x21)
            central.le32(crc)
            central.le32(entry.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: csize))
            central.le32(entry.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: usize))
            central.le16(UInt16(entry.rawName.count))
            central.le16(UInt16(centralExtra.count))
            central.le16(0)  // comment
            central.le16(0)  // disk
            central.le16(0)  // internal attributes
            central.le32(isDirectory ? (0o040755 << 16 | 0x10) : (0o100644 << 16))
            central.le32(entry.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: offset))
            central.append(contentsOf: entry.rawName)
            central.append(centralExtra)
        }
        let directoryOffset = UInt64(out.count)
        out.append(central)
        let count = UInt64(entries.count)
        if zip64EOCD {
            let recordOffset = UInt64(out.count)
            out.le32(0x0606_4B50)
            out.le64(44)
            out.le16(45); out.le16(45)
            out.le32(0); out.le32(0)
            out.le64(count); out.le64(count)
            out.le64(UInt64(central.count)); out.le64(directoryOffset)
            out.le32(0x0706_4B50)
            out.le32(0)
            out.le64(recordOffset)
            out.le32(1)
        }
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        let entryCount = declaredEntryCount ?? (zip64EOCD ? 0xFFFF : UInt16(count))
        out.le16(entryCount); out.le16(entryCount)
        out.le32(zip64EOCD ? 0xFFFF_FFFF : UInt32(central.count))
        out.le32(zip64EOCD ? 0xFFFF_FFFF : UInt32(directoryOffset))
        out.le16(UInt16(comment.count))
        out.append(comment)
        return out
    }
}

/// Raw DEFLATE (what ZIP method 8 holds) via the Compression framework.
func deflate(_ data: Data) -> Data {
    let capacity = data.count + 1024
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { dst in
        data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    precondition(written > 0, "deflate failed")
    return output.prefix(written)
}

extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// Stored text entries in order.
func zipData(_ files: [(String, String)], comment: String = "") -> Data {
    var zip = TestZIP(files.map { TestZIPEntry($0.0, $0.1) })
    zip.comment = Data(comment.utf8)
    return zip.build()
}

/// An EPUB: a stored `mimetype` first, then the files in order.
func epubData(_ files: [(String, String)], mimetype: Bool = true) -> Data {
    let entries = (mimetype ? [TestZIPEntry("mimetype", "application/epub+zip")] : [])
        + files.map { TestZIPEntry($0.0, $0.1, method: .deflate) }
    return TestZIP(entries).build()
}

func container(_ opfPath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
}

/// Deterministic pseudo-random bytes.
func noise(_ count: Int, seed: UInt64) -> Data {
    var generator = SeededGenerator(state: seed)
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

/// A temporary directory removed when the value is released.
final class TempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderCoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, _ data: Data) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
        return file
    }

    @discardableResult
    func directory(_ name: String) -> URL {
        let dir = url.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The error `body` throws, or `nil`.
func thrownError(_ body: () throws -> Void) -> Error? {
    do { try body(); return nil } catch { return error }
}
