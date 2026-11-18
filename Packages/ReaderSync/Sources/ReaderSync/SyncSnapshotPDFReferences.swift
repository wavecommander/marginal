import Foundation
import ReaderBackup

/// Why the snapshot backups could not all be read and checked (housekeeping then removes no PDF).
public enum SyncSnapshotReferenceError: Error, Hashable, Sendable {
    /// An object under `Backups/` is not a snapshot this key opens.
    case unreadableSnapshot(name: String)
}

/// The PDFs the account's snapshot backups refer to (`SyncSnapshotReferences`), read through its
/// `EncryptedBackupDestination`: every snapshot is downloaded once and its manifest read (the
/// SHA-256 of each book's PDF); what a snapshot refers to is kept in `cacheDirectory` by its
/// object name and size, so later runs download only new snapshots.
///
/// Every object under `Backups/` must be a snapshot that opens with the key, and every snapshot
/// must download and open; otherwise this throws and housekeeping removes no PDF.
public struct SyncSnapshotPDFReferences: SyncSnapshotReferences {
    public let destination: EncryptedBackupDestination
    /// Device-local, one per account (`Application Support/Sync/<account>/snapshots`).
    public let cacheDirectory: URL

    public init(destination: EncryptedBackupDestination, cacheDirectory: URL) {
        self.destination = destination
        self.cacheDirectory = cacheDirectory
    }

    public func referencedPDFs() async throws -> Set<String> {
        let objects = try await destination.store.list(.backups)
        let snapshots = try await destination.listSnapshots()
        let listed = Set(snapshots.map(\.id))
        if let stranger = objects.first(where: { !listed.contains($0.name) }) {
            throw SyncSnapshotReferenceError.unreadableSnapshot(name: stranger.name)
        }
        var cache = loadCache()
        var kept: [String: [String]] = [:]
        var result = Set<String>()
        for snapshot in snapshots {
            try Task.checkCancellation()
            let cacheKey = "\(snapshot.id)#\(snapshot.byteSize)"
            if let hashes = cache[cacheKey] {
                kept[cacheKey] = hashes
                result.formUnion(hashes)
                continue
            }
            let hashes = try await pdfHashes(of: snapshot)
            kept[cacheKey] = hashes
            cache[cacheKey] = hashes
            result.formUnion(hashes)
        }
        saveCache(kept)
        return result
    }

    private func pdfHashes(of snapshot: BackupSnapshotInfo) async throws -> [String] {
        let folder = cacheDirectory.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(UUID().uuidString).ttbackup", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: file) }
        try await destination.downloadSnapshot(snapshot, to: file, progress: nil)
        let reader = try BackupArchiveReader(url: file)
        return reader.manifest.books.map { $0.pdf.sha256.lowercased() }.sorted()
    }

    private var cacheFile: URL { cacheDirectory.appendingPathComponent("snapshot-pdfs.json", isDirectory: false) }

    private func loadCache() -> [String: [String]] {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return cache
    }

    private func saveCache(_ cache: [String: [String]]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}
