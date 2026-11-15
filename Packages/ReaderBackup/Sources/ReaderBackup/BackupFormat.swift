import Foundation

/// Constants of the backup format that the app's configuration also names (`project.yml` declares
/// the exported type and the document type with the same identifier and extension).
public enum BackupFormat {
    /// `manifest.json`'s `format` value.
    public static let name = "tactile-texts-backup"
    /// The format version this build writes, and the highest it reads.
    public static let currentVersion = 1
    /// File extension of a snapshot archive, without the dot.
    public static let fileExtension = "ttbackup"
    /// Uniform type identifier of a snapshot archive (exported by the app).
    public static let typeIdentifier = "software.tactile.marginal.backup"
}
