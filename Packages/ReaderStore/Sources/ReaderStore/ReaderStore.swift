import Foundation
import SwiftData
import ReaderCore

/// Namespace for the on-disk layout constants of the persistent store.
public enum ReaderStore {
    /// Directory under the root that holds the SwiftData store files.
    public static let databaseDirectoryName = "Database"
    /// The SwiftData store file name inside `databaseDirectoryName` (SQLite adds `-wal` and `-shm`).
    public static let databaseFileName = "Marginal.store"
}

extension LibraryStore {
    /// The app's persistent store: SwiftData records plus file-backed ink under `rootDirectory`
    /// (default: the app's Application Support directory, created if missing, not excluded from
    /// backup).
    ///
    /// On disk, everything lives under `rootDirectory`:
    /// - `Database/Marginal.store` (+ `-wal`, `-shm`): the SwiftData store.
    /// - `Database Copies/<stamp>-<reason>/`: copies of the store (`LibraryDatabase`).
    /// - `Books/<bookID>/...`: per `BookStorageLayout` (PDF copy, `ink/`, `notes/`, and for a
    ///   scanned book `text/` and `recognition.json`, through `FileRecognisedTextStore`).
    ///
    /// Creates one `ModelContainer` per call; the app calls this once and shares the result across
    /// all windows. **Durability:** every record mutation saves before it returns and every ink
    /// write is an atomic file write that completes before its `await` returns, so nothing is
    /// pending when the app is backgrounded and no save call is needed there.
    ///
    /// Before opening, the store's version is checked (`LibraryDatabase`): a store from a newer
    /// version is left untouched and this throws `ReaderStoreError.libraryFromNewerVersion`; a
    /// store from an earlier version is copied (`Database Copies/`) before it is migrated, and if
    /// that copy cannot be made this throws `ReaderStoreError.copyFailed` without migrating.
    ///
    /// - Parameter reset: deletes the `Database` directory, its copies and the `Books` tree first
    ///   (the `-resetState` launch argument). Throws `ReaderStoreError.resetFailed` if anything is left.
    @MainActor
    public static func live(rootDirectory: URL? = nil, reset: Bool = false) throws -> LibraryStore {
        let fileManager = FileManager.default
        let root = try rootDirectory ?? defaultRootDirectory()
        if reset { try removeAllData(rootDirectory: root) }
        let databaseDirectory = root.appendingPathComponent(ReaderStore.databaseDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let storeURL = databaseDirectory.appendingPathComponent(ReaderStore.databaseFileName)
        switch LibraryDatabase.state(ofStoreAt: storeURL) {
        case .newer:
            throw ReaderStoreError.libraryFromNewerVersion
        case .earlier:
            try LibraryDatabase.makeCopy(rootDirectory: root, reason: .beforeUpdate)
        case .empty, .current, .unreadable:
            // An unreadable file is left for SwiftData to open or report.
            break
        }
        let container = try SchemaFactory.makeContainer(storeURL: storeURL)
        let records = SwiftDataRecordStore(container: container)
        return LibraryStore(records: records, inkStore: FileInkStore(rootDirectory: root), rootDirectory: root,
                            recognisedText: FileRecognisedTextStore(rootDirectory: root))
    }

    /// The app's root directory: Application Support, created if missing.
    public static func defaultRootDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
    }

    /// Deletes the `Database` directory, its copies and the `Books` tree under `rootDirectory`
    /// (what `live(reset: true)` does first). Throws `ReaderStoreError.resetFailed` if anything is left.
    public static func removeAllData(rootDirectory root: URL) throws {
        for name in [ReaderStore.databaseDirectoryName, LibraryDatabase.copiesDirectoryName, "Books"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            do {
                try removeIfPresent(url, fileManager: FileManager.default)
            } catch {
                throw ReaderStoreError.resetFailed("\(url.path): \(error)")
            }
        }
    }

    /// A store for tests and previews: in-memory SwiftData and a unique directory in the temporary
    /// directory for ink and files (created lazily, never cleaned up automatically: remove
    /// `rootDirectory` when done).
    @MainActor
    public static func ephemeral() throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginalEphemeral-\(UUID().uuidString)", isDirectory: true)
        let container = try SchemaFactory.makeContainer(storeURL: nil)
        let records = SwiftDataRecordStore(container: container)
        return LibraryStore(records: records, inkStore: FileInkStore(rootDirectory: root), rootDirectory: root,
                            recognisedText: FileRecognisedTextStore(rootDirectory: root))
    }

    /// Removes `Books/<id>` directories under `rootDirectory` that have no `Book` record: the
    /// backstop for `LibraryStoreError.bookFilesNotRemoved`. Returns the IDs removed.
    ///
    /// Entries whose names are not UUIDs are left alone. Call it at launch, before any import can
    /// be in flight: an importer that creates the directory before saving the `Book` record
    /// would otherwise lose that directory. The directory scan and removal run off the main actor.
    @discardableResult
    public func sweepOrphanedBookDirectories() async throws -> [UUID] {
        let known = Set(try books.allBooks().map(\.id))
        let booksDirectory = rootDirectory.appendingPathComponent("Books", isDirectory: true)
        return try await Task.detached {
            let fileManager = FileManager()
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: booksDirectory.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                return []
            }
            var removed: [UUID] = []
            for name in names {
                guard let id = UUID(uuidString: name), !known.contains(id) else { continue }
                try fileManager.removeItem(at: booksDirectory.appendingPathComponent(name, isDirectory: true))
                removed.append(id)
            }
            return removed
        }.value
    }
}

private func removeIfPresent(_ url: URL, fileManager: FileManager) throws {
    do {
        try fileManager.removeItem(at: url)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain
        && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
        return
    }
}
