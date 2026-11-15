import Foundation
import ReaderBackup

/// The folder and iCloud destinations the app offers, built once by the composition root.
nonisolated struct FolderAndICloudDestinations: Sendable {
    /// Remembers the picked folder; the UI calls `setFolder(_:)` with the document picker's URL.
    let folderStore: BackupFolderStore
    let folder: PickedFolderBackupDestination
    let iCloud: ICloudBackupDestination

    /// Both, in the order they are listed: always offered, each reporting itself unavailable
    /// (no folder chosen yet; no iCloud in this build or no account) when it is.
    var all: [any BackupDestination] { [folder, iCloud] }
}

/// Builds the folder and iCloud destinations.
nonisolated enum BackupDestinationFactory {
    /// The destinations with the system's bookmarks, file coordination and iCloud. `defaults`
    /// holds the picked folder's bookmark.
    static func folderAndICloud(defaults: UserDefaults = .standard) -> FolderAndICloudDestinations {
        let store = BackupFolderStore(defaults: defaults)
        return FolderAndICloudDestinations(folderStore: store,
                                           folder: PickedFolderBackupDestination(store: store),
                                           iCloud: ICloudBackupDestination())
    }
}
