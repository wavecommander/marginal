import CoreData
import Foundation
import SQLite3
import SwiftData

/// The store file's schema version, the copies kept of it, and the two ways back into a library
/// this build cannot open as it is (docs/DESIGN.md "A library from a newer version").
///
/// - **Version check.** `state` compares the store's metadata with every version in
///   `MarginalMigrationPlan`. SwiftData stores carry no version number, only per-entity hashes, so
///   a store that matches none of them is reported as `.newer`: a newer build wrote it (the
///   ordinary case: a newer build was installed, then an older one).
/// - **Copies.** Before a store changes version (an update's migration, opening a newer library
///   in this version) and before a copy is put back over it, the store is copied to
///   `Database Copies/<stamp>-<reason>/`. The newest `copiesKept` are kept. Copies are single
///   files (the SQLite journal folded in), so one can be put back with one atomic replace.
/// - **Open in this version.** A newer store is converted down to this build's version by Core
///   Data's inferred (lightweight) migration, using the newer model Core Data caches inside every
///   store. This works while each version only adds optional columns or entities (the schema
///   rule in AGENTS.md); whatever this version has no column for is left out. The conversion runs
///   on a copy and replaces the store only when it succeeded.
///
/// Every function here works on closed store files: call them before `LibraryStore.live` opens
/// the store, or while the app runs on its stand-in store. They do file I/O and may take a moment
/// on a large library, so the app calls them off the main actor.
public enum LibraryDatabase {
    /// What the store file under a root directory is, to this build.
    public enum State: Hashable, Sendable {
        /// No store file yet (a first launch).
        case empty
        /// This build's version.
        case current
        /// An earlier version, which opening migrates.
        case earlier
        /// No version this build knows: written by a newer build.
        case newer
        /// The file's metadata could not be read (damaged, or not a store).
        case unreadable(String)
    }

    /// Why a copy was made.
    public enum CopyReason: String, Codable, Hashable, Sendable {
        /// Before an update migrated the library to this build's version.
        case beforeUpdate
        /// Before a newer library was opened in this version.
        case beforeOpeningInThisVersion
        /// The library as it was when another copy was put back over it.
        case setAside
    }

    /// One kept copy of the store.
    public struct Copy: Identifiable, Hashable, Sendable {
        /// The copy's folder name, unique among the copies.
        public let id: String
        public let date: Date
        public let reason: CopyReason
        /// What the copied store is, to this build.
        public let state: State
        let folder: URL

        /// Whether this build can open the copy (put it back and open it).
        public var canBeUsed: Bool { state == .current || state == .earlier }
        var storeURL: URL { folder.appendingPathComponent(ReaderStore.databaseFileName) }
    }

    /// The folder beside `Database` that holds the copies.
    public static let copiesDirectoryName = "Database Copies"
    /// How many copies are kept (the newest).
    public static let copiesKept = 3

    // MARK: Version check

    /// What the store under `rootDirectory` is, to this build.
    public static func state(rootDirectory: URL) -> State {
        state(ofStoreAt: storeURL(rootDirectory: rootDirectory))
    }

    /// What the store at `url` is, judged against `schemas` with `current` as this build's version.
    static func state(ofStoreAt url: URL, schemas: [any VersionedSchema.Type] = MarginalMigrationPlan.schemas,
                      current: any VersionedSchema.Type = SchemaFactory.currentVersion) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        } catch {
            return .unreadable(String(describing: error))
        }
        if matches(current, metadata) { return .current }
        for schema in schemas where ObjectIdentifier(schema) != ObjectIdentifier(current) && matches(schema, metadata) {
            return .earlier
        }
        return .newer
    }

    private static func matches(_ schema: any VersionedSchema.Type, _ metadata: [String: Any]) -> Bool {
        guard let model = managedObjectModel(for: schema) else { return false }
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    static func managedObjectModel(for schema: any VersionedSchema.Type) -> NSManagedObjectModel? {
        NSManagedObjectModel.makeManagedObjectModel(for: schema.models)
    }

    // MARK: Copies

    /// The kept copies, newest first.
    public static func copies(rootDirectory: URL) -> [Copy] {
        let directory = copiesDirectory(rootDirectory: rootDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name -> Copy? in
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(infoFileName)),
                  let info = try? JSONDecoder().decode(CopyInfo.self, from: data) else { return nil }
            let store = folder.appendingPathComponent(ReaderStore.databaseFileName)
            return Copy(id: name, date: info.date, reason: info.reason, state: state(ofStoreAt: store), folder: folder)
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Copies the store under `rootDirectory` (with its journal) into a new copy folder, then
    /// removes the oldest copies beyond `copiesKept`. Throws `ReaderStoreError.copyFailed` with
    /// nothing left behind if the copy cannot be made.
    @discardableResult
    static func makeCopy(rootDirectory: URL, reason: CopyReason, now: Date = Date()) throws -> Copy {
        let fileManager = FileManager.default
        let source = storeURL(rootDirectory: rootDirectory)
        let name = "\(stamp(now))-\(reason.rawValue)-\(UUID().uuidString.prefix(6))"
        let folder = copiesDirectory(rootDirectory: rootDirectory).appendingPathComponent(name, isDirectory: true)
        let copied = folder.appendingPathComponent(ReaderStore.databaseFileName)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try copyStoreFiles(from: source, to: copied)
            // Best effort: a store SQLite cannot open keeps its journal beside it in the copy.
            try? foldJournal(storeAt: copied)
            try JSONEncoder().encode(CopyInfo(date: now, reason: reason))
                .write(to: folder.appendingPathComponent(infoFileName), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw ReaderStoreError.copyFailed(String(describing: error))
        }
        pruneCopies(rootDirectory: rootDirectory)
        return Copy(id: name, date: now, reason: reason, state: state(ofStoreAt: copied), folder: folder)
    }

    // MARK: Ways back in

    /// Converts the newer store under `rootDirectory` to this build's version, after keeping a
    /// copy of it as it was (`CopyReason.beforeOpeningInThisVersion`). Every record is kept;
    /// columns and entities this version does not have are left out. Throws, with the store
    /// unchanged, if the store is not `.newer` or cannot be converted.
    public static func openInThisVersion(rootDirectory: URL) throws {
        try convertNewerStore(rootDirectory: rootDirectory, to: SchemaFactory.currentVersion,
                              schemas: MarginalMigrationPlan.schemas)
    }

    static func convertNewerStore(rootDirectory: URL, to target: any VersionedSchema.Type,
                                  schemas: [any VersionedSchema.Type]) throws {
        let live = storeURL(rootDirectory: rootDirectory)
        guard state(ofStoreAt: live, schemas: schemas, current: target) == .newer else {
            throw ReaderStoreError.cannotOpenInThisVersion("the library is not from a newer version")
        }
        guard let model = managedObjectModel(for: target) else {
            throw ReaderStoreError.cannotOpenInThisVersion("this version's model could not be built")
        }
        let copy = try makeCopy(rootDirectory: rootDirectory, reason: .beforeOpeningInThisVersion)
        let working = try workingCopy(of: copy.storeURL, rootDirectory: rootDirectory)
        defer { try? FileManager.default.removeItem(at: working.deletingLastPathComponent()) }
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            // History tracking must match the store SwiftData wrote, or the migration fails with
            // "attempt to write a readonly database".
            let options: [String: Any] = [NSMigratePersistentStoresAutomaticallyOption: true,
                                          NSInferMappingModelAutomaticallyOption: true,
                                          NSPersistentHistoryTrackingKey: true]
            let store = try coordinator.addPersistentStore(type: .sqlite, at: working, options: options)
            try coordinator.remove(store)
            try foldJournal(storeAt: working)
        } catch {
            throw ReaderStoreError.cannotOpenInThisVersion(String(describing: error))
        }
        guard state(ofStoreAt: working, schemas: schemas, current: target) == .current else {
            throw ReaderStoreError.cannotOpenInThisVersion("the converted library does not match this version")
        }
        try install(working, rootDirectory: rootDirectory)
    }

    /// Puts `copy` back as the library, after keeping the library as it is now
    /// (`CopyReason.setAside`). Throws, with the library unchanged, if this build cannot open the
    /// copy or it cannot be read.
    public static func putBack(_ copy: Copy, rootDirectory: URL) throws {
        let current = state(ofStoreAt: copy.storeURL)
        guard current == .current || current == .earlier else { throw ReaderStoreError.copyCannotBeUsed }
        // Taken first: making the set-aside copy may prune this one.
        let working = try workingCopy(of: copy.storeURL, rootDirectory: rootDirectory)
        defer { try? FileManager.default.removeItem(at: working.deletingLastPathComponent()) }
        do {
            try foldJournal(storeAt: working)
        } catch {
            throw ReaderStoreError.copyFailed(String(describing: error))
        }
        if FileManager.default.fileExists(atPath: storeURL(rootDirectory: rootDirectory).path) {
            try makeCopy(rootDirectory: rootDirectory, reason: .setAside)
        }
        try install(working, rootDirectory: rootDirectory)
    }

    // MARK: Files

    static func storeURL(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(ReaderStore.databaseDirectoryName, isDirectory: true)
            .appendingPathComponent(ReaderStore.databaseFileName)
    }

    static func copiesDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(copiesDirectoryName, isDirectory: true)
    }

    private static let infoFileName = "copy.json"
    private static let journalSuffixes = ["-wal", "-shm"]

    private struct CopyInfo: Codable {
        var date: Date
        var reason: CopyReason
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Copies a closed store and its write-ahead log (not the shared-memory index, which SQLite
    /// rebuilds from the log).
    private static func copyStoreFiles(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: source, to: destination)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if fileManager.fileExists(atPath: wal.path) {
            try fileManager.copyItem(at: wal, to: URL(fileURLWithPath: destination.path + "-wal"))
        }
    }

    /// A scratch copy of the store at `source` in a hidden folder under the copies directory
    /// (removed by the caller, and by the next prune if the app stops first).
    private static func workingCopy(of source: URL, rootDirectory: URL) throws -> URL {
        let folder = copiesDirectory(rootDirectory: rootDirectory)
            .appendingPathComponent(".working-\(UUID().uuidString)", isDirectory: true)
        let working = folder.appendingPathComponent(ReaderStore.databaseFileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try copyStoreFiles(from: source, to: working)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw ReaderStoreError.copyFailed(String(describing: error))
        }
        return working
    }

    /// Folds the write-ahead log into the store file and leaves it in rollback-journal mode, so
    /// the store is one file. Core Data switches it back to WAL when it next opens it.
    static func foldJournal(storeAt url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw ReaderStoreError.copyFailed("\(url.lastPathComponent): \(message)")
        }
        defer { sqlite3_close(db) }
        for statement in ["PRAGMA wal_checkpoint(TRUNCATE)", "PRAGMA journal_mode=DELETE"] {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw ReaderStoreError.copyFailed("\(statement): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// Makes the single-file store at `file` the library's store: the old journal goes first (a
    /// stale log would be replayed onto the new file), then one atomic replace. A copy of the old
    /// store was made before this is called.
    private static func install(_ file: URL, rootDirectory: URL) throws {
        let fileManager = FileManager.default
        let live = storeURL(rootDirectory: rootDirectory)
        do {
            try fileManager.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            for suffix in journalSuffixes {
                let journal = URL(fileURLWithPath: live.path + suffix)
                if fileManager.fileExists(atPath: journal.path) { try fileManager.removeItem(at: journal) }
            }
            if fileManager.fileExists(atPath: live.path) {
                _ = try fileManager.replaceItemAt(live, withItemAt: file)
            } else {
                try fileManager.moveItem(at: file, to: live)
            }
        } catch {
            throw ReaderStoreError.copyFailed(String(describing: error))
        }
    }

    /// Removes copies beyond the newest `copiesKept`, and scratch folders a stopped app left.
    private static func pruneCopies(rootDirectory: URL) {
        let fileManager = FileManager.default
        let directory = copiesDirectory(rootDirectory: rootDirectory)
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".working-") {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            // Only scratch folders older than a minute: one may belong to work running now.
            let modified = (try? fileManager.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
            if let modified, modified < Date().addingTimeInterval(-60) { try? fileManager.removeItem(at: folder) }
        }
        for copy in copies(rootDirectory: rootDirectory).dropFirst(copiesKept) {
            try? fileManager.removeItem(at: copy.folder)
        }
    }
}
