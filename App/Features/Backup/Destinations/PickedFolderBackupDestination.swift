import Foundation
import ReaderBackup

/// Backups in a folder the reader picked in Files (for example in iCloud Drive), in the folder
/// layout (`Backups/`, `PDFs/`).
///
/// Every operation resolves the bookmark (`BackupFolderStore`), holds security-scoped access to
/// the folder for the whole operation, and runs it through `CoordinatedBackupFolder`, so each
/// access is coordinated and items in iCloud Drive that are not downloaded yet are fetched first.
/// When the folder cannot be used, `availability()` says why and every other call throws
/// `BackupError.destinationUnavailable` with the same reason.
///
/// The `id` is fixed (`folder`), so a record of the last backup survives choosing the folder
/// again.
nonisolated struct PickedFolderBackupDestination: BackupDestination {
    static let destinationID = "folder"
    /// Display name when no folder has been chosen.
    static let unnamedDisplayName = "Folder"

    let store: BackupFolderStore
    private let coordinator: any BackupFileCoordinating
    private let ubiquity: any BackupUbiquitousItemControl
    private let downloadWait: BackupDownloadWaitPolicy

    init(store: BackupFolderStore, coordinator: any BackupFileCoordinating = SystemFileCoordinator(),
         ubiquity: any BackupUbiquitousItemControl = SystemUbiquitousItemControl(),
         downloadWait: BackupDownloadWaitPolicy = .standard) {
        self.store = store
        self.coordinator = coordinator
        self.ubiquity = ubiquity
        self.downloadWait = downloadWait
    }

    var id: String { Self.destinationID }

    /// The chosen folder's name, or "Folder" when none is chosen.
    var displayName: String { store.folderName ?? Self.unnamedDisplayName }

    @concurrent
    func availability() async -> BackupDestinationAvailability {
        switch store.resolveFolder() {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .resolved(let url, let name):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = await folder(at: url, name: name).availability()
            guard case .unavailable = result else { return result }
            // A folder that resolves but is gone (deleted, or its provider removed it): ask for a
            // new one. Other failures (a provider that is offline) keep the provider's reason.
            return folderExists(url) ? result : .unavailable(reason: BackupFolderStore.notFoundReason(name))
        }
    }

    @concurrent
    func listSnapshots() async throws -> [BackupSnapshotInfo] {
        try await withFolder { try await $0.listSnapshots() }
    }

    @concurrent
    @discardableResult
    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        try await withFolder { try await $0.uploadSnapshot(from: file, name: name, progress: progress) }
    }

    @concurrent
    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        try await withFolder { try await $0.downloadSnapshot(snapshot, to: file, progress: progress) }
    }

    @concurrent
    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        try await withFolder { try await $0.deleteSnapshot(snapshot) }
    }

    @concurrent
    func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        try await withFolder { try await $0.hasPDF(sha256: sha256, size: size) }
    }

    @concurrent
    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        try await withFolder { try await $0.uploadPDF(from: file, sha256: sha256, size: size, progress: progress) }
    }

    @concurrent
    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        try await withFolder { try await $0.downloadPDF(sha256: sha256, to: file, progress: progress) }
    }

    /// Whether `snapshot` has reached the folder's provider (iCloud Drive reports this; a local
    /// folder is `.notTracked`).
    @concurrent
    func uploadState(of snapshot: BackupSnapshotInfo) async -> BackupUploadState {
        (try? await withFolder { $0.uploadState(of: snapshot) }) ?? .notTracked
    }

    // MARK: - Internals

    /// Runs `body` with the resolved folder, holding security-scoped access throughout.
    private func withFolder<T>(_ body: (CoordinatedBackupFolder) async throws -> T) async throws -> T {
        switch store.resolveFolder() {
        case .unavailable(let reason):
            throw BackupError.destinationUnavailable(reason: reason)
        case .resolved(let url, let name):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Never recreate a folder that was deleted: writes create missing parents.
            guard folderExists(url) else { throw BackupError.destinationUnavailable(reason: BackupFolderStore.notFoundReason(name)) }
            return try await body(folder(at: url, name: name))
        }
    }

    /// `false` only when the folder is known to be gone; a provider that can't answer now is
    /// left to the operation itself to report.
    private func folderExists(_ url: URL) -> Bool {
        var exists = true
        do {
            try coordinator.coordinate(url, .readingMetadataOnly) { granted in
                var isDirectory: ObjCBool = false
                exists = FileManager.default.fileExists(atPath: granted.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        } catch BackupError.fileNotFound {
            exists = false
        } catch {}
        return exists
    }

    private func folder(at url: URL, name: String) -> CoordinatedBackupFolder {
        CoordinatedBackupFolder(root: url, id: id, displayName: name, coordinator: coordinator,
                                ubiquity: ubiquity, downloadWait: downloadWait)
    }
}
