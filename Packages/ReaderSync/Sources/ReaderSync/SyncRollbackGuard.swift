import Foundation
import ReaderBackup

/// The highest head version this device has seen for each book, kept on disk, so the store
/// cannot silently roll a book back by serving an older head (`docs/CLOUD_SYNC_PLAN.md` "What the
/// operator can and cannot see").
///
/// **Files.** `<directory>/<book key>`: the decimal version followed by a newline (`12\n`),
/// replaced atomically (written beside it, then renamed). Book keys are 64 hex digits, so they
/// are safe file names. The caller keeps one directory per account
/// (`Application Support/Sync/<account>/versions`), outside every book's own directory.
///
/// A version equal to the highest seen is accepted (the same head read again); only a lower one
/// is refused. A record that cannot be read throws `rollbackRecordUnreadable` rather than
/// accepting a head it cannot check.
///
/// Calls are serialised within one value and its copies; one directory must not be shared by
/// two values at once.
public struct SyncRollbackGuard: Sendable {
    /// Where the records are.
    public let directory: URL
    private let lock = Lock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The highest version seen for the book, or `nil` if none was recorded.
    public func highestVersion(bookKey: String) throws -> Int? {
        try lock.locked { try read(bookKey) }
    }

    /// Throws `SyncError.rollback` when `version` is lower than the highest seen for the book.
    public func check(bookKey: String, version: Int) throws {
        try lock.locked {
            if let highest = try read(bookKey), version < highest {
                throw SyncError.rollback(bookKey: bookKey, highestSeen: highest, offered: version)
            }
        }
    }

    /// Records `version` as seen, keeping the highest.
    public func record(bookKey: String, version: Int) throws {
        try lock.locked {
            if let highest = try read(bookKey), highest >= version { return }
            try write(bookKey, version)
        }
    }

    /// `check`, then `record`, as one step: what a device does with every head it reads.
    public func accept(bookKey: String, version: Int) throws {
        try lock.locked {
            if let highest = try read(bookKey) {
                if version < highest { throw SyncError.rollback(bookKey: bookKey, highestSeen: highest, offered: version) }
                if version == highest { return }
            }
            try write(bookKey, version)
        }
    }

    /// Forgets the book's record.
    public func remove(bookKey: String) throws {
        let url = try file(bookKey)
        try lock.locked {
            try mappingFileErrors(url) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Forgets every record (signing in to another account sets the old one aside).
    public func removeAll() throws {
        try lock.locked {
            try mappingFileErrors(directory) {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }
        }
    }

    // MARK: Internals

    private func file(_ bookKey: String) throws -> URL {
        directory.appendingPathComponent(try SyncLayout.validName(bookKey), isDirectory: false)
    }

    private func read(_ bookKey: String) throws -> Int? {
        let url = try file(bookKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= 32,
              let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"),
              let version = Int(text.dropLast()), version >= 1 else {
            throw SyncError.rollbackRecordUnreadable(bookKey: bookKey)
        }
        return version
    }

    private func write(_ bookKey: String, _ version: Int) throws {
        let url = try file(bookKey)
        try mappingFileErrors(url) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(version)\n".utf8).write(to: url, options: .atomic)
        }
    }
}

/// A lock shared by a value and its copies.
final class Lock: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
