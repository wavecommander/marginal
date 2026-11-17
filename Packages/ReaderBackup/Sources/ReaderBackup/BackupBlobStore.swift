import Foundation

/// A folder of a blob store, matching `BackupFolderLayout`.
public enum BackupBlobFolder: String, Hashable, Sendable, CaseIterable {
    /// `Backups/`: snapshot objects.
    case backups = "Backups"
    /// `PDFs/`: PDF objects.
    case pdfs = "PDFs"
}

/// The name of an object in a blob store: one name in `Backups/` or `PDFs/`, or a top-level
/// control object (`folder == nil`).
public struct BackupBlobKey: Hashable, Sendable, CustomStringConvertible {
    /// The folder, or `nil` for a top-level control object.
    public let folder: BackupBlobFolder?
    /// The object's name within its folder (a single path component).
    public let name: String

    public init(folder: BackupBlobFolder?, name: String) {
        self.folder = folder
        self.name = name
    }

    /// `Backups/<name>`
    public static func backup(_ name: String) -> BackupBlobKey { BackupBlobKey(folder: .backups, name: name) }
    /// `PDFs/<name>`
    public static func pdf(_ name: String) -> BackupBlobKey { BackupBlobKey(folder: .pdfs, name: name) }
    /// `<name>` at the top level.
    public static func control(_ name: String) -> BackupBlobKey { BackupBlobKey(folder: nil, name: name) }

    /// The object's path relative to the store's root: `Backups/<name>`, `PDFs/<name>` or `<name>`.
    public var path: String { folder.map { "\($0.rawValue)/\(name)" } ?? name }

    public var description: String { path }

    /// `true` when `name` is a safe single path component: 1 to 255 UTF-8 bytes, no `/`, `\`
    /// or NUL, and not starting with `.` (which also excludes `.` and `..`). Stores refuse other
    /// names.
    public var hasValidName: Bool {
        let bytes = name.utf8
        return (1...255).contains(bytes.count) && !name.hasPrefix(".")
            && !bytes.contains(UInt8(ascii: "/")) && !bytes.contains(UInt8(ascii: "\\")) && !bytes.contains(0)
    }
}

/// An object listed in a blob store folder.
public struct BackupBlobInfo: Hashable, Sendable {
    /// The object's name within its folder.
    public var name: String
    /// Its size in bytes.
    public var byteSize: Int64

    public init(name: String, byteSize: Int64) {
        self.name = name
        self.byteSize = byteSize
    }
}

/// The minimum a storage back end must offer to hold a reader's encrypted backups: opaque
/// objects by name in `Backups/` and `PDFs/`, plus a few top-level control objects.
/// `EncryptedBackupDestination` builds a full `BackupDestination` on top of it.
///
/// A store knows nothing about what it holds and does no content hashing: integrity comes from
/// the encryption, which authenticates every byte.
///
/// Contract every implementation keeps:
/// - An object is either absent or complete: a failed or cancelled upload leaves nothing under
///   the object's name (and leaves an object it was replacing intact or fully replaced).
/// - `download` writes the local file atomically too, or leaves nothing there.
/// - A missing object: `size(of:)` returns `nil`; `download` throws
///   `BackupError.fileNotFound(name:)` with the key's name; `delete` succeeds.
/// - Keys whose name is not `hasValidName` are refused with `BackupError.unsafeEntryName`.
/// - Cancellation (of the calling task) throws `CancellationError`. The store's own failures
///   (no network, rejected credentials, a full account) throw its own `LocalizedError`, which
///   callers show as is.
/// - Progress callbacks report the fraction of the transfer, ending at 1 on success.
public protocol BackupBlobStore: Sendable {
    /// Whether the store can be used now, and if not why (reader-facing).
    func availability() async -> BackupDestinationAvailability

    /// The objects in `folder` (in no particular order). An empty or missing folder lists
    /// nothing. Names that are not `hasValidName` may be left out.
    func list(_ folder: BackupBlobFolder) async throws -> [BackupBlobInfo]

    /// The size of the object in bytes, or `nil` when there is none.
    func size(of key: BackupBlobKey) async throws -> Int64?

    /// Uploads the local file as the object `key`, replacing any object there.
    func upload(from file: URL, to key: BackupBlobKey, progress: BackupProgress?) async throws

    /// Downloads the object `key` to the local file `file`, replacing any file there.
    func download(_ key: BackupBlobKey, to file: URL, progress: BackupProgress?) async throws

    /// Deletes the object `key`. Deleting one that is already gone succeeds.
    func delete(_ key: BackupBlobKey) async throws
}

/// A `BackupBlobStore` over a directory: `<root>/Backups/<name>`, `<root>/PDFs/<name>` and
/// `<root>/<control name>`. It uses the same file access hook as `FolderBackupDestination` (see
/// there), so a picked folder can hold encrypted backups too, and it is
/// what the tests use.
///
/// Writes go to a hidden temporary sibling that is renamed into place when complete. Listing
/// ignores hidden files (including iCloud placeholders), folders and unsafe names.
public struct FolderBackupBlobStore: BackupBlobStore {
    /// The store's folder.
    public let root: URL
    private let access: FolderBackupDestination.AccessHook

    public init(root: URL, access: @escaping FolderBackupDestination.AccessHook = FolderBackupDestination.directAccess) {
        self.root = root
        self.access = access
    }

    public func availability() async -> BackupDestinationAvailability {
        do {
            let isDirectory = try perform(root, .read) { url -> Bool in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            return isDirectory ? .available
                : .unavailable(reason: "The folder “\(root.lastPathComponent)” can’t be found. It may have been moved, renamed or deleted.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func list(_ folder: BackupBlobFolder) async throws -> [BackupBlobInfo] {
        let directory = root.appendingPathComponent(folder.rawValue, isDirectory: true)
        return try perform(directory, .read) { url -> [BackupBlobInfo] in
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
            let names = try mappingFileErrors(url) { try manager.contentsOfDirectory(atPath: url.path) }
            return names.compactMap { name in
                guard BackupBlobKey(folder: folder, name: name).hasValidName,
                      let size = FileOps.regularFileSize(url.appendingPathComponent(name, isDirectory: false)) else { return nil }
                return BackupBlobInfo(name: name, byteSize: size)
            }
        }
    }

    public func size(of key: BackupBlobKey) async throws -> Int64? {
        try perform(try url(key), .read) { FileOps.regularFileSize($0) }
    }

    public func upload(from file: URL, to key: BackupBlobKey, progress: BackupProgress?) async throws {
        try perform(try url(key), .write) { url in
            try FileOps.createDirectory(url.deletingLastPathComponent())
            try FileOps.copyVerifying(file, to: url, expected: nil, mismatch: .contentMismatch(name: key.name), progress: progress)
        }
    }

    public func download(_ key: BackupBlobKey, to file: URL, progress: BackupProgress?) async throws {
        try perform(try url(key), .read) { url in
            guard FileOps.regularFileSize(url) != nil else { throw BackupError.fileNotFound(name: key.name) }
            try FileOps.copyVerifying(url, to: file, expected: nil, mismatch: .contentMismatch(name: key.name), progress: progress)
        }
    }

    public func delete(_ key: BackupBlobKey) async throws {
        try perform(try url(key), .delete) { url in
            guard FileOps.regularFileSize(url) != nil else { return }
            try mappingFileErrors(url) { try FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Internals

    private func url(_ key: BackupBlobKey) throws -> URL {
        guard key.hasValidName else { throw BackupError.unsafeEntryName(name: key.name) }
        var url = root
        if let folder = key.folder { url = url.appendingPathComponent(folder.rawValue, isDirectory: true) }
        return url.appendingPathComponent(key.name, isDirectory: false)
    }

    /// Runs `body` through the access hook and returns its result.
    private func perform<T>(_ url: URL, _ intent: FolderBackupDestination.AccessIntent, _ body: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        var result: T?
        try access(url, intent) { accessed in result = try body(accessed) }
        guard let result else { throw BackupError.fileAccessFailed(name: url.lastPathComponent, code: Int(EIO)) }
        return result
    }
}

extension FolderBackupDestination {
    /// The destination's folder as a blob store (same root and access hook), to hold encrypted
    /// backups through `EncryptedBackupDestination`.
    public var blobStore: FolderBackupBlobStore {
        FolderBackupBlobStore(root: root, access: access)
    }
}
