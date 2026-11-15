import Foundation

/// A `BackupDestination` over a directory: `<root>/Backups/<snapshot>.ttbackup` and
/// `<root>/PDFs/<sha256>.pdf` (`BackupFolderLayout`). The Folder destination uses it on a
/// folder the reader picked; the iCloud destination uses it on the ubiquity container.
///
/// - Every write goes to a hidden temporary name in the target folder and is renamed into place
///   only when complete, so other devices and file browsers never see a partial file under a
///   snapshot or PDF name. A failed or cancelled write removes its temporary file.
/// - PDFs are skipped when already present with the right size, and an upload is verified by
///   reading the copy back and comparing its SHA-256 before it is renamed into place.
/// - Listing ignores anything that is not a snapshot name, and hidden files (including iCloud's
///   `.<name>.icloud` placeholders for items not yet downloaded).
///
/// **File access hook.** Every file-system access under `root` goes through `access`, called
/// with the URL being accessed, what the access does, and a body that performs it given the URL
/// to use. The default calls the body directly. The app passes a hook that starts
/// security-scoped access and coordinates the access with `NSFileCoordinator`, then runs the
/// body with the URL the coordinator hands back; the hook must rethrow the body's error. Local
/// files outside `root` (the source of an upload, the target of a download) are accessed
/// directly.
///
/// Blocking file I/O runs on the caller's task (the methods are `nonisolated async`, so they do
/// not run on the main actor).
public struct FolderBackupDestination: BackupDestination {
    /// What an access through the hook does.
    public enum AccessIntent: Hashable, Sendable {
        /// Reads a file, inspects it, or lists a directory.
        case read
        /// Creates or replaces a file (writing a temporary sibling and renaming it into place,
        /// creating the parent directory when needed).
        case write
        /// Deletes a file.
        case delete
    }

    /// Wraps one access of `url`; must call `body` exactly once (with `url` or the URL to use
    /// instead) and rethrow its error.
    public typealias AccessHook = @Sendable (_ url: URL, _ intent: AccessIntent, _ body: (URL) throws -> Void) throws -> Void

    /// The default hook: runs the body on `url` directly.
    public static let directAccess: AccessHook = { url, _, body in try body(url) }

    public let id: String
    public let displayName: String
    /// The destination's folder.
    public let root: URL
    let access: AccessHook

    /// A destination rooted at `root`. `id` defaults to `folder:<root path>` and `displayName`
    /// to the folder's name.
    public init(root: URL, id: String? = nil, displayName: String? = nil, access: @escaping AccessHook = FolderBackupDestination.directAccess) {
        self.root = root
        self.id = id ?? "folder:\(root.path)"
        self.displayName = displayName ?? root.lastPathComponent
        self.access = access
    }

    public func availability() async -> BackupDestinationAvailability {
        do {
            let isDirectory = try perform(root, .read) { url -> Bool in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            return isDirectory ? .available
                : .unavailable(reason: "The folder “\(displayName)” can’t be found. It may have been moved, renamed or deleted.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func listSnapshots() async throws -> [BackupSnapshotInfo] {
        let directory = root.appendingPathComponent(BackupFolderLayout.backupsDirectory, isDirectory: true)
        let snapshots = try perform(directory, .read) { url -> [BackupSnapshotInfo] in
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
            let names = try mappingFileErrors(url) { try manager.contentsOfDirectory(atPath: url.path) }
            return names.compactMap { name in
                guard !name.hasPrefix("."), let size = FileOps.regularFileSize(url.appendingPathComponent(name, isDirectory: false)) else {
                    return nil
                }
                return Self.info(name: name, size: size)
            }
        }
        return snapshots.sorted(by: BackupSnapshotInfo.newestFirst)
    }

    @discardableResult
    public func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        guard Self.info(name: name, size: 0) != nil else { throw BackupError.invalidSnapshotName(name: name) }
        let target = snapshotURL(name)
        let digest = try perform(target, .write) { url in
            try FileOps.createDirectory(url.deletingLastPathComponent())
            return try FileOps.copyVerifying(file, to: url, expected: nil, mismatch: .contentMismatch(name: name), progress: progress)
        }
        return Self.info(name: name, size: digest.size)!
    }

    public func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        guard Self.info(name: snapshot.id, size: 0) != nil else { throw BackupError.invalidSnapshotName(name: snapshot.id) }
        try perform(snapshotURL(snapshot.id), .read) { url in
            guard FileOps.regularFileSize(url) != nil else { throw BackupError.snapshotNotFound(name: snapshot.name) }
            try FileOps.copyVerifying(url, to: file, expected: nil, mismatch: .contentMismatch(name: snapshot.name), progress: progress)
        }
    }

    public func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        guard Self.info(name: snapshot.id, size: 0) != nil else { throw BackupError.invalidSnapshotName(name: snapshot.id) }
        try perform(snapshotURL(snapshot.id), .delete) { url in
            guard FileOps.regularFileSize(url) != nil else { return }
            try mappingFileErrors(url) { try FileManager.default.removeItem(at: url) }
        }
    }

    public func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        let hash = try Self.validHash(sha256)
        return try perform(pdfURL(hash), .read) { url in FileOps.regularFileSize(url) == size }
    }

    public func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        let expected = ContentDigest(sha256: hash, size: size)
        try perform(pdfURL(hash), .write) { url in
            if FileOps.regularFileSize(url) == size {
                progress?(1)
                return
            }
            try FileOps.createDirectory(url.deletingLastPathComponent())
            let temporary = FileOps.temporarySibling(of: url)
            do {
                // Copy (checking the source is the PDF the caller hashed), then read the copy
                // back and check it again before it becomes visible under its final name.
                let copyProgress: BackupProgress = { progress?($0 * 0.5) }
                try FileOps.copyVerifying(file, to: temporary, expected: expected,
                                          mismatch: .contentMismatch(name: file.lastPathComponent), progress: copyProgress)
                let written = try ContentHash.digest(ofFileAt: temporary, progress: { progress?(0.5 + $0 * 0.5) })
                guard written == expected else { throw BackupError.contentMismatch(name: file.lastPathComponent) }
                try FileOps.rename(temporary, to: url)
                progress?(1)
            } catch {
                FileOps.removeQuietly(temporary)
                throw error
            }
        }
    }

    public func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        try perform(pdfURL(hash), .read) { url in
            guard let size = FileOps.regularFileSize(url) else { throw BackupError.pdfNotAtDestination(sha256: hash) }
            try FileOps.copyVerifying(url, to: file, expected: ContentDigest(sha256: hash, size: size),
                                      mismatch: .contentMismatch(name: BackupFolderLayout.pdfFileName(sha256: hash)), progress: progress)
        }
    }

    // MARK: - Internals

    private func snapshotURL(_ name: String) -> URL {
        root.appendingPathComponent(BackupFolderLayout.backupsDirectory, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func pdfURL(_ sha256: String) -> URL {
        root.appendingPathComponent(BackupFolderLayout.pdfsDirectory, isDirectory: true)
            .appendingPathComponent(BackupFolderLayout.pdfFileName(sha256: sha256), isDirectory: false)
    }

    /// Runs `body` through the access hook and returns its result.
    private func perform<T>(_ url: URL, _ intent: AccessIntent, _ body: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        var result: T?
        try access(url, intent) { accessed in result = try body(accessed) }
        guard let result else { throw BackupError.fileAccessFailed(name: url.lastPathComponent, code: Int(EIO)) }
        return result
    }

    /// The snapshot info for a file named `name`, or `nil` when it is not a snapshot name.
    private static func info(name: String, size: Int64) -> BackupSnapshotInfo? {
        guard !name.contains("/"), !name.hasPrefix("."), let parsed = SnapshotName.parse(name) else { return nil }
        return BackupSnapshotInfo(id: name, name: name, createdAt: parsed.createdAt, deviceName: parsed.deviceName, byteSize: size)
    }

    private static func validHash(_ sha256: String) throws -> String {
        let hash = sha256.lowercased()
        guard ContentHash.isValidSHA256(hash) else { throw BackupError.pdfNotAtDestination(sha256: sha256) }
        return hash
    }
}
