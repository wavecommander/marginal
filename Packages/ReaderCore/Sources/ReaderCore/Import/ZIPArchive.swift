import Compression
import Foundation

/// Why a ZIP archive or one of its entries could not be read. Archive-level errors come from
/// `ZIPArchive.init`; entry-level errors from reading that entry (other entries stay readable).
public enum ZIPError: Error, Sendable, Hashable {
    // Archive level.
    /// No end-of-central-directory record: not a ZIP archive.
    case notAZIPArchive
    /// The file ends before a structure it declares (archive or entry).
    case truncated
    /// A split ("spanned") archive; only single-file archives are read.
    case multiDiskArchive
    /// The central directory is inconsistent with itself or with the file.
    case corruptCentralDirectory
    case tooManyEntries(declared: UInt64, limit: Int)
    case centralDirectoryTooLarge(size: UInt64, limit: UInt64)
    case totalUncompressedSizeTooLarge(limit: UInt64)
    /// The file could not be opened or read.
    case readFailed(reason: String)

    // Entry level.
    case entryNotFound(path: String)
    /// The name is absolute, climbs out with `..` (with `/` or `\`), names a drive, is empty
    /// or contains NUL. Such entries are listed (flagged `hasUnsafePath`) but never read.
    case unsafeEntryName(path: String)
    case encryptedEntry(path: String)
    /// Only stored (0) and deflate (8) are supported.
    case unsupportedCompressionMethod(path: String, method: UInt16)
    /// The declared uncompressed size is over the caller's `maxSize`.
    case entryTooLarge(path: String, size: UInt64, limit: UInt64)
    /// The declared sizes are impossible for the method (e.g. a deflate ratio over ~1032:1).
    case implausibleCompressionRatio(path: String)
    case corruptLocalHeader(path: String)
    /// The compressed data is not valid for its method.
    case corruptEntryData(path: String)
    /// Inflating produced more than the declared uncompressed size; inflation was stopped.
    case uncompressedSizeExceeded(path: String)
    /// The data ended at a different size than declared.
    case sizeMismatch(path: String)
    case crcMismatch(path: String, expected: UInt32, actual: UInt32)
}

/// One entry of a ZIP archive's central directory.
public struct ZIPEntry: Sendable, Hashable {
    /// The entry name as stored (UTF-8 when valid, otherwise decoded as CP437), with `/`
    /// separators; never normalised. Directories end with `/`.
    public let path: String
    /// Position in the central directory.
    public let index: Int
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    /// 0 = stored, 8 = deflate; anything else cannot be read.
    public let compressionMethod: UInt16
    public let crc32: UInt32
    public let localHeaderOffset: UInt64
    /// General-purpose bit flags.
    public let flags: UInt16
    public let isDirectory: Bool
    /// See `ZIPError.unsafeEntryName`.
    public let hasUnsafePath: Bool

    public var isEncrypted: Bool { flags & 0x0001 != 0 }
    public var isCompressionSupported: Bool { compressionMethod == 0 || compressionMethod == 8 }
    /// The last path component (without a trailing `/`).
    public var fileName: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    public init(path: String, index: Int, compressedSize: UInt64, uncompressedSize: UInt64,
                compressionMethod: UInt16, crc32: UInt32, localHeaderOffset: UInt64, flags: UInt16,
                isDirectory: Bool, hasUnsafePath: Bool) {
        self.path = path
        self.index = index
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.compressionMethod = compressionMethod
        self.crc32 = crc32
        self.localHeaderOffset = localHeaderOffset
        self.flags = flags
        self.isDirectory = isDirectory
        self.hasUnsafePath = hasUnsafePath
    }
}

/// A small read-only ZIP reader (stored and deflate, ZIP64) over a file handle or bytes in
/// memory. Opening reads only the end records and the central directory; entries are read
/// one at a time, in full (`data(for:maxSize:)`) or in chunks (`read(_:chunkSize:_:)`).
/// Every read verifies the size and CRC-32. Hostile input throws `ZIPError`, never traps.
///
/// Not thread-safe: use an archive from one task at a time.
public final class ZIPArchive {
    /// Resource caps checked when the archive is opened.
    public struct Limits: Sendable, Hashable {
        public var maxEntryCount: Int
        /// Cap on the sum of all entries' declared uncompressed sizes.
        public var maxTotalUncompressedSize: UInt64
        public var maxCentralDirectorySize: UInt64

        public init(maxEntryCount: Int = 100_000,
                    maxTotalUncompressedSize: UInt64 = 4 << 30,
                    maxCentralDirectorySize: UInt64 = 64 << 20) {
            self.maxEntryCount = maxEntryCount
            self.maxTotalUncompressedSize = maxTotalUncompressedSize
            self.maxCentralDirectorySize = maxCentralDirectorySize
        }

        public static let `default` = Limits()
    }

    /// Entries in central-directory order.
    public let entries: [ZIPEntry]
    /// The archive comment (UTF-8 when valid, otherwise CP437).
    public let comment: String
    public let limits: Limits

    private let source: ZIPByteSource
    private let indexByPath: [String: Int]
    /// Entry data must end at or before this offset (the start of the central directory).
    private let dataLimit: UInt64

    /// Opens the archive at `url`, reading only its end records and central directory.
    public convenience init(url: URL, limits: Limits = .default) throws {
        try self.init(source: try FileByteSource(url: url), limits: limits)
    }

    /// Reads an archive held in memory.
    public convenience init(data: Data, limits: Limits = .default) throws {
        try self.init(source: DataByteSource(data: data), limits: limits)
    }

    init(source: ZIPByteSource, limits: Limits) throws {
        self.source = source
        self.limits = limits
        let directory = try CentralDirectory.read(from: source, limits: limits)
        entries = directory.entries
        comment = directory.comment
        dataLimit = directory.offset
        var index: [String: Int] = [:]
        for entry in entries where index[entry.path] == nil { index[entry.path] = entry.index }
        indexByPath = index
    }

    /// The first entry with exactly this path, if any.
    public func entry(at path: String) -> ZIPEntry? {
        indexByPath[path].map { entries[$0] }
    }

    public func contains(_ path: String) -> Bool { indexByPath[path] != nil }

    /// The whole entry, verified against its declared size and CRC-32. Throws `entryTooLarge`
    /// without reading when the declared size is over `maxSize`.
    public func data(for entry: ZIPEntry, maxSize: UInt64) throws -> Data {
        guard entry.uncompressedSize <= maxSize else {
            throw ZIPError.entryTooLarge(path: entry.path, size: entry.uncompressedSize, limit: maxSize)
        }
        var result = Data()
        result.reserveCapacity(Int(min(entry.uncompressedSize, 64 << 20)))
        try read(entry) { result.append($0) }
        return result
    }

    /// The whole entry at `path` (see `data(for:maxSize:)`).
    public func data(at path: String, maxSize: UInt64) throws -> Data {
        guard let entry = entry(at: path) else { throw ZIPError.entryNotFound(path: path) }
        return try data(for: entry, maxSize: maxSize)
    }

    /// Streams the entry's uncompressed bytes to `body` in chunks of at most `chunkSize`, so a
    /// large entry is never held in memory whole. The size and CRC-32 are checked as the data
    /// arrives and at the end: if this throws, discard whatever `body` received.
    public func read(_ entry: ZIPEntry, chunkSize: Int = 64 * 1024, _ body: (Data) throws -> Void) throws {
        let chunkSize = min(max(chunkSize, 1), 16 << 20)
        try checkReadable(entry)
        let start = try dataStart(of: entry)
        var crc = CRC32()
        var produced: UInt64 = 0
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            let (total, overflow) = produced.addingReportingOverflow(UInt64(bytes.count))
            guard !overflow, total <= entry.uncompressedSize else {
                throw ZIPError.uncompressedSizeExceeded(path: entry.path)
            }
            produced = total
            crc.update(bytes)
            try body(Data(bytes))
        }
        switch entry.compressionMethod {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZIPError.sizeMismatch(path: entry.path) }
            var offset = start
            var remaining = entry.compressedSize
            while remaining > 0 {
                let count = Int(min(remaining, UInt64(chunkSize)))
                let chunk = try source.read(at: offset, count: count)
                try chunk.withUnsafeBytes { try emit($0) }
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
        default:
            try inflate(entry, from: start, outputChunk: chunkSize, emit: emit)
        }
        guard produced == entry.uncompressedSize else { throw ZIPError.sizeMismatch(path: entry.path) }
        guard crc.value == entry.crc32 else {
            throw ZIPError.crcMismatch(path: entry.path, expected: entry.crc32, actual: crc.value)
        }
    }

    // MARK: Entry data

    private func checkReadable(_ entry: ZIPEntry) throws {
        guard !entry.hasUnsafePath else { throw ZIPError.unsafeEntryName(path: entry.path) }
        guard !entry.isEncrypted else { throw ZIPError.encryptedEntry(path: entry.path) }
        guard entry.isCompressionSupported else {
            throw ZIPError.unsupportedCompressionMethod(path: entry.path, method: entry.compressionMethod)
        }
        if entry.compressionMethod == 8 {
            // Deflate cannot exceed ~1032:1; a larger declared size is a lie (or a bomb).
            let (bound, overflow) = entry.compressedSize.multipliedReportingOverflow(by: 1040)
            if !overflow, entry.uncompressedSize > bound + 4096 {
                throw ZIPError.implausibleCompressionRatio(path: entry.path)
            }
        }
    }

    /// The offset of the entry's data, after its local header; checks the data lies in the file.
    private func dataStart(of entry: ZIPEntry) throws -> UInt64 {
        let headerEnd = try checkedAdd(entry.localHeaderOffset, 30, or: ZIPError.corruptLocalHeader(path: entry.path))
        guard headerEnd <= source.length else { throw ZIPError.truncated }
        let header = [UInt8](try source.read(at: entry.localHeaderOffset, count: 30))
        var reader = ByteReader(header, failure: ZIPError.corruptLocalHeader(path: entry.path))
        guard try reader.u32() == Signature.localFileHeader else { throw ZIPError.corruptLocalHeader(path: entry.path) }
        try reader.skip(22)
        let nameLength = UInt64(try reader.u16())
        let extraLength = UInt64(try reader.u16())
        let failure = ZIPError.corruptLocalHeader(path: entry.path)
        let start = try checkedAdd(try checkedAdd(headerEnd, nameLength, or: failure), extraLength, or: failure)
        let end = try checkedAdd(start, entry.compressedSize, or: failure)
        guard end <= source.length else { throw ZIPError.truncated }
        guard end <= dataLimit else { throw ZIPError.corruptLocalHeader(path: entry.path) }
        return start
    }

    private func inflate(_ entry: ZIPEntry, from start: UInt64, outputChunk: Int,
                         emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZIPError.corruptEntryData(path: entry.path)
        }
        defer { compression_stream_destroy(stream) }

        let inputCapacity = 64 * 1024
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        defer { input.deallocate() }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunk)
        defer { output.deallocate() }

        var offset = start
        var remaining = entry.compressedSize
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = 0
        let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)
        while true {
            if stream.pointee.src_size == 0, remaining > 0 {
                let count = Int(min(remaining, UInt64(inputCapacity)))
                let chunk = try source.read(at: offset, count: count)
                chunk.copyBytes(to: input, count: count)
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = count
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
            let inputBefore = stream.pointee.src_size
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = outputChunk
            let status = compression_stream_process(stream, remaining == 0 ? finalize : 0)
            let produced = outputChunk - stream.pointee.dst_size
            if produced > 0 { try emit(UnsafeRawBufferPointer(start: output, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // No progress with nothing left to feed: the stream is cut short.
                if produced == 0, stream.pointee.src_size == inputBefore, remaining == 0 || inputBefore > 0 {
                    throw ZIPError.corruptEntryData(path: entry.path)
                }
            default:
                throw ZIPError.corruptEntryData(path: entry.path)
            }
        }
    }
}

// MARK: - Central directory

enum Signature {
    static let localFileHeader: UInt32 = 0x0403_4B50
    static let centralFileHeader: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
    static let zip64Locator: UInt32 = 0x0706_4B50
}

private struct CentralDirectory {
    var entries: [ZIPEntry]
    var comment: String
    var offset: UInt64

    static func read(from source: ZIPByteSource, limits: ZIPArchive.Limits) throws -> CentralDirectory {
        let length = source.length
        guard length >= 22 else { throw try looksLikeZIP(source) ? ZIPError.truncated : ZIPError.notAZIPArchive }

        // End of central directory: scan back through a possible comment (≤ 65,535 bytes).
        let tailCount = Int(min(length, 22 + 0xFFFF))
        let tailStart = length - UInt64(tailCount)
        let tail = [UInt8](try source.read(at: tailStart, count: tailCount))
        guard let eocdIndex = findEOCD(in: tail) else {
            throw try looksLikeZIP(source) ? ZIPError.truncated : ZIPError.notAZIPArchive
        }
        let eocdOffset = tailStart + UInt64(eocdIndex)
        var reader = ByteReader(tail, at: eocdIndex + 4, failure: .corruptCentralDirectory)
        var diskNumber = UInt32(try reader.u16())
        var directoryDisk = UInt32(try reader.u16())
        var entriesOnDisk = UInt64(try reader.u16())
        var entryCount = UInt64(try reader.u16())
        var directorySize = UInt64(try reader.u32())
        var directoryOffset = UInt64(try reader.u32())
        let commentLength = Int(try reader.u16())
        let commentBytes = tail[(eocdIndex + 22)..<min(tail.count, eocdIndex + 22 + commentLength)]
        let comment = ZIPText.decode(commentBytes)

        // ZIP64: a locator just before the EOCD points at the ZIP64 EOCD record.
        var directoryEnd = eocdOffset
        if eocdOffset >= 20 {
            let locator = [UInt8](try source.read(at: eocdOffset - 20, count: 20))
            var locatorReader = ByteReader(locator, failure: .corruptCentralDirectory)
            if try locatorReader.u32() == Signature.zip64Locator {
                _ = try locatorReader.u32()  // disk with the ZIP64 EOCD
                let recordOffset = try locatorReader.u64()
                guard let recordEnd = recordOffset.addingChecked(56), recordEnd <= eocdOffset - 20 else {
                    throw ZIPError.corruptCentralDirectory
                }
                let record = [UInt8](try source.read(at: recordOffset, count: 56))
                var recordReader = ByteReader(record, failure: .corruptCentralDirectory)
                guard try recordReader.u32() == Signature.zip64EndOfCentralDirectory else {
                    throw ZIPError.corruptCentralDirectory
                }
                try recordReader.skip(8 + 2 + 2)  // record size, versions
                diskNumber = try recordReader.u32()
                directoryDisk = try recordReader.u32()
                entriesOnDisk = try recordReader.u64()
                entryCount = try recordReader.u64()
                directorySize = try recordReader.u64()
                directoryOffset = try recordReader.u64()
                directoryEnd = recordOffset
            }
        }

        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == entryCount else { throw ZIPError.multiDiskArchive }
        guard entryCount <= UInt64(limits.maxEntryCount) else {
            throw ZIPError.tooManyEntries(declared: entryCount, limit: limits.maxEntryCount)
        }
        guard directorySize <= limits.maxCentralDirectorySize else {
            throw ZIPError.centralDirectoryTooLarge(size: directorySize, limit: limits.maxCentralDirectorySize)
        }
        guard let end = directoryOffset.addingChecked(directorySize), end <= directoryEnd else {
            throw ZIPError.corruptCentralDirectory
        }
        let (minimumSize, overflow) = entryCount.multipliedReportingOverflow(by: 46)
        guard !overflow, minimumSize <= directorySize else { throw ZIPError.corruptCentralDirectory }

        guard let directoryCount = Int(exactly: directorySize) else { throw ZIPError.corruptCentralDirectory }
        let bytes = [UInt8](try source.read(at: directoryOffset, count: directoryCount))
        var directory = ByteReader(bytes, failure: .corruptCentralDirectory)
        var entries: [ZIPEntry] = []
        entries.reserveCapacity(Int(entryCount))
        var total: UInt64 = 0
        for index in 0..<Int(entryCount) {
            let entry = try readEntry(&directory, index: index)
            guard let sum = total.addingChecked(entry.uncompressedSize), sum <= limits.maxTotalUncompressedSize else {
                throw ZIPError.totalUncompressedSizeTooLarge(limit: limits.maxTotalUncompressedSize)
            }
            total = sum
            entries.append(entry)
        }
        return CentralDirectory(entries: entries, comment: comment, offset: directoryOffset)
    }

    /// Prefers an EOCD whose comment runs exactly to the end of the file; falls back to the
    /// last plausible one (some writers append junk).
    private static func findEOCD(in tail: [UInt8]) -> Int? {
        var lenient: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                let commentLength = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
                if index + 22 + commentLength == tail.count { return index }
                if lenient == nil, index + 22 + commentLength <= tail.count { lenient = index }
            }
            index -= 1
        }
        return lenient
    }

    private static func looksLikeZIP(_ source: ZIPByteSource) throws -> Bool {
        guard source.length >= 4 else { return false }
        let head = [UInt8](try source.read(at: 0, count: 4))
        return head == [0x50, 0x4B, 0x03, 0x04]
    }

    private static func readEntry(_ reader: inout ByteReader, index: Int) throws -> ZIPEntry {
        guard try reader.u32() == Signature.centralFileHeader else { throw ZIPError.corruptCentralDirectory }
        let versionMadeBy = try reader.u16()
        _ = try reader.u16()  // version needed
        let flags = try reader.u16()
        let method = try reader.u16()
        try reader.skip(4)  // time, date
        let crc = try reader.u32()
        var compressedSize = UInt64(try reader.u32())
        var uncompressedSize = UInt64(try reader.u32())
        let nameLength = Int(try reader.u16())
        let extraLength = Int(try reader.u16())
        let commentLength = Int(try reader.u16())
        var diskStart = UInt32(try reader.u16())
        try reader.skip(2)  // internal attributes
        let externalAttributes = try reader.u32()
        var localHeaderOffset = UInt64(try reader.u32())
        let rawName = try reader.take(nameLength)
        let extra = try reader.take(extraLength)
        try reader.skip(commentLength)

        // ZIP64 extended information: only the fields whose 32-bit value is saturated, in order.
        var extraReader = ByteReader(Array(extra), failure: .corruptCentralDirectory)
        while extraReader.remaining >= 4 {
            let tag = try extraReader.u16()
            let size = Int(try extraReader.u16())
            let field = try extraReader.take(size)
            guard tag == 0x0001 else { continue }
            var zip64 = ByteReader(Array(field), failure: .corruptCentralDirectory)
            if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try zip64.u64() }
            if compressedSize == 0xFFFF_FFFF { compressedSize = try zip64.u64() }
            if localHeaderOffset == 0xFFFF_FFFF { localHeaderOffset = try zip64.u64() }
            if diskStart == 0xFFFF { diskStart = try zip64.u32() }
        }
        guard diskStart == 0 else { throw ZIPError.multiDiskArchive }

        let name = ZIPText.decode(rawName)
        let host = versionMadeBy >> 8
        let attributeSaysDirectory = (host == 0 && externalAttributes & 0x10 != 0)
            || (host == 3 && (externalAttributes >> 16) & 0o170000 == 0o040000)
        let isDirectory = name.hasSuffix("/") || (attributeSaysDirectory && uncompressedSize == 0 && compressedSize == 0)
        return ZIPEntry(path: name, index: index, compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                        compressionMethod: method, crc32: crc, localHeaderOffset: localHeaderOffset, flags: flags,
                        isDirectory: isDirectory, hasUnsafePath: ZIPText.isUnsafePath(raw: rawName, name: name))
    }
}

// MARK: - Names

enum ZIPText {
    /// UTF-8 when the bytes are valid UTF-8 (whether or not flag bit 11 says so), else CP437.
    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        if let string = String(bytes: bytes, encoding: .utf8) { return string }
        var result = String.UnicodeScalarView()
        for byte in bytes {
            if byte < 0x80 {
                result.append(Unicode.Scalar(byte))
            } else {
                result.append(cp437High[Int(byte - 0x80)])
            }
        }
        return String(result)
    }

    static func isUnsafePath(raw: ArraySlice<UInt8>, name: String) -> Bool {
        if raw.isEmpty || raw.contains(0) { return true }
        if name.hasPrefix("/") || name.hasPrefix("\\") { return true }
        let scalars = Array(name.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":", scalars[0].isASCII, scalars[0].properties.isAlphabetic { return true }
        let components = name.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        return components.contains("..")
    }

    /// Code page 437, bytes 0x80…0xFF.
    static let cp437High: [Unicode.Scalar] = {
        let rows: [String] = [
            "ÇüéâäàåçêëèïîìÄÅ", "ÉæÆôöòûùÿÖÜ¢£¥₧ƒ", "áíóúñÑªº¿⌐¬½¼¡«»", "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐",
            "└┴┬├─┼╞╟╚╔╩╦╠═╬╧", "╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀", "αßΓπΣσµτΦΘΩδ∞φε∩", "≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}",
        ]
        return rows.flatMap { Array($0.unicodeScalars) }
    }()
}

// MARK: - Byte sources

/// Random-access bytes. `read` returns exactly `count` bytes or throws.
protocol ZIPByteSource: AnyObject {
    var length: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

final class FileByteSource: ZIPByteSource {
    private let handle: FileHandle
    let length: UInt64

    init(url: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
            length = try handle.seekToEnd()
        } catch {
            throw ZIPError.readFailed(reason: error.localizedDescription)
        }
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, let end = offset.addingChecked(UInt64(count)), end <= length else { throw ZIPError.truncated }
        if count == 0 { return Data() }
        do {
            try handle.seek(toOffset: offset)
            var result = Data()
            while result.count < count {
                guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else { break }
                result.append(chunk)
            }
            guard result.count == count else { throw ZIPError.truncated }
            return result
        } catch let error as ZIPError {
            throw error
        } catch {
            throw ZIPError.readFailed(reason: error.localizedDescription)
        }
    }
}

final class DataByteSource: ZIPByteSource {
    private let data: Data
    var length: UInt64 { UInt64(data.count) }

    init(data: Data) { self.data = data }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, let end = offset.addingChecked(UInt64(count)), end <= length else { throw ZIPError.truncated }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<(start + count))
    }
}

// MARK: - Little-endian reading

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var position: Int
    private let failure: ZIPError

    init(_ bytes: [UInt8], at position: Int = 0, failure: ZIPError) {
        self.bytes = bytes
        self.position = position
        self.failure = failure
    }

    var remaining: Int { max(0, bytes.count - position) }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw failure }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        var value: UInt32 = 0
        for (shift, byte) in b.enumerated() { value |= UInt32(byte) << (8 * shift) }
        return value
    }

    mutating func u64() throws -> UInt64 {
        let b = try take(8)
        var value: UInt64 = 0
        for (shift, byte) in b.enumerated() { value |= UInt64(byte) << (8 * shift) }
        return value
    }
}

extension UInt64 {
    /// `self + other`, or `nil` on overflow.
    func addingChecked(_ other: UInt64) -> UInt64? {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? nil : sum
    }
}

private func checkedAdd(_ a: UInt64, _ b: UInt64, or failure: ZIPError) throws -> UInt64 {
    guard let sum = a.addingChecked(b) else { throw failure }
    return sum
}
