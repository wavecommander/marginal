import Foundation
import GoogleDriveKit
import ReaderBackup

/// Backups in the reader's Google Drive, in the folder layout (`BackupFolderLayout`):
///
///     My Drive/Tactile Texts Backups/Backups/<snapshot name>.ttbackup
///     My Drive/Tactile Texts Backups/PDFs/<sha256>.pdf
///
/// The three folders are found by the role each was tagged with when this app created it (so a
/// renamed or moved top folder is still found) and created when missing. Their IDs are kept for
/// the life of this object; a folder that disappears (deleted or put in the trash) is looked up
/// or created again. Under the `drive.file` scope the app sees only what it created.
///
/// - Snapshot `id`s are Drive file IDs. Uploading a name that already exists replaces the old
///   file once the new one is complete.
/// - Uploads are verified against Drive's SHA-256 of what it stored (PDFs also against the
///   caller's hash) and removed when they do not match; downloads are verified the same way and
///   leave nothing behind when they fail.
/// - Errors: `CancellationError`, `BackupError` (not found, mismatch, local files) or
///   `CloudBackupError` (sign-in, storage full, network, service).
nonisolated final class GoogleDriveBackupDestination: BackupDestination {
    static let destinationID = "google-drive"
    static let name = "Google Drive"
    /// The visible top folder in My Drive.
    static let rootFolderName = "Tactile Texts Backups"
    /// Role tags (`GoogleDriveClient.folderRoleKey`) of the three folders.
    enum FolderRole: String, Sendable, CaseIterable {
        case root = "tactile-texts-backups"
        case backups = "tactile-texts-backups.snapshots"
        case pdfs = "tactile-texts-backups.pdfs"
    }
    /// How long a folder ID is trusted before an upload checks again that the folder is still
    /// there and not in the trash.
    static let folderRecheckInterval: TimeInterval = 60

    static let snapshotMimeType = "application/octet-stream"
    static let pdfMimeType = "application/pdf"

    let id = GoogleDriveBackupDestination.destinationID
    let displayName = GoogleDriveBackupDestination.name

    /// `nil` when the build is not set up.
    let client: GoogleDriveClient?
    let account: GoogleDriveAccount
    private let folders: FolderCache

    /// - Parameters:
    ///   - account: the app's Google connection; its `auth` signs every request.
    ///   - urlSession: injected in tests with a `URLProtocol` stub.
    ///   - now: the clock for `folderRecheckInterval` (injected in tests).
    init(account: GoogleDriveAccount, urlSession: URLSession = .shared, retryPolicy: GoogleRetryPolicy = .default,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        client = account.auth.map { GoogleDriveClient(auth: $0, urlSession: urlSession, retryPolicy: retryPolicy) }
        folders = FolderCache(now: now)
    }

    // MARK: Availability

    @concurrent
    func availability() async -> BackupDestinationAvailability {
        guard let client else {
            return .unavailable(reason: CloudBackupError.notSetUp(destination: displayName).localizedDescription)
        }
        let signedIn: Bool
        do {
            signedIn = try await client.auth.isSignedIn()
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
        if signedIn { return .available }
        let needsAgain = await account.state == .needsSignInAgain
        return .unavailable(reason: (needsAgain ? CloudBackupError.needsSignInAgain : .notSignedIn).localizedDescription)
    }

    // MARK: Snapshots

    @concurrent
    func listSnapshots() async throws -> [BackupSnapshotInfo] {
        try await run(.other) { client in
            var files = try await client.listFiles(inFolder: try await self.folder(.backups, client))
            if files.isEmpty, try await self.recoverIfGone(.backups, client) {
                files = try await client.listFiles(inFolder: try await self.folder(.backups, client))
            }
            return files.compactMap(Self.snapshotInfo).sorted(by: BackupSnapshotInfo.newestFirst)
        }
    }

    @discardableResult @concurrent
    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        guard Self.isSnapshotName(name) else { throw BackupError.invalidSnapshotName(name: name) }
        return try await run(.snapshot(name: name)) { client in
            let uploaded = try await self.intoFolder(.backups, client) { folderID in
                let existing = try await client.file(named: name, inFolder: folderID)
                let uploaded = try await client.uploadFile(
                    at: file, name: name, mimeType: Self.snapshotMimeType, inFolder: folderID,
                    progress: Self.transferProgress(progress))
                if let existing, existing.id != uploaded.id { try? await client.deleteFile(id: existing.id) }
                return uploaded
            }
            progress?(1)
            guard let info = Self.snapshotInfo(uploaded) else {
                throw CloudBackupError.serviceError(destination: Self.name, diagnostic: "uploaded snapshot unreadable")
            }
            return info
        }
    }

    @concurrent
    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        try await run(.snapshot(name: snapshot.name)) { client in
            try await client.downloadFile(id: snapshot.id, to: file, progress: Self.transferProgress(progress))
            progress?(1)
        }
    }

    @concurrent
    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        try await run(.snapshot(name: snapshot.name)) { client in
            do {
                try await client.deleteFile(id: snapshot.id)
            } catch GoogleDriveError.notFound {
                // Already gone.
            }
        }
    }

    // MARK: PDFs

    @concurrent
    func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        let hash = try Self.validHash(sha256)
        return try await run(.pdf(sha256: hash)) { client in
            Self.matches(try await self.findPDF(hash, client), hash: hash, size: size)
        }
    }

    @concurrent
    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        let name = BackupFolderLayout.pdfFileName(sha256: hash)
        try await run(.pdf(sha256: hash)) { client in
            try await self.intoFolder(.pdfs, client) { folderID in
                let existing = try await client.file(named: name, inFolder: folderID)
                if Self.matches(existing, hash: hash, size: size) { return }
                let uploaded = try await client.uploadFile(
                    at: file, name: name, mimeType: Self.pdfMimeType, inFolder: folderID, expectedSHA256: hash,
                    progress: Self.transferProgress(progress))
                // A same-named file with the wrong content would otherwise be found first forever.
                if let existing, existing.id != uploaded.id { try? await client.deleteFile(id: existing.id) }
            }
            progress?(1)
        }
    }

    @concurrent
    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        try await run(.pdf(sha256: hash)) { client in
            guard let found = try await self.findPDF(hash, client) else {
                throw BackupError.pdfNotAtDestination(sha256: hash)
            }
            do {
                try await client.downloadFile(id: found.id, to: file, expectedSHA256: hash,
                                              progress: Self.transferProgress(progress))
            } catch GoogleDriveError.checksumMismatch {
                // The contract: nothing at the local URL when the bytes are wrong.
                try? FileManager.default.removeItem(at: file)
                throw BackupError.contentMismatch(name: BackupFolderLayout.pdfFileName(sha256: hash))
            }
            progress?(1)
        }
    }

    // MARK: - Internals

    /// Runs `body` with the client, mapping its errors and telling the account when Google
    /// refused the sign-in.
    private func run<T: Sendable>(_ subject: CloudErrorSubject,
                                  _ body: (GoogleDriveClient) async throws -> T) async throws -> T {
        guard let client else { throw CloudBackupError.notSetUp(destination: displayName) }
        do {
            return try await body(client)
        } catch {
            let mapped = CloudBackupError.mapping(google: error, subject: subject)
            if let cloud = mapped as? CloudBackupError {
                let account = account
                switch cloud {
                case .needsSignInAgain: await account.noteNeedsSignInAgain()
                case .notSignedIn: await account.noteSignedOut()
                default: break
                }
            }
            throw mapped
        }
    }

    /// The PDF file named `<hash>.pdf`, looking the folder up again when it has gone.
    private func findPDF(_ hash: String, _ client: GoogleDriveClient) async throws -> GoogleDriveFile? {
        let name = BackupFolderLayout.pdfFileName(sha256: hash)
        if let found = try await client.file(named: name, inFolder: try await folder(.pdfs, client)) { return found }
        guard try await recoverIfGone(.pdfs, client) else { return nil }
        return try await client.file(named: name, inFolder: try await folder(.pdfs, client))
    }

    /// Runs an upload into the folder with `role`: checks a folder ID that has not been checked
    /// recently is still usable first, and when Drive says the parent is not found, looks the
    /// folders up again and retries once.
    private func intoFolder<T: Sendable>(_ role: FolderRole, _ client: GoogleDriveClient,
                                         _ body: (String) async throws -> T) async throws -> T {
        _ = try await recoverIfGone(role, client)
        do {
            return try await body(try await folder(role, client))
        } catch GoogleDriveError.notFound {
            await folders.invalidate()
            return try await body(try await folder(role, client))
        }
    }

    private func folder(_ role: FolderRole, _ client: GoogleDriveClient) async throws -> String {
        let ids = try await folders.ids(client)
        return role == .pdfs ? ids.pdfs : ids.backups
    }

    /// When the folder's ID was last confirmed more than `folderRecheckInterval` ago, checks it
    /// is still there and not in the trash; when it is gone, forgets the IDs and returns `true` so
    /// the caller looks again.
    private func recoverIfGone(_ role: FolderRole, _ client: GoogleDriveClient) async throws -> Bool {
        let id = try await folder(role, client)
        guard await folders.needsRecheck(role, after: Self.folderRecheckInterval) else { return false }
        let gone: Bool
        do {
            let file = try await client.file(id: id)
            gone = file.trashed || !file.isFolder
        } catch GoogleDriveError.notFound {
            gone = true
        }
        if gone {
            await folders.invalidate()
        } else {
            await folders.markChecked(role)
        }
        return gone
    }

    static func snapshotInfo(_ file: GoogleDriveFile) -> BackupSnapshotInfo? {
        guard !file.isFolder, !file.trashed, isSnapshotName(file.name), let parsed = SnapshotName.parse(file.name) else {
            return nil
        }
        return BackupSnapshotInfo(id: file.id, name: file.name, createdAt: parsed.createdAt,
                                  deviceName: parsed.deviceName, byteSize: file.size ?? 0)
    }

    static func isSnapshotName(_ name: String) -> Bool {
        !name.contains("/") && !name.hasPrefix(".") && SnapshotName.parse(name) != nil
    }

    static func matches(_ file: GoogleDriveFile?, hash: String, size: Int64) -> Bool {
        guard let file, file.size == size else { return false }
        return file.sha256Checksum.map { $0.lowercased() == hash } ?? true
    }

    static func validHash(_ sha256: String) throws -> String {
        let hash = sha256.lowercased()
        guard ContentHash.isValidSHA256(hash) else { throw BackupError.pdfNotAtDestination(sha256: sha256) }
        return hash
    }

    static func transferProgress(_ progress: BackupProgress?) -> GoogleTransferProgressHandler? {
        guard let progress else { return nil }
        return { transfer in progress(min(1, max(0, transfer.fractionCompleted))) }
    }
}

/// The three folder IDs, resolved once (concurrent callers share one lookup).
private actor FolderCache {
    struct IDs: Sendable {
        var backups: String
        var pdfs: String
    }

    private var ids: IDs?
    private var lookup: Task<IDs, any Error>?
    private var checkedAt: [GoogleDriveBackupDestination.FolderRole: Date] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) { self.now = now }

    func ids(_ client: GoogleDriveClient) async throws -> IDs {
        if let ids { return ids }
        if let lookup { return try await lookup.value }
        let task = Task { try await Self.resolve(client) }
        lookup = task
        do {
            let resolved = try await task.value
            if lookup == task {
                ids = resolved
                lookup = nil
                let now = now()
                checkedAt = [.backups: now, .pdfs: now]
            }
            return resolved
        } catch {
            if lookup == task { lookup = nil }
            throw error
        }
    }

    func invalidate() {
        ids = nil
        lookup = nil
        checkedAt = [:]
    }

    func needsRecheck(_ role: GoogleDriveBackupDestination.FolderRole, after interval: TimeInterval) -> Bool {
        guard ids != nil, let checked = checkedAt[role] else { return false }
        return now().timeIntervalSince(checked) > interval
    }

    func markChecked(_ role: GoogleDriveBackupDestination.FolderRole) {
        checkedAt[role] = now()
    }

    private static func resolve(_ client: GoogleDriveClient) async throws -> IDs {
        typealias Role = GoogleDriveBackupDestination.FolderRole
        let root = try await client.findOrCreateFolder(
            named: GoogleDriveBackupDestination.rootFolderName, role: Role.root.rawValue, inParent: nil)
        let backups = try await client.findOrCreateFolder(
            named: BackupFolderLayout.backupsDirectory, role: Role.backups.rawValue, inParent: root.id)
        let pdfs = try await client.findOrCreateFolder(
            named: BackupFolderLayout.pdfsDirectory, role: Role.pdfs.rawValue, inParent: root.id)
        return IDs(backups: backups.id, pdfs: pdfs.id)
    }
}
