import Foundation
import ReaderBackup

/// The folder layout over one directory, every access coordinated, with iCloud's
/// not-yet-downloaded items handled. The picked-folder destination runs its operations through
/// one of these, built for the root it resolved for that operation.
///
/// It wraps `FolderBackupDestination` (which owns the layout, atomic writes, verification and
/// skip-if-present) and adds:
/// - **Coordination.** The access hook runs every access under `BackupFileCoordinating` with the
///   intent's coordination: reads of the root folder (the availability check) are metadata-only;
///   other reads (listing `Tactile Texts Backups/`, reading a snapshot or PDF) are plain coordinated reads;
///   writes are `.forReplacing`; deletes `.forDeleting`.
/// - **Items not downloaded yet.** Listing adds snapshots that exist only as iCloud
///   placeholders; `hasPDF` and `uploadPDF` count a placeholder of the right size as present;
///   downloads ask iCloud for the item and wait (`BackupDownloadWaitPolicy`) before the
///   coordinated read, so a read never sits waiting on a download without a timeout; deleting
///   a snapshot also removes its placeholder.
///
/// Blocking file work runs on the calling task, which callers keep off the main actor.
nonisolated struct CoordinatedBackupFolder: Sendable {
    let root: URL
    let coordinator: any BackupFileCoordinating
    let ubiquity: any BackupUbiquitousItemControl
    let downloadWait: BackupDownloadWaitPolicy
    let folder: FolderBackupDestination

    init(root: URL, id: String, displayName: String, coordinator: any BackupFileCoordinating,
         ubiquity: any BackupUbiquitousItemControl, downloadWait: BackupDownloadWaitPolicy) {
        self.root = root
        self.coordinator = coordinator
        self.ubiquity = ubiquity
        self.downloadWait = downloadWait
        // New snapshots go in `Tactile Texts Backups/`; ones already in `Backups/` stay usable.
        self.folder = FolderBackupDestination(root: root, id: id, displayName: displayName,
                                              backupsDirectory: BackupFolderLayout.localBackupsDirectory,
                                              legacyBackupsDirectories: [BackupFolderLayout.backupsDirectory],
                                              access: Self.accessHook(root: root, coordinator: coordinator))
    }

    /// The hook `FolderBackupDestination` calls for every access.
    static func accessHook(root: URL, coordinator: any BackupFileCoordinating) -> FolderBackupDestination.AccessHook {
        let rootPath = root.standardizedFileURL.path
        return { url, intent, body in
            let kind: BackupFileCoordination
            switch intent {
            case .read: kind = url.standardizedFileURL.path == rootPath ? .readingMetadataOnly : .reading
            case .write: kind = .writingForReplacing
            case .delete: kind = .deleting
            }
            try coordinator.coordinate(url, kind, body)
        }
    }

    // MARK: - Operations

    func availability() async -> BackupDestinationAvailability {
        await folder.availability()
    }

    func listSnapshots() async throws -> [BackupSnapshotInfo] {
        var snapshots = try await folder.listSnapshots()
        let known = Set(snapshots.map(\.name))
        snapshots += try placeholderSnapshots().filter { !known.contains($0.name) }
        return snapshots.sorted(by: BackupSnapshotInfo.newestFirst)
    }

    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        try await folder.uploadSnapshot(from: file, name: name, progress: progress)
    }

    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        if SnapshotName.parse(snapshot.id) != nil, !snapshot.id.contains("/") {
            try await ensureDownloaded(try existingSnapshotURL(snapshot.id), displayName: snapshot.name)
        }
        try await folder.downloadSnapshot(snapshot, to: file, progress: progress)
    }

    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        try await folder.deleteSnapshot(snapshot)
        // A snapshot that is only in iCloud is represented here by its placeholder.
        for url in snapshotURLs(snapshot.id) {
            try coordinator.coordinate(url, .deleting) { granted in
                let placeholder = BackupICloudPlaceholder.placeholderURL(for: granted)
                guard FileManager.default.fileExists(atPath: placeholder.path) else { return }
                try BackupFileCoordinationError.mapping(placeholder) { try FileManager.default.removeItem(at: placeholder) }
            }
        }
    }

    func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        guard let url = pdfURL(sha256) else { return try await folder.hasPDF(sha256: sha256, size: size) }
        try Task.checkCancellation()
        var present = false
        try coordinator.coordinate(url, .readingMetadataOnly) { granted in
            if Self.regularFileSize(granted) == size {
                present = true
            } else if Self.regularFileSize(granted) == nil {
                present = BackupICloudPlaceholder.recordedSize(at: BackupICloudPlaceholder.placeholderURL(for: granted)) == size
            }
        }
        return present
    }

    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        if try await hasPDF(sha256: sha256, size: size) {
            progress?(1)
            return
        }
        try await folder.uploadPDF(from: file, sha256: sha256, size: size, progress: progress)
    }

    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        if let url = pdfURL(sha256) {
            try await ensureDownloaded(url, displayName: url.lastPathComponent)
        }
        try await folder.downloadPDF(sha256: sha256, to: file, progress: progress)
    }

    func uploadState(of snapshot: BackupSnapshotInfo) -> BackupUploadState {
        guard SnapshotName.parse(snapshot.id) != nil, !snapshot.id.contains("/"),
              let url = try? existingSnapshotURL(snapshot.id),
              let status = ubiquity.status(of: url) else { return .notTracked }
        if status.isUploaded { return .uploaded }
        if let error = status.uploadingError {
            return .failed(reason: BackupFileCoordinationError.translate(error, url: url).localizedDescription)
        }
        return status.isUploading ? .uploading : .waiting
    }

    // MARK: - Not-downloaded items

    /// Snapshots in the backups folders present only as iCloud placeholders.
    private func placeholderSnapshots() throws -> [BackupSnapshotInfo] {
        var found: [BackupSnapshotInfo] = []
        for directoryName in folder.snapshotDirectories {
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            try Task.checkCancellation()
            try coordinator.coordinate(directory, .reading) { granted in
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: granted.path) else { return }
                for fileName in names {
                    guard let name = BackupICloudPlaceholder.itemName(forPlaceholder: fileName),
                          !name.contains("/"), let parsed = SnapshotName.parse(name),
                          let size = BackupICloudPlaceholder.recordedSize(at: granted.appendingPathComponent(fileName, isDirectory: false))
                    else { continue }
                    found.append(BackupSnapshotInfo(id: name, name: name, createdAt: parsed.createdAt,
                                                    deviceName: parsed.deviceName, byteSize: size))
                }
            }
        }
        return found
    }

    /// When `url` is an iCloud item that is not on this device (a placeholder, or a dataless item
    /// iCloud reports as not downloaded), asks iCloud for it and waits until it is here. Returns
    /// at once for local items and for items that do not exist (the read that follows reports
    /// those).
    func ensureDownloaded(_ url: URL, displayName name: String) async throws {
        var (real, placeholder) = try inspect(url)
        let status = ubiquity.status(of: url)
        let notDownloaded = placeholder || (status.map { !$0.isDownloaded } ?? false)
        guard notDownloaded else { return }

        do {
            try ubiquity.startDownloading(url)
        } catch {
            throw BackupFileCoordinationError.translate(error, url: url)
        }
        var elapsed: Duration = .zero
        var started = false
        while true {
            try Task.checkCancellation()
            if let current = ubiquity.status(of: url) {
                if current.isDownloaded { return }
                if current.downloadingError != nil { throw BackupDownloadFailure.failed(name) }
                if current.isDownloading { started = true }
            } else {
                (real, placeholder) = try inspect(url)
                if real, !placeholder { return }
            }
            if !started, elapsed >= downloadWait.startTimeout { throw BackupDownloadFailure.notStarted(name) }
            if elapsed >= downloadWait.timeout { throw BackupDownloadFailure.timedOut(name) }
            try await downloadWait.sleep(downloadWait.pollInterval)
            elapsed += downloadWait.pollInterval
        }
    }

    /// Whether `url` is a regular file and whether its placeholder exists, read without
    /// waiting for a download.
    private func inspect(_ url: URL) throws -> (real: Bool, placeholder: Bool) {
        var result = (real: false, placeholder: false)
        try coordinator.coordinate(url, .readingMetadataOnly) { granted in
            result.real = Self.regularFileSize(granted) != nil
            result.placeholder = FileManager.default.fileExists(atPath: BackupICloudPlaceholder.placeholderURL(for: granted).path)
        }
        return result
    }

    // MARK: - Paths

    /// `name` in each backups folder, the one new snapshots go to first.
    private func snapshotURLs(_ name: String) -> [URL] {
        folder.snapshotDirectories.map {
            root.appendingPathComponent($0, isDirectory: true).appendingPathComponent(name, isDirectory: false)
        }
    }

    /// Where the snapshot `name` is: the first backups folder holding it (a file or an iCloud
    /// placeholder), or the folder new snapshots go to when none does.
    private func existingSnapshotURL(_ name: String) throws -> URL {
        let urls = snapshotURLs(name)
        for url in urls {
            let (real, placeholder) = try inspect(url)
            if real || placeholder { return url }
        }
        return urls[0]
    }

    /// `PDFs/<sha256>.pdf`, or `nil` for a malformed hash (left to `FolderBackupDestination` to
    /// reject).
    private func pdfURL(_ sha256: String) -> URL? {
        let hash = sha256.lowercased()
        guard ContentHash.isValidSHA256(hash) else { return nil }
        return root.appendingPathComponent(BackupFolderLayout.pdfsDirectory, isDirectory: true)
            .appendingPathComponent(BackupFolderLayout.pdfFileName(sha256: hash), isDirectory: false)
    }

    /// Size of the regular file at `url` (`stat`, which reports a dataless file's full size
    /// without downloading it), or `nil` when there is none.
    static func regularFileSize(_ url: URL) -> Int64? {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }
}
