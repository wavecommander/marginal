#if DEBUG
import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync

/// `-syncTestFolder <path>` (DEBUG): sync against a folder, with no network. The folder stands
/// for one account: `objects/` the account's sync objects (`FolderSyncObjectStore`), `account/`
/// its backup objects (the key check). Every launch uses the same fixed test key, so several
/// launches (or simulators) sharing the folder read each other's data. Signed in as `sync-test`.
enum SyncTestAccess {
    static let accountID = "sync-test"
    /// A fixed key: test data only, never a reader's.
    nonisolated static let key = try! BackupEncryptionKey(rawBytes: (0..<32).map { UInt8(0xA0 ^ $0) })

    static func make(folder: URL) -> LocalSyncAccess? {
        do {
            let account = folder.appendingPathComponent("account", isDirectory: true)
            try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
            return LocalSyncAccess(accountID: accountID, store: try FolderSyncObjectStore(root: folder.appendingPathComponent("objects-root", isDirectory: true)),
                                   blobStore: FolderBackupBlobStore(root: account), keyStore: InMemoryBackupKeyStore(key: key),
                                   temporaryDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TactileSyncTest"))
        } catch {
            syncLog.error("-syncTestFolder: the folder couldn't be prepared")
            return nil
        }
    }
}

/// `-syncTestSeedBook <pdf>` (DEBUG, UI tests): a second "device" puts books in the
/// `-syncTestFolder` account through the real engine. It has its own temporary library (removed
/// afterwards), its own device ID and engine directory, and the same fixed test key; it imports
/// each PDF and runs one joining round, so the account then holds those books with their PDFs,
/// as if another iPad had synced them. Nothing of this device's library is touched.
enum SyncTestSeed {
    /// Editors as the seeding device sees them: none.
    private final class NoEditors: SyncEditorProbe {
        func flushForSync(store: LibraryStore) async {}
        func syncBusySurfaces(bookID: UUID, store: LibraryStore) -> SyncBusyEditors { SyncBusyEditors() }
    }

    static func seed(folder: URL, books: [URL]) async {
        guard !books.isEmpty, let access = make(folder: folder) else { return }
        do {
            let store = try LibraryStore.ephemeral()
            defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
            let importer = ImportService(store: store)
            for url in books { _ = try await importer.importPDF(at: url) }
            guard case .ready(let account) = try await access.prepareRound() else {
                syncLog.error("-syncTestSeedBook: the test account isn't ready")
                return
            }
            let core = LibrarySyncCore(store: store, editors: NoEditors())
            let encrypted = EncryptedSyncStore(store: account.store, key: account.key,
                                               temporaryDirectory: store.rootDirectory.appendingPathComponent("tmp", isDirectory: true))
            let engine = SyncEngine(store: encrypted, library: LibrarySyncSource(core: core), inkMerger: AppSyncInkMerger(),
                                    directory: store.rootDirectory.appendingPathComponent("Sync/seed", isDirectory: true),
                                    device: SyncEngine.Device(id: UUID(), name: "Seeding device"))
            let report = try await engine.sync(mode: .full, joinConfirmed: true)
            syncLog.notice("-syncTestSeedBook: seeded \(report.count(.uploadedNew)) books")
        } catch {
            syncLog.error("-syncTestSeedBook failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func make(folder: URL) -> LocalSyncAccess? { SyncTestAccess.make(folder: folder) }
}
#endif
