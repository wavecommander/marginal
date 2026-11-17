import Foundation
import ReaderBackup

/// Builds the destinations that depend on how the app was built.
///
/// The app has no destination of its own for iCloud Drive, Google Drive or any other storage
/// that Files shows: the reader picks a folder there with the system's picker
/// (`PickedFolderBackupDestination`), and saves or opens a single backup file the same way.
nonisolated enum BackupDestinationFactory {
    /// The developer's S3-compatible bucket, or `nil` unless the build names one with its keys
    /// (`S3BackupConfiguration`).
    static func s3(infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
                   urlSession: URLSession = .shared) -> S3BackupDestination? {
        S3BackupConfiguration.fromInfoDictionary(infoDictionary).map {
            S3BackupDestination(configuration: $0, urlSession: urlSession)
        }
    }
}
