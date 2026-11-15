import Foundation

/// Whether a destination can be used right now.
public enum BackupDestinationAvailability: Hashable, Sendable {
    case available
    /// Not usable; `reason` is shown to the reader as is (for example "This folder can’t be
    /// found. It may have been moved or deleted." or "iCloud isn’t available in this build.").
    case unavailable(reason: String)

    /// `true` for `.available`.
    public var isAvailable: Bool { self == .available }
}

/// A snapshot archive stored at a destination.
public struct BackupSnapshotInfo: Hashable, Sendable, Identifiable {
    /// The destination's own handle for the snapshot (the file name for a folder, a file ID for
    /// Google Drive). Pass the info back to the same destination to download or delete it.
    public var id: String
    /// The snapshot's file name (`SnapshotName`).
    public var name: String
    /// When the backup was made (from the name, to the second).
    public var createdAt: Date
    /// The device that made it (from the name, sanitised).
    public var deviceName: String
    /// Size of the archive in bytes.
    public var byteSize: Int64

    public init(id: String, name: String, createdAt: Date, deviceName: String, byteSize: Int64) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.byteSize = byteSize
    }

    /// Newest first; ties (same second) by name, descending, so the order is total.
    public static func newestFirst(_ a: BackupSnapshotInfo, _ b: BackupSnapshotInfo) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.name > b.name
    }
}

/// A place backups go in the folder layout (`BackupFolderLayout`): snapshot archives under
/// `Backups/`, PDFs addressed by hash under `PDFs/`. The Folder, iCloud and Google Drive
/// destinations implement it; the backup engine only talks to this protocol.
///
/// Contract every implementation keeps:
/// - Writes are all-or-nothing: a failed or cancelled upload leaves no partial snapshot or PDF
///   visible under its final name.
/// - Cancellation (of the calling task) throws `CancellationError`; failures throw `BackupError`.
/// - `downloadPDF` verifies the downloaded bytes against `sha256` before returning and leaves
///   nothing at the local URL when they differ (`contentMismatch`).
/// - Progress callbacks report the fraction of the transfer, ending at 1 on success.
public protocol BackupDestination: Sendable {
    /// Stable identifier, used to remember the chosen destination (for example `folder:<path>`).
    var id: String { get }
    /// Name shown in the destination list.
    var displayName: String { get }

    /// Whether the destination can be used now, and if not why (reader-facing).
    func availability() async -> BackupDestinationAvailability

    /// The snapshots at the destination, newest first (`BackupSnapshotInfo.newestFirst`).
    /// Files that are not snapshot archives are ignored.
    func listSnapshots() async throws -> [BackupSnapshotInfo]

    /// Uploads the local archive at `file` as snapshot `name` (a `SnapshotName`), replacing a
    /// snapshot of the same name. Returns the stored snapshot.
    @discardableResult
    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo

    /// Downloads `snapshot` to the local file `file` (replacing any file there).
    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws

    /// Deletes `snapshot`. Deleting one that is already gone succeeds.
    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws

    /// `true` when the destination holds the PDF with this hash at this size.
    func hasPDF(sha256: String, size: Int64) async throws -> Bool

    /// Uploads the local PDF at `file`, whose hash and size the caller has computed, unless the
    /// destination already holds it with that size. The bytes are verified against `sha256`.
    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws

    /// Downloads the PDF with this hash to the local file `file`, verified (see above). Throws
    /// `pdfNotAtDestination` when it is not there.
    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws
}
