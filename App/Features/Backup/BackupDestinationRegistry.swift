import Foundation
import Observation
import ReaderBackup

/// The backup destinations the app offers (the Backup screen lists `entries`). One per app,
/// owned by `AppEnvironment`. Each destination registers itself (Folder, iCloud, Google Drive,
/// S3-compatible); `-backupFolder <path>` registers a `FolderBackupDestination` for UI tests.
@Observable
@MainActor
final class BackupDestinationRegistry {
    /// One destination.
    struct Entry: Identifiable {
        /// `destination.id`: stable, used to remember the chosen destination and its last backup.
        let id: String
        /// The name the list shows.
        let displayName: String
        let destination: any BackupDestination
    }

    /// Destinations in registration order.
    private(set) var entries: [Entry] = []

    init() {}

    /// Adds `destination`, or replaces the entry with the same `id` in place.
    func register(_ destination: any BackupDestination, displayName: String? = nil) {
        let entry = Entry(id: destination.id, displayName: displayName ?? destination.displayName, destination: destination)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Removes the destination with this ID (no-op if unknown).
    func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// The destination with this ID, or `nil`.
    func destination(id: String) -> (any BackupDestination)? {
        entries.first { $0.id == id }?.destination
    }
}
