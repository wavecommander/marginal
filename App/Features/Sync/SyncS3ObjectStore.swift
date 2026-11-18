import Foundation
import ReaderSync
import S3Kit

/// Why the account's storage answered in a way sync cannot use.
nonisolated enum SyncStorageError: Error, Hashable, Sendable, LocalizedError {
    /// The service did not say which version of an object it holds (no ETag). Sync's conditional
    /// writes need it, so this is refused rather than passed over: an unconditional write could
    /// then replace another device's work.
    case missingETag(key: String)

    var errorDescription: String? {
        "Tactile Texts Cloud didn’t say which version of a synced book it holds, so sync stopped for now. It will try again."
    }
}

/// `SyncObjectStore` over an S3-compatible bucket (`S3Client`), for Tactile Texts Cloud: the
/// session's endpoint and key prefix, signed with the service's temporary credentials
/// (`BackupServiceCredentialsProvider`, which refreshes them before they expire, as for backups).
/// Keys are relative to the endpoint's prefix, as the protocol's are to the account's folder.
///
/// The protocol's contract, mapped:
/// - A refused condition (`S3Error.isPreconditionFailed`) is `SyncError.preconditionFailed(key:)`.
/// - An object over `maxBytes` (`S3Error.isObjectTooLarge`) is `SyncError.objectTooLarge`.
/// - A missing object: `get` and `head` return `nil`, `download` throws
///   `SyncError.objectNotFound`, `delete` succeeds.
/// - Every ETag is the service's, quotes included. An object listed, read or headed without one
///   throws `SyncStorageError.missingETag` (a conditional write needs it, and an absent ETag must
///   never read as "unchanged"); a put whose answer has none is S3Kit's `unexpectedResponse`.
/// - Everything else (no network, rejected credentials, the service's refusals) passes through
///   as S3Kit or the credentials provider threw it.
nonisolated struct SyncS3ObjectStore: SyncObjectStore, CustomStringConvertible, CustomReflectable {
    let client: S3Client
    /// Part size for multipart uploads (a PDF; blobs are small).
    let partSize: Int64

    init(client: S3Client, partSize: Int64 = S3Client.defaultPartSize) {
        self.client = client
        self.partSize = partSize
    }

    var description: String { "SyncS3ObjectStore(\(client.endpoint))" }
    var customMirror: Mirror { Mirror(self, children: ["endpoint": client.endpoint], displayStyle: .struct) }

    func list(prefix: String) async throws -> [SyncObjectInfo] {
        try await client.list(prefix: prefix).map { object in
            guard let eTag = object.eTag, !eTag.isEmpty else { throw SyncStorageError.missingETag(key: object.key) }
            return SyncObjectInfo(key: object.key, eTag: eTag, size: object.size)
        }
    }

    func get(_ key: String, maxBytes: Int) async throws -> SyncObjectData? {
        let object: S3Object?
        do {
            object = try await client.getObject(key: key, maxBytes: maxBytes)
        } catch let error as S3Error where error.isObjectTooLarge {
            throw SyncError.objectTooLarge(key: key, limit: maxBytes)
        }
        guard let object else { return nil }
        guard let eTag = object.eTag, !eTag.isEmpty else { throw SyncStorageError.missingETag(key: key) }
        return SyncObjectData(data: object.data, eTag: eTag, metadata: object.metadata)
    }

    func put(_ data: Data, at key: String, metadata: [String: String], condition: SyncWriteCondition?) async throws -> String {
        let s3Condition: S3PutCondition? = switch condition {
        case .ifMatch(let eTag): .ifMatch(eTag: eTag)
        case .ifAbsent: .ifAbsent
        case nil: nil
        }
        do {
            let eTag = try await client.putObject(data: data, key: key, metadata: metadata, condition: s3Condition)
            guard !eTag.isEmpty else { throw SyncStorageError.missingETag(key: key) }
            return eTag
        } catch let error as S3Error where error.isPreconditionFailed {
            throw SyncError.preconditionFailed(key: key)
        }
    }

    func upload(fileAt file: URL, to key: String, metadata: [String: String]) async throws {
        try await client.upload(fileAt: file, key: key, metadata: metadata, partSize: partSize)
    }

    func download(_ key: String, to file: URL) async throws {
        do {
            try await client.download(key: key, to: file)
        } catch S3Error.objectNotFound {
            throw SyncError.objectNotFound(key: key)
        }
    }

    func head(_ key: String) async throws -> SyncObjectHead? {
        guard let head = try await client.head(key: key) else { return nil }
        guard let eTag = head.eTag, !eTag.isEmpty else { throw SyncStorageError.missingETag(key: key) }
        return SyncObjectHead(size: head.size, eTag: eTag, metadata: head.metadata)
    }

    func delete(_ key: String) async throws {
        try await client.delete(key: key)
    }
}
