import Foundation

/// Every failure this package reports. A `SyncObjectStore`'s own failures (no network, rejected
/// credentials, a full account) and `CancellationError` pass through unchanged; local file
/// failures are `BackupError`s from `ReaderBackup`.
///
/// No case ever carries key material. Object keys are keyed hashes, which reveal nothing.
public enum SyncError: Error, LocalizedError, Hashable, Sendable {
    /// A conditional write was refused: the object's ETag is no longer the one given
    /// (`ifMatch`), or an object already exists (`ifAbsent`). Nothing was written by that
    /// request. After a write whose answer was lost this may mean the write had in fact won:
    /// see `EncryptedSyncStore.reconcileHeadWrite(bookKey:writeID:)`.
    case preconditionFailed(key: String)
    /// There is no object with this key.
    case objectNotFound(key: String)
    /// The object is larger than the reader allows for its kind.
    case objectTooLarge(key: String, limit: Int)
    /// The object failed authentication, is not the kind or the object asked for (renamed or
    /// swapped), or its content breaks the format. With a wrong key every object reads as this;
    /// check the key with `EncryptedBackupDestination.checkKey()` first.
    case objectDamaged(key: String)
    /// A blob or PDF decrypted, but its plaintext is not the content asked for (its SHA-256 or
    /// size differ).
    case contentMismatch(key: String)
    /// The object was written in a newer format than this app knows. Sync for the account stops
    /// and nothing is changed (`docs/CLOUD_SYNC_PLAN.md` "Versions").
    case newerFormatVersion(Int)
    /// A head's version is lower than the highest this device has seen for the book: the store
    /// offered an older head, which is refused so a book cannot be silently rolled back.
    case rollback(bookKey: String, highestSeen: Int, offered: Int)
    /// A name built from caller input is not valid (not 64 lower-case hex digits, say).
    case invalidName(String)
    /// A head given to be written breaks the format's rules (`SyncHead.isWellFormed`).
    case invalidHead
    /// The device's stored base for a book could not be read (damaged, or written by a newer app).
    case baseUnreadable(bookID: UUID)
    /// The device's record of the highest head version seen for a book could not be read. Sync
    /// of that book stops rather than accept a head it cannot check.
    case rollbackRecordUnreadable(bookKey: String)

    public var errorDescription: String? {
        switch self {
        case .preconditionFailed:
            "Another device changed this book at the same moment. Sync will try again."
        case .objectNotFound:
            "Part of a synced book is missing from Tactile Texts Cloud."
        case .objectTooLarge:
            "Part of a synced book in Tactile Texts Cloud is larger than expected, so it wasn’t read."
        case .objectDamaged:
            "Part of a synced book in Tactile Texts Cloud is damaged or has been changed, so it can’t be used."
        case .contentMismatch:
            "Part of a synced book in Tactile Texts Cloud doesn’t match what was saved."
        case .newerFormatVersion:
            "Your books were synced by a newer version of Tactile Texts. Update the app on this iPad to keep syncing."
        case .rollback:
            "Tactile Texts Cloud offered an older copy of a book than this iPad has already seen, so it wasn’t used."
        case .invalidName:
            "A synced book has an invalid name."
        case .invalidHead:
            "A book couldn’t be prepared for syncing."
        case .baseUnreadable, .rollbackRecordUnreadable:
            "This iPad’s sync record for a book can’t be read."
        }
    }
}
