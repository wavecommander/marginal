#if DEBUG
import Foundation
import ReaderBackup
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
#endif
