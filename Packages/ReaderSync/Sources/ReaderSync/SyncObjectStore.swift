import Foundation

/// An object in a listing: its key, ETag, size and when it was last written.
public struct SyncObjectInfo: Hashable, Sendable {
    /// The key relative to the account folder (`Sync/v1/books/<book key>`).
    public var key: String
    /// As the service sent it, quotes included. Compared only for equality.
    public var eTag: String
    public var size: Int64
    /// When the object was last written, by the store's clock (S3 `LastModified`), or `nil` when
    /// the store did not say. Housekeeping removes nothing whose age it cannot tell.
    public var lastModified: Date?

    public init(key: String, eTag: String, size: Int64, lastModified: Date? = nil) {
        self.key = key
        self.eTag = eTag
        self.size = size
        self.lastModified = lastModified
    }
}

/// What a store knows about one object without its content.
public struct SyncObjectHead: Hashable, Sendable {
    public var size: Int64
    public var eTag: String
    /// Plaintext user metadata, names lower-case (`write-id`).
    public var metadata: [String: String]
    /// When the object was last written, by the store's clock (S3 `Last-Modified`), or `nil`.
    public var lastModified: Date?

    public init(size: Int64, eTag: String, metadata: [String: String], lastModified: Date? = nil) {
        self.size = size
        self.eTag = eTag
        self.metadata = metadata
        self.lastModified = lastModified
    }
}

/// A small object read into memory.
public struct SyncObjectData: Hashable, Sendable {
    public var data: Data
    public var eTag: String
    /// Plaintext user metadata, names lower-case (`write-id`).
    public var metadata: [String: String]

    public init(data: Data, eTag: String, metadata: [String: String]) {
        self.data = data
        self.eTag = eTag
        self.metadata = metadata
    }
}

/// The condition of a conditional write.
public enum SyncWriteCondition: Hashable, Sendable {
    /// Replace the object only while its ETag is still this one (S3 `If-Match`). Refused when
    /// the object changed or no longer exists.
    case ifMatch(eTag: String)
    /// Create the object only if there is none (S3 `If-None-Match: *`).
    case ifAbsent
}

/// The plain object store sync needs, holding only ciphertext: keys are `/`-separated paths
/// relative to the account's folder (`Sync/v1/books/<book key>`, `PDFs/<name>.ttenc`).
/// `EncryptedSyncStore` builds sync's objects on top of it. The app adapts `S3Client` to it;
/// `InMemorySyncObjectStore` is the test double.
///
/// Contract every implementation keeps:
/// - A write is atomic: the object is absent, the old one, or the complete new one, never a
///   mix, and a conditional write's condition is evaluated atomically when it commits, so of
///   several writes conditional on one ETag at most one succeeds.
/// - A refused condition throws `SyncError.preconditionFailed(key:)` and changes nothing.
/// - An ETag changes whenever the object's bytes change (equal bytes may keep equal ETags, as
///   S3's do). `list`, `head`, `get` and the writes report the same ETag for the same object.
/// - A missing object: `get` and `head` return `nil`; `download` throws
///   `SyncError.objectNotFound(key:)`; `delete` succeeds.
/// - `get` refuses an object larger than `maxBytes` with `SyncError.objectTooLarge`.
/// - Metadata names are lower-case ASCII tokens and values printable ASCII.
/// - `list` and `head` report each object's last-modified time by the store's own clock when the
///   store keeps one (S3 does). Every write, writing the same bytes again included, makes it the
///   time of that write. Housekeeping and the blob-reuse rule depend on it (`SyncHousekeeping`).
/// - Cancellation of the calling task throws `CancellationError`. The store's own failures throw
///   its own errors, which callers pass on. A write whose answer was lost may or may not have
///   taken effect; callers reconcile (see `EncryptedSyncStore`).
public protocol SyncObjectStore: Sendable {
    /// Every object whose key starts with `prefix`, with its ETag and size, in key order.
    func list(prefix: String) async throws -> [SyncObjectInfo]

    /// The object's bytes, ETag and metadata, or `nil` when there is none.
    func get(_ key: String, maxBytes: Int) async throws -> SyncObjectData?

    /// Stores `data` as `key` with `metadata`, under `condition` (`nil`: unconditionally), and
    /// returns the stored object's ETag.
    func put(_ data: Data, at key: String, metadata: [String: String], condition: SyncWriteCondition?) async throws -> String

    /// Stores the local file as `key` unconditionally (for immutable, content-named objects),
    /// streamed from disk.
    func upload(fileAt file: URL, to key: String, metadata: [String: String]) async throws

    /// Downloads the object to the local file, replacing any file there atomically.
    func download(_ key: String, to file: URL) async throws

    /// The object's size, ETag and metadata, or `nil` when there is none.
    func head(_ key: String) async throws -> SyncObjectHead?

    /// Deletes the object; succeeds when it is already gone.
    func delete(_ key: String) async throws
}
