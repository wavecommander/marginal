import Foundation
import zlib

// Constants and byte helpers for the subset of the ZIP format (PKWARE APPNOTE 6.3) this package
// reads and writes: stored entries only, UTF-8 names, ZIP64 extensions, a single "disk".

enum ZipConstants {
    static let localHeaderSignature: UInt32 = 0x0403_4b50
    static let centralHeaderSignature: UInt32 = 0x0201_4b50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4b50
    static let zip64LocatorSignature: UInt32 = 0x0706_4b50

    static let localHeaderSize = 30
    static let centralHeaderSize = 46
    static let endOfCentralDirectorySize = 22
    static let zip64EndOfCentralDirectorySize = 56
    static let zip64LocatorSize = 20

    /// Header ID of the ZIP64 extended-information extra field.
    static let zip64ExtraID: UInt16 = 0x0001

    /// Version needed to extract: 2.0 for plain stored entries, 4.5 when ZIP64 is used.
    static let versionDefault: UInt16 = 20
    static let versionZip64: UInt16 = 45
    /// "Version made by" high byte 3 = Unix, so `external attributes` carry a file mode.
    static let madeByUnix: UInt16 = 3 << 8

    /// General-purpose flag bits.
    static let flagEncrypted: UInt16 = 1 << 0
    static let flagStrongEncryption: UInt16 = 1 << 6
    static let flagUTF8: UInt16 = 1 << 11

    /// Unix mode `-rw-r--r--` (regular file) in the high 16 bits of the external attributes.
    static let externalAttributesFile: UInt32 = (0o100644 as UInt32) << 16

    static let max16: UInt64 = 0xFFFF
    static let max32: UInt64 = 0xFFFF_FFFF
}

/// Rules for entry names, shared by the writer (which refuses to write a name the reader would
/// refuse) and the reader (which refuses names that could escape an extraction directory).
enum ZipEntryName {
    /// Throws `unsafeEntryName` unless `name` is a plain relative path: not empty, no leading
    /// `/`, no backslash or NUL, and no empty, `.` or `..` component. A single trailing `/`
    /// (a directory entry) is accepted only when `allowDirectory` is set.
    static func validate(_ name: String, allowDirectory: Bool) throws {
        var path = Substring(name)
        if allowDirectory, path.hasSuffix("/") { path = path.dropLast() }
        let unsafe = BackupError.unsafeEntryName(name: name)
        guard !path.isEmpty, !path.hasPrefix("/") else { throw unsafe }
        guard !path.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\0" }) else { throw unsafe }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else { throw unsafe }
        }
        guard name.utf8.count <= Int(ZipConstants.max16) else { throw unsafe }
    }
}

/// CRC-32 (the ZIP polynomial) from zlib, fed incrementally.
struct CRC32 {
    private(set) var value: UInt32 = 0

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        var remaining = bytes.count
        var pointer = base.assumingMemoryBound(to: Bytef.self)
        var crc = uLong(value)
        // zlib's length parameter is a 32-bit uInt; feed very large buffers in pieces.
        while remaining > 0 {
            let piece = min(remaining, Int(UInt32.max))
            crc = zlib.crc32(crc, pointer, uInt(piece))
            pointer += piece
            remaining -= piece
        }
        value = UInt32(truncatingIfNeeded: crc)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }
}

/// Little-endian byte building.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u16(_ value: UInt16) { append(value) }
    mutating func u32(_ value: UInt32) { append(value) }
    mutating func u64(_ value: UInt64) { append(value) }
    mutating func bytes(_ value: Data) { data.append(value) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Bounds-checked little-endian reading of untrusted bytes: every read past the end throws
/// `archiveDamaged` instead of trapping.
struct ByteReader {
    let data: Data
    private(set) var position: Int

    init(_ data: Data, at position: Int = 0) {
        self.data = data
        self.position = position
    }

    var remaining: Int { data.count - position }

    mutating func u16() throws -> UInt16 { try read(UInt16.self) }
    mutating func u32() throws -> UInt32 { try read(UInt32.self) }
    mutating func u64() throws -> UInt64 { try read(UInt64.self) }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw BackupError.archiveDamaged(detail: "record runs past its end") }
        let start = data.startIndex + position
        position += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw BackupError.archiveDamaged(detail: "record runs past its end") }
        position += count
    }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= remaining else { throw BackupError.archiveDamaged(detail: "record runs past its end") }
        var value: T = 0
        let start = data.startIndex + position
        withUnsafeMutableBytes(of: &value) { target in
            data.copyBytes(to: target.bindMemory(to: UInt8.self), from: start..<(start + size))
        }
        position += size
        return T(littleEndian: value)
    }
}

/// MS-DOS date and time fields, in UTC so an archive's bytes do not depend on the time zone of
/// the device that wrote it. Clamped to the representable range 1980–2107.
struct DOSDateTime {
    let date: UInt16
    let time: UInt16

    init(_ value: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        var year = parts.year ?? 1980
        var month = parts.month ?? 1, day = parts.day ?? 1
        var hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0
        if year < 1980 { (year, month, day, hour, minute, second) = (1980, 1, 1, 0, 0, 0) }
        if year > 2107 { (year, month, day, hour, minute, second) = (2107, 12, 31, 23, 59, 58) }
        date = UInt16((year - 1980) << 9 | month << 5 | day)
        time = UInt16(hour << 11 | minute << 5 | second / 2)
    }
}
