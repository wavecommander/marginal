import CryptoKit
import Darwin
import Foundation
import ReaderSync

/// A `SyncObjectStore` in a local folder, standing in for the account's storage in tests and the
/// `-syncTestFolder` launch argument (no network). Several processes may share the folder: every
/// call holds an exclusive `flock` on `lock`, so a conditional write's check and write are atomic
/// across them, as R2's are.
///
///     <root>/objects/<key, with "%" and "/" percent-encoded>     the object's bytes
///     <root>/metadata/<same name>.json                           its user metadata
///     <root>/lock
///
/// ETags are a quoted hash of the bytes (as S3's for a single `PutObject`), so writing equal
/// bytes keeps the ETag and any change of bytes changes it. An object's last-modified time is
/// its file's modification date (every write replaces the file).
nonisolated final class FolderSyncObjectStore: SyncObjectStore, @unchecked Sendable {
    let root: URL
    private let objects: URL
    private let metadataFolder: URL
    private let lockFile: URL
    private let lock = NSLock()

    init(root: URL) throws {
        self.root = root
        objects = root.appendingPathComponent("objects", isDirectory: true)
        metadataFolder = root.appendingPathComponent("metadata", isDirectory: true)
        lockFile = root.appendingPathComponent("lock", isDirectory: false)
        for folder in [objects, metadataFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: lockFile.path) {
            FileManager.default.createFile(atPath: lockFile.path, contents: nil)
        }
    }

    // MARK: SyncObjectStore

    func list(prefix: String) async throws -> [SyncObjectInfo] {
        try await locked {
            let names = try FileManager.default.contentsOfDirectory(atPath: objects.path)
            return try names.compactMap { name -> SyncObjectInfo? in
                guard let key = Self.key(fromName: name), key.hasPrefix(prefix) else { return nil }
                let url = objects.appendingPathComponent(name)
                let data = try Data(contentsOf: url)
                return SyncObjectInfo(key: key, eTag: Self.eTag(data), size: Int64(data.count), lastModified: Self.modified(url))
            }
            .sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
        }
    }

    func get(_ key: String, maxBytes: Int) async throws -> SyncObjectData? {
        try await locked {
            guard let data = try read(key) else { return nil }
            guard data.count <= maxBytes else { throw SyncError.objectTooLarge(key: key, limit: maxBytes) }
            return SyncObjectData(data: data, eTag: Self.eTag(data), metadata: try readMetadata(key))
        }
    }

    func put(_ data: Data, at key: String, metadata: [String: String], condition: SyncWriteCondition?) async throws -> String {
        try await locked {
            let current = try read(key)
            switch condition {
            case .ifMatch(let eTag):
                guard let current, Self.eTag(current) == eTag else { throw SyncError.preconditionFailed(key: key) }
            case .ifAbsent:
                guard current == nil else { throw SyncError.preconditionFailed(key: key) }
            case nil:
                break
            }
            try write(data, metadata: metadata, key: key)
            return Self.eTag(data)
        }
    }

    func upload(fileAt file: URL, to key: String, metadata: [String: String]) async throws {
        let data = try Data(contentsOf: file)
        try await locked { try write(data, metadata: metadata, key: key) }
    }

    func download(_ key: String, to file: URL) async throws {
        let data: Data = try await locked {
            guard let data = try read(key) else { throw SyncError.objectNotFound(key: key) }
            return data
        }
        try data.write(to: file, options: .atomic)
    }

    func head(_ key: String) async throws -> SyncObjectHead? {
        try await locked {
            guard let data = try read(key) else { return nil }
            return SyncObjectHead(size: Int64(data.count), eTag: Self.eTag(data), metadata: try readMetadata(key),
                                  lastModified: Self.modified(objectURL(key)))
        }
    }

    func delete(_ key: String) async throws {
        try await locked {
            try? FileManager.default.removeItem(at: objectURL(key))
            try? FileManager.default.removeItem(at: metadataURL(key))
        }
    }

    // MARK: Internals

    /// Runs `body` holding the in-process lock and the folder's `flock`.
    private func locked<T>(_ body: () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try lock.withLock {
            let descriptor = open(lockFile.path, O_RDWR | O_CREAT, 0o644)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    private func read(_ key: String) throws -> Data? {
        let url = objectURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func readMetadata(_ key: String) throws -> [String: String] {
        guard let data = try? Data(contentsOf: metadataURL(key)) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func write(_ data: Data, metadata: [String: String], key: String) throws {
        try JSONEncoder().encode(metadata).write(to: metadataURL(key), options: .atomic)
        try data.write(to: objectURL(key), options: .atomic)
    }

    private func objectURL(_ key: String) -> URL { objects.appendingPathComponent(Self.name(for: key)) }
    private func metadataURL(_ key: String) -> URL { metadataFolder.appendingPathComponent(Self.name(for: key) + ".json") }

    static func name(for key: String) -> String {
        key.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    static func key(fromName name: String) -> String? {
        guard !name.hasPrefix(".") else { return nil }
        return name.replacingOccurrences(of: "%2F", with: "/").replacingOccurrences(of: "%25", with: "%")
    }

    /// The file's modification date: every write replaces the file (atomically), so it is the
    /// time of the last write, as S3's `LastModified` is.
    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func eTag(_ data: Data) -> String {
        "\"" + SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined() + "\""
    }
}
