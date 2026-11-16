import Foundation

/// One item of a ZIP archive, as its central directory describes it.
public struct ZipEntry: Hashable, Sendable {
    /// The entry's path inside the archive (`/`-separated, relative; validated).
    public let name: String
    /// Size in bytes (stored, so the same in the archive and extracted).
    public let size: Int64
    /// CRC-32 recorded for the entry, checked whenever it is read.
    public let crc32: UInt32
    /// Offset of the entry's local header in the archive file.
    let localHeaderOffset: UInt64

    /// `true` for a directory entry (name ending in `/`); other tools write these, this
    /// package's writer never does.
    public var isDirectory: Bool { name.hasSuffix("/") }
}

/// Reads a ZIP archive by random access: the end-of-central-directory record (ZIP64-aware) and
/// the central directory are read once at `init`; entry data is read on demand by offset.
///
/// It reads what `ZipArchiveWriter` writes and the same subset from other tools (for example
/// `zip -0`): stored entries on a single disk. Everything is checked as untrusted input, and
/// `init` refuses, with a `BackupError`:
/// - a file with no end record (`archiveIncomplete`) or inconsistent records, offsets or sizes
///   (`archiveDamaged`; offsets are bounds-checked so hostile input never reads out of range);
/// - compressed entries (`compressedEntry`) and encrypted ones (`encryptedEntry`);
/// - names that are not plain relative paths: absolute, containing `..` or `.` or empty
///   components, backslashes or NULs, or not UTF-8 (`unsafeEntryName`);
/// - two entries with the same name (`duplicateEntryName`; names that are canonically
///   equivalent Unicode count as the same, as they would on disk).
///
/// Reading an entry checks its local header against the central directory and its CRC-32 and
/// size (`entryChecksumMismatch`, `archiveIncomplete`).
///
/// `Sendable`: all state is immutable and reads are positioned, so one reader can serve
/// several tasks. Reading is blocking: call it off the main actor.
public final class ZipArchiveReader: Sendable {
    /// The archive file.
    public let url: URL
    /// Every entry, in central-directory order.
    public let entries: [ZipEntry]

    private let file: ReadOnlyFile
    private let index: [String: Int]
    /// Where entry data must end: the start of the central directory.
    private let directoryOffset: UInt64

    /// Upper bound on the central directory read into memory (about two million entries).
    private static let maximumDirectorySize: UInt64 = 256 * 1024 * 1024

    /// Opens and validates the archive at `url` (see the type's documentation for what is refused).
    public init(url: URL) throws {
        let file = try ReadOnlyFile(url: url)
        let end = try Self.readEnd(of: file)
        let directory = try file.readExactly(at: end.directoryOffset, count: Int(end.directorySize))
        let entries = try Self.parseDirectory(directory, count: end.count, directoryOffset: end.directoryOffset)
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() {
            guard index.updateValue(position, forKey: entry.name) == nil else {
                throw BackupError.duplicateEntryName(name: entry.name)
            }
        }
        self.url = url
        self.file = file
        self.entries = entries
        self.index = index
        self.directoryOffset = end.directoryOffset
    }

    /// The entry named `name`, or `nil`.
    public func entry(named name: String) -> ZipEntry? {
        index[name].map { entries[$0] }
    }

    /// The whole entry in memory, verified. For small entries (manifests, records): refuses
    /// entries larger than `maximumSize` bytes with `entryTooLarge`.
    public func data(of entry: ZipEntry, maximumSize: Int = 64 * 1024 * 1024) throws -> Data {
        guard entry.size <= Int64(maximumSize) else { throw BackupError.entryTooLarge(name: entry.name) }
        var data = Data(capacity: Int(entry.size))
        try stream(entry) { data.append(contentsOf: $0) }
        return data
    }

    /// Extracts `entry` to the file `destination` by streaming in 4 MiB chunks, computing its
    /// SHA-256 in the same pass. The bytes go to a hidden temporary sibling that is renamed onto
    /// `destination` (replacing any file there) only after the CRC-32 checks out and, when
    /// `expected` is given, the size and SHA-256 match it (else `contentMismatch` naming the
    /// entry). On any failure or cancellation nothing is left at `destination`. Returns the
    /// digest of the extracted bytes. `destination`'s directory must exist.
    @discardableResult
    public func extract(_ entry: ZipEntry, to destination: URL, expected: ContentDigest? = nil,
                        progress: BackupProgress? = nil) throws -> ContentDigest {
        if let expected, expected.size != entry.size { throw BackupError.contentMismatch(name: entry.name) }
        return try extract(entry, to: destination, expected: expected) { written in
            if entry.size > 0 { progress?(Double(written) / Double(entry.size)) }
        }
    }

    /// `extract` with a byte-count callback (the backup reader aggregates progress by bytes).
    @discardableResult
    func extract(_ entry: ZipEntry, to destination: URL, expected: ContentDigest?,
                 onBytes: (Int64) -> Void) throws -> ContentDigest {
        if entry.isDirectory {
            try FileOps.createDirectory(destination)
            return ContentHasher().finalize()
        }
        let temporary = FileOps.temporarySibling(of: destination)
        do {
            let output = try WritableFile(creatingAt: temporary)
            var hasher = ContentHasher()
            onBytes(0)
            try stream(entry) { chunk in
                try output.write(chunk)
                hasher.update(chunk)
                onBytes(hasher.byteCount)
            }
            try output.close()
            let digest = hasher.finalize()
            if let expected, expected != digest { throw BackupError.contentMismatch(name: entry.name) }
            try FileOps.rename(temporary, to: destination)
            return digest
        } catch {
            FileOps.removeQuietly(temporary)
            throw error
        }
    }

    /// Streams the entry's bytes to `body` in chunks, checking cancellation between chunks.
    /// The CRC-32 is checked after the last chunk, so a caller must not trust (or publish) the
    /// bytes until this returns.
    func stream(_ entry: ZipEntry, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let start = try dataOffset(of: entry)
        var crc = CRC32()
        try file.stream(from: start, count: UInt64(entry.size)) { chunk in
            crc.update(chunk)
            try body(chunk)
        }
        guard crc.value == entry.crc32 else { throw BackupError.entryChecksumMismatch(name: entry.name) }
    }

    /// Validates the local header and returns where the entry's data starts.
    private func dataOffset(of entry: ZipEntry) throws -> UInt64 {
        let header = try file.readExactly(at: entry.localHeaderOffset, count: ZipConstants.localHeaderSize)
        var reader = ByteReader(header)
        guard try reader.u32() == ZipConstants.localHeaderSignature else {
            throw BackupError.archiveDamaged(detail: "bad local header for \(entry.name)")
        }
        _ = try reader.u16() // version needed
        let flags = try reader.u16()
        let method = try reader.u16()
        if flags & (ZipConstants.flagEncrypted | ZipConstants.flagStrongEncryption) != 0 {
            throw BackupError.encryptedEntry(name: entry.name)
        }
        guard method == 0 else { throw BackupError.compressedEntry(name: entry.name) }
        try reader.skip(16) // time, date, CRC, sizes (the central directory is authoritative)
        let nameLength = UInt64(try reader.u16())
        let extraLength = UInt64(try reader.u16())
        let localName = try file.readExactly(at: entry.localHeaderOffset + UInt64(ZipConstants.localHeaderSize),
                                             count: Int(nameLength))
        guard localName == Data(entry.name.utf8) else {
            throw BackupError.archiveDamaged(detail: "local and central names differ for \(entry.name)")
        }
        let start = entry.localHeaderOffset + UInt64(ZipConstants.localHeaderSize) + nameLength + extraLength
        let (end, overflow) = start.addingReportingOverflow(UInt64(entry.size))
        guard !overflow, end <= directoryOffset else {
            throw BackupError.archiveDamaged(detail: "data of \(entry.name) overlaps the directory")
        }
        return start
    }

    // MARK: - End records

    private struct End {
        var count: UInt64
        var directorySize: UInt64
        var directoryOffset: UInt64
    }

    private static func readEnd(of file: ReadOnlyFile) throws -> End {
        let size = file.size
        let minimum = UInt64(ZipConstants.endOfCentralDirectorySize)
        guard size >= minimum else { throw BackupError.archiveIncomplete }
        // The end record is the last thing in the file, followed only by a comment of at most
        // 65,535 bytes. Search backwards for a signature whose comment length fits exactly.
        let tailLength = min(size, minimum + ZipConstants.max16)
        let tailStart = size - tailLength
        let tail = try file.readExactly(at: tailStart, count: Int(tailLength))
        var found: Int?
        var position = tail.count - Int(minimum)
        while position >= 0 {
            var probe = ByteReader(tail, at: position)
            if try probe.u32() == ZipConstants.endOfCentralDirectorySignature {
                try probe.skip(16)
                let commentLength = Int(try probe.u16())
                if position + Int(minimum) + commentLength == tail.count {
                    found = position
                    break
                }
            }
            position -= 1
        }
        guard let found else { throw BackupError.archiveIncomplete }
        let endPosition = tailStart + UInt64(found)

        var reader = ByteReader(tail, at: found + 4)
        let disk = try reader.u16()
        let directoryDisk = try reader.u16()
        let countOnDisk = UInt64(try reader.u16())
        var end = End(count: UInt64(try reader.u16()), directorySize: UInt64(try reader.u32()),
                      directoryOffset: UInt64(try reader.u32()))
        guard disk == 0, directoryDisk == 0, countOnDisk == end.count else {
            throw BackupError.archiveDamaged(detail: "multi-disk archive")
        }

        // ZIP64: a locator immediately before the end record points at the ZIP64 end record.
        var directoryLimit = endPosition
        let locatorSize = UInt64(ZipConstants.zip64LocatorSize)
        if endPosition >= locatorSize {
            let locator = try file.readExactly(at: endPosition - locatorSize, count: ZipConstants.zip64LocatorSize)
            var locatorReader = ByteReader(locator)
            if try locatorReader.u32() == ZipConstants.zip64LocatorSignature {
                let locatorDisk = try locatorReader.u32()
                let recordOffset = try locatorReader.u64()
                let totalDisks = try locatorReader.u32()
                let recordSize = UInt64(ZipConstants.zip64EndOfCentralDirectorySize)
                guard locatorDisk == 0, totalDisks <= 1,
                      recordOffset <= endPosition - locatorSize,
                      endPosition - locatorSize - recordOffset >= recordSize else {
                    throw BackupError.archiveDamaged(detail: "bad ZIP64 locator")
                }
                let record = try file.readExactly(at: recordOffset, count: ZipConstants.zip64EndOfCentralDirectorySize)
                var recordReader = ByteReader(record)
                guard try recordReader.u32() == ZipConstants.zip64EndOfCentralDirectorySignature else {
                    throw BackupError.archiveDamaged(detail: "bad ZIP64 end record")
                }
                try recordReader.skip(8 + 2 + 2) // record size, made by, needed
                let disk64 = try recordReader.u32()
                let directoryDisk64 = try recordReader.u32()
                let countOnDisk64 = try recordReader.u64()
                end = End(count: try recordReader.u64(), directorySize: try recordReader.u64(),
                          directoryOffset: try recordReader.u64())
                guard disk64 == 0, directoryDisk64 == 0, countOnDisk64 == end.count else {
                    throw BackupError.archiveDamaged(detail: "multi-disk ZIP64 archive")
                }
                directoryLimit = recordOffset
            }
        }

        let (directoryEnd, overflow) = end.directoryOffset.addingReportingOverflow(end.directorySize)
        guard !overflow, directoryEnd <= directoryLimit else {
            throw BackupError.archiveDamaged(detail: "central directory out of range")
        }
        guard end.directorySize <= maximumDirectorySize,
              end.count <= end.directorySize / UInt64(ZipConstants.centralHeaderSize) else {
            throw BackupError.archiveDamaged(detail: "implausible central directory size or entry count")
        }
        return end
    }

    // MARK: - Central directory

    private static func parseDirectory(_ directory: Data, count: UInt64, directoryOffset: UInt64) throws -> [ZipEntry] {
        var reader = ByteReader(directory)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard try reader.u32() == ZipConstants.centralHeaderSignature else {
                throw BackupError.archiveDamaged(detail: "bad central directory header")
            }
            try reader.skip(4) // made by, version needed
            let flags = try reader.u16()
            let method = try reader.u16()
            try reader.skip(4) // time, date
            let crc = try reader.u32()
            var compressedSize = UInt64(try reader.u32())
            var size = UInt64(try reader.u32())
            let nameLength = Int(try reader.u16())
            let extraLength = Int(try reader.u16())
            let commentLength = Int(try reader.u16())
            var diskStart = UInt32(try reader.u16())
            try reader.skip(2 + 4) // internal and external attributes
            var offset = UInt64(try reader.u32())
            let nameBytes = try reader.bytes(nameLength)
            let extra = try reader.bytes(extraLength)
            try reader.skip(commentLength)

            guard let name = String(data: nameBytes, encoding: .utf8) else {
                throw BackupError.unsafeEntryName(name: String(decoding: nameBytes, as: UTF8.self))
            }
            if size == ZipConstants.max32 || compressedSize == ZipConstants.max32 || offset == ZipConstants.max32
                || diskStart == UInt32(ZipConstants.max16) {
                var fields = try zip64Fields(in: extra, name: name)
                if size == ZipConstants.max32 { size = try fields.u64() }
                if compressedSize == ZipConstants.max32 { compressedSize = try fields.u64() }
                if offset == ZipConstants.max32 { offset = try fields.u64() }
                if diskStart == UInt32(ZipConstants.max16) { diskStart = try fields.u32() }
            }
            if flags & (ZipConstants.flagEncrypted | ZipConstants.flagStrongEncryption) != 0 {
                throw BackupError.encryptedEntry(name: name)
            }
            guard method == 0 else { throw BackupError.compressedEntry(name: name) }
            try ZipEntryName.validate(name, allowDirectory: true)
            guard compressedSize == size, size <= UInt64(Int64.max) else {
                throw BackupError.archiveDamaged(detail: "stored sizes differ for \(name)")
            }
            guard diskStart == 0 else { throw BackupError.archiveDamaged(detail: "multi-disk entry \(name)") }
            if name.hasSuffix("/"), size != 0 {
                throw BackupError.archiveDamaged(detail: "directory entry \(name) has data")
            }
            // Cheap early bound; the exact one (with the local extra field) is checked on read.
            let minimumEnd = offset.addingReportingOverflow(UInt64(ZipConstants.localHeaderSize + nameLength))
            let dataEnd = minimumEnd.partialValue.addingReportingOverflow(size)
            guard !minimumEnd.overflow, !dataEnd.overflow, dataEnd.partialValue <= directoryOffset else {
                throw BackupError.archiveDamaged(detail: "entry \(name) out of range")
            }
            entries.append(ZipEntry(name: name, size: Int64(size), crc32: crc, localHeaderOffset: offset))
        }
        guard reader.remaining == 0 else {
            throw BackupError.archiveDamaged(detail: "central directory has trailing bytes")
        }
        return entries
    }

    /// A reader positioned at the data of the ZIP64 extra field in `extra`.
    private static func zip64Fields(in extra: Data, name: String) throws -> ByteReader {
        var reader = ByteReader(extra)
        while reader.remaining >= 4 {
            let id = try reader.u16()
            let length = Int(try reader.u16())
            let body = try reader.bytes(length)
            if id == ZipConstants.zip64ExtraID { return ByteReader(body) }
        }
        throw BackupError.archiveDamaged(detail: "missing ZIP64 field for \(name)")
    }
}
