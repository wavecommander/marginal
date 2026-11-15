import Foundation

/// A reader-progress callback: a fraction in `0...1`, called from the thread doing the work.
/// Values never decrease within one operation, and the last call of a successful operation is `1`.
public typealias BackupProgress = @Sendable (Double) -> Void

/// Size of every streamed read and write: large files are never held in memory, only one chunk.
let streamChunkSize = 4 * 1024 * 1024

/// A regular file opened read-only, read with positioned reads (`pread`).
///
/// `Sendable` because `pread` does not move a shared file offset, so concurrent reads of one
/// instance cannot interfere; the descriptor is closed when the last reference goes away.
final class ReadOnlyFile: Sendable {
    let url: URL
    let descriptor: Int32
    /// The size when the file was opened.
    let size: UInt64

    init(url: URL) throws {
        let fd: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else { throw BackupError.posix(errno, url) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw BackupError.posix(code, url)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw BackupError.fileAccessFailed(name: url.lastPathComponent, code: Int(EISDIR))
        }
        self.url = url
        self.descriptor = fd
        self.size = UInt64(info.st_size)
    }

    deinit { close(descriptor) }

    /// Reads up to `buffer.count` bytes at `offset`; returns the count read (short only at EOF).
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        var total = 0
        while total < buffer.count {
            let result = pread(descriptor, buffer.baseAddress! + total, buffer.count - total, off_t(offset) + off_t(total))
            if result < 0 {
                if errno == EINTR { continue }
                throw BackupError.posix(errno, url)
            }
            if result == 0 { break }
            total += result
        }
        return total
    }

    /// Exactly `count` bytes at `offset`, or `incomplete` when the file ends first.
    func readExactly(at offset: UInt64, count: Int, incomplete: BackupError = .archiveIncomplete) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let read = try data.withUnsafeMutableBytes { try self.read(at: offset, into: $0) }
        guard read == count else { throw incomplete }
        return data
    }

    /// Streams exactly `count` bytes from `offset` in chunks of at most `streamChunkSize`,
    /// checking for task cancellation before each chunk. Throws `incomplete` if the file ends
    /// first.
    func stream(from offset: UInt64, count: UInt64, incomplete: BackupError = .archiveIncomplete,
                _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard count > 0 else { return }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(min(UInt64(streamChunkSize), count)), alignment: 16)
        defer { buffer.deallocate() }
        var done: UInt64 = 0
        while done < count {
            try Task.checkCancellation()
            let want = Int(min(UInt64(buffer.count), count - done))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<want])
            let read = try self.read(at: offset + done, into: slice)
            guard read == want else { throw incomplete }
            try body(UnsafeRawBufferPointer(slice))
            done += UInt64(want)
        }
    }

    /// `true` when the file has bytes at or after `offset` (used to detect a file that grew).
    func hasBytes(at offset: UInt64) throws -> Bool {
        var byte: UInt8 = 0
        return try withUnsafeMutableBytes(of: &byte) { try read(at: offset, into: $0) } > 0
    }

    /// Streams the whole file as it is on disk, expecting exactly `size` bytes; a file that is
    /// shorter or longer than when it was opened throws `sourceFileChanged`.
    func streamWholeFile(_ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let changed = BackupError.sourceFileChanged(name: url.lastPathComponent)
        try stream(from: 0, count: size, incomplete: changed, body)
        if try hasBytes(at: size) { throw changed }
    }
}

/// A file created for writing (replacing any file already at the path), written sequentially,
/// with positioned writes for patching headers.
final class WritableFile {
    let url: URL
    private(set) var descriptor: Int32
    /// Bytes written by sequential `write` calls, which is the current end of the file.
    private(set) var offset: UInt64 = 0

    init(creatingAt url: URL) throws {
        let fd: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { throw BackupError.posix(errno, url) }
        self.url = url
        self.descriptor = fd
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        try write(buffer, at: offset)
        offset += UInt64(buffer.count)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    /// Writes at `position` without moving `offset` (patching an earlier header).
    func write(_ buffer: UnsafeRawBufferPointer, at position: UInt64) throws {
        guard descriptor >= 0 else { throw BackupError.writerClosed }
        var done = 0
        while done < buffer.count {
            let result = pwrite(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(position) + off_t(done))
            if result < 0 {
                if errno == EINTR { continue }
                throw BackupError.posix(errno, url)
            }
            done += result
        }
    }

    /// Flushes to the device (before an atomic rename makes the file visible).
    func synchronize() throws {
        guard descriptor >= 0 else { throw BackupError.writerClosed }
        guard fsync(descriptor) == 0 else { throw BackupError.posix(errno, url) }
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        guard Darwin.close(fd) == 0 else { throw BackupError.posix(errno, url) }
    }
}

/// File-system helpers shared by the archive and folder code.
enum FileOps {
    /// Removes `url` if it exists; never throws (cleanup after a failure).
    static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Atomically renames `source` onto `destination`, replacing any file there (`rename(2)`).
    static func rename(_ source: URL, to destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return -1 }
                return Darwin.rename(from, to)
            }
        }
        guard result == 0 else { throw BackupError.posix(errno, destination) }
    }

    /// A hidden sibling of `url` for writing before an atomic rename into place.
    static func temporarySibling(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial", isDirectory: false)
    }

    /// Creates `url` and any missing parents.
    static func createDirectory(_ url: URL) throws {
        try mappingFileErrors(url) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Size of the regular file at `url`, or `nil` when there is none.
    static func regularFileSize(_ url: URL) -> Int64? {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    /// Copies `source` to `destination` atomically (hidden temporary sibling, then rename),
    /// streaming in chunks with cancellation and progress, hashing what it copies. When
    /// `expected` is given, a different size or SHA-256 throws `mismatch` and nothing is left at
    /// `destination`. Returns the digest of the copied bytes.
    @discardableResult
    static func copyVerifying(_ source: URL, to destination: URL, expected: ContentDigest?, mismatch: BackupError,
                              progress: BackupProgress?) throws -> ContentDigest {
        let input = try ReadOnlyFile(url: source)
        let temporary = temporarySibling(of: destination)
        do {
            let output = try WritableFile(creatingAt: temporary)
            var hasher = ContentHasher()
            let total = input.size
            progress?(0)
            try input.streamWholeFile { chunk in
                try output.write(chunk)
                hasher.update(chunk)
                if total > 0 { progress?(Double(hasher.byteCount) / Double(total)) }
            }
            try output.synchronize()
            try output.close()
            let digest = hasher.finalize()
            if let expected, expected != digest { throw mismatch }
            try rename(temporary, to: destination)
            progress?(1)
            return digest
        } catch {
            removeQuietly(temporary)
            throw error
        }
    }
}
