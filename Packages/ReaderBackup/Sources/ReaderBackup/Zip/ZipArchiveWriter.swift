import Foundation

/// Writes a standard ZIP archive whose entries are all *stored* (method 0, no compression), so
/// the archive opens in any unzip tool and entries can be read back by offset without inflating.
///
/// - Names are UTF-8 (general-purpose bit 11) and must be plain relative paths
///   (see `ZipArchiveReader` for the exact rules; the writer refuses what the reader would).
/// - ZIP64 records are written whenever an entry's size or offset, the central directory's size
///   or offset, or the entry count needs them, so multi-gigabyte backups work.
/// - File entries are streamed in 4 MiB chunks; CRC-32 (zlib) and SHA-256 are computed in the
///   same pass, and the CRC is patched into the local header afterwards, so each source file is
///   read exactly once.
/// - **Any thrown error (including `CancellationError` and a duplicate name) abandons the
///   archive**: the partial output file is removed and the writer refuses further use. A writer
///   released without `finish()` removes its output too, so an early exit never leaves a
///   half-written archive that looks complete.
///
/// Blocking and not thread-safe: use one writer from one task, off the main actor.
public final class ZipArchiveWriter {
    /// Where the archive is being written.
    public let url: URL

    /// Test hook: write ZIP64 records for every entry and for the end of the central directory
    /// even when nothing needs them, so ZIP64 reading is covered without multi-gigabyte files.
    var forceZIP64 = false

    private enum State { case open, finished, failed }

    private struct CentralRecord {
        let name: Data
        let crc: UInt32
        let size: UInt64
        let offset: UInt64
    }

    private let file: WritableFile
    private let timestamp: DOSDateTime
    private var records: [CentralRecord] = []
    private var names: Set<String> = []
    private var state = State.open

    /// Creates (or replaces) the file at `url`. Every entry gets `modificationDate` as its
    /// timestamp, written in UTC: a fixed date makes the archive's bytes reproducible.
    public init(url: URL, modificationDate: Date = Date()) throws {
        self.url = url
        self.file = try WritableFile(creatingAt: url)
        self.timestamp = DOSDateTime(modificationDate)
    }

    deinit {
        if state == .open {
            try? file.close()
            FileOps.removeQuietly(url)
        }
    }

    /// Adds the file at `source` as entry `name`, streaming it. Returns the SHA-256 and size of
    /// the bytes written. `progress` is the fraction of this file written so far. Throws
    /// `sourceFileChanged` if the file's size changes while it is read.
    @discardableResult
    public func addEntry(named name: String, contentsOf source: URL, progress: BackupProgress? = nil) throws -> ContentDigest {
        try addEntry(named: name, contentsOf: source) { written, total in
            if total > 0 { progress?(Double(written) / Double(total)) }
        }.digest
    }

    /// Adds `data` as entry `name`. Returns its SHA-256 and size.
    @discardableResult
    public func addEntry(named name: String, data: Data) throws -> ContentDigest {
        try guarded {
            try begin(name)
            let (header, zip64) = try writeLocalHeader(name: name, size: UInt64(data.count))
            var crc = CRC32()
            var hasher = ContentHasher()
            try data.withUnsafeBytes { bytes in
                crc.update(bytes)
                hasher.update(bytes)
                try file.write(bytes)
            }
            try finishEntry(name: name, header: header, zip64: zip64, crc: crc.value, size: UInt64(data.count))
            return hasher.finalize()
        }
    }

    /// Streams a file into entry `name`, calling `onBytes(written, total)` after every chunk.
    /// Returns the digest and the CRC (the backup writer records both).
    func addEntry(named name: String, contentsOf source: URL,
                  onBytes: (_ written: Int64, _ total: Int64) -> Void) throws -> (digest: ContentDigest, crc: UInt32) {
        try guarded {
            try begin(name)
            let input = try ReadOnlyFile(url: source)
            let size = input.size
            let (header, zip64) = try writeLocalHeader(name: name, size: size)
            var crc = CRC32()
            var hasher = ContentHasher()
            onBytes(0, Int64(size))
            try input.streamWholeFile { chunk in
                crc.update(chunk)
                hasher.update(chunk)
                try file.write(chunk)
                onBytes(hasher.byteCount, Int64(size))
            }
            try finishEntry(name: name, header: header, zip64: zip64, crc: crc.value, size: size)
            return (hasher.finalize(), crc.value)
        }
    }

    /// Writes the central directory and end records and closes the file. The archive is
    /// complete only after this returns.
    public func finish() throws {
        try guarded {
            let directoryOffset = file.offset
            var batch = ByteWriter()
            for record in records {
                appendCentralHeader(record, to: &batch)
                if batch.data.count >= streamChunkSize {
                    try file.write(batch.data)
                    batch = ByteWriter()
                }
            }
            try file.write(batch.data)
            let directorySize = file.offset - directoryOffset
            try writeEnd(directoryOffset: directoryOffset, directorySize: directorySize)
            try file.close()
            state = .finished
        }
    }

    /// Stops writing and removes the partial output. Safe to call at any time; a no-op after
    /// `finish()`.
    public func abandon() {
        guard state == .open else { return }
        state = .failed
        try? file.close()
        FileOps.removeQuietly(url)
    }

    // MARK: - Internals

    /// Runs `body`; any error abandons the archive before it propagates.
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        guard state == .open else { throw BackupError.writerClosed }
        do {
            return try body()
        } catch {
            abandon()
            throw error
        }
    }

    private func begin(_ name: String) throws {
        try Task.checkCancellation()
        try ZipEntryName.validate(name, allowDirectory: false)
        guard names.insert(name).inserted else { throw BackupError.duplicateEntryName(name: name) }
    }

    /// Writes a local header with a zero CRC (patched by `finishEntry`). Returns the header's
    /// offset and whether it carries ZIP64 sizes.
    private func writeLocalHeader(name: String, size: UInt64) throws -> (offset: UInt64, zip64: Bool) {
        let offset = file.offset
        let zip64 = forceZIP64 || size >= ZipConstants.max32
        let nameBytes = Data(name.utf8)
        var header = ByteWriter()
        header.u32(ZipConstants.localHeaderSignature)
        header.u16(zip64 ? ZipConstants.versionZip64 : ZipConstants.versionDefault)
        header.u16(ZipConstants.flagUTF8)
        header.u16(0) // stored
        header.u16(timestamp.time)
        header.u16(timestamp.date)
        header.u32(0) // CRC-32, patched after the data
        header.u32(zip64 ? UInt32(ZipConstants.max32) : UInt32(size))
        header.u32(zip64 ? UInt32(ZipConstants.max32) : UInt32(size))
        header.u16(UInt16(nameBytes.count))
        header.u16(zip64 ? 20 : 0)
        header.bytes(nameBytes)
        if zip64 {
            header.u16(ZipConstants.zip64ExtraID)
            header.u16(16)
            header.u64(size) // uncompressed
            header.u64(size) // compressed
        }
        try file.write(header.data)
        return (offset, zip64)
    }

    private func finishEntry(name: String, header: UInt64, zip64: Bool, crc: UInt32, size: UInt64) throws {
        try withUnsafeBytes(of: crc.littleEndian) { try file.write($0, at: header + 14) }
        records.append(CentralRecord(name: Data(name.utf8), crc: crc, size: size, offset: header))
    }

    private func appendCentralHeader(_ record: CentralRecord, to out: inout ByteWriter) {
        let sizeOverflows = forceZIP64 || record.size >= ZipConstants.max32
        let offsetOverflows = forceZIP64 || record.offset >= ZipConstants.max32
        var extra = ByteWriter()
        if sizeOverflows || offsetOverflows {
            var fields = ByteWriter()
            if sizeOverflows {
                fields.u64(record.size) // uncompressed
                fields.u64(record.size) // compressed
            }
            if offsetOverflows { fields.u64(record.offset) }
            extra.u16(ZipConstants.zip64ExtraID)
            extra.u16(UInt16(fields.data.count))
            extra.bytes(fields.data)
        }
        let version = extra.data.isEmpty ? ZipConstants.versionDefault : ZipConstants.versionZip64
        out.u32(ZipConstants.centralHeaderSignature)
        out.u16(ZipConstants.madeByUnix | version)
        out.u16(version)
        out.u16(ZipConstants.flagUTF8)
        out.u16(0) // stored
        out.u16(timestamp.time)
        out.u16(timestamp.date)
        out.u32(record.crc)
        out.u32(sizeOverflows ? UInt32(ZipConstants.max32) : UInt32(record.size))
        out.u32(sizeOverflows ? UInt32(ZipConstants.max32) : UInt32(record.size))
        out.u16(UInt16(record.name.count))
        out.u16(UInt16(extra.data.count))
        out.u16(0) // comment length
        out.u16(0) // disk number start
        out.u16(0) // internal attributes
        out.u32(ZipConstants.externalAttributesFile)
        out.u32(offsetOverflows ? UInt32(ZipConstants.max32) : UInt32(record.offset))
        out.bytes(record.name)
        out.bytes(extra.data)
    }

    private func writeEnd(directoryOffset: UInt64, directorySize: UInt64) throws {
        let count = UInt64(records.count)
        let countOverflows = forceZIP64 || count >= ZipConstants.max16
        let sizeOverflows = forceZIP64 || directorySize >= ZipConstants.max32
        let offsetOverflows = forceZIP64 || directoryOffset >= ZipConstants.max32
        var out = ByteWriter()
        if countOverflows || sizeOverflows || offsetOverflows {
            let recordOffset = file.offset
            out.u32(ZipConstants.zip64EndOfCentralDirectorySignature)
            out.u64(UInt64(ZipConstants.zip64EndOfCentralDirectorySize - 12))
            out.u16(ZipConstants.madeByUnix | ZipConstants.versionZip64)
            out.u16(ZipConstants.versionZip64)
            out.u32(0) // this disk
            out.u32(0) // disk with the central directory
            out.u64(count)
            out.u64(count)
            out.u64(directorySize)
            out.u64(directoryOffset)
            out.u32(ZipConstants.zip64LocatorSignature)
            out.u32(0)
            out.u64(recordOffset)
            out.u32(1) // total disks
        }
        out.u32(ZipConstants.endOfCentralDirectorySignature)
        out.u16(0)
        out.u16(0)
        out.u16(countOverflows ? UInt16(ZipConstants.max16) : UInt16(count))
        out.u16(countOverflows ? UInt16(ZipConstants.max16) : UInt16(count))
        out.u32(sizeOverflows ? UInt32(ZipConstants.max32) : UInt32(directorySize))
        out.u32(offsetOverflows ? UInt32(ZipConstants.max32) : UInt32(directoryOffset))
        out.u16(0) // comment length
        try file.write(out.data)
    }
}
