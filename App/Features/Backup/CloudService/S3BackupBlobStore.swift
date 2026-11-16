import Foundation
import ReaderBackup
import S3Kit

/// A `BackupBlobStore` in an S3-compatible bucket, under the endpoint's key prefix:
///
///     <prefix>/Backups/<name>
///     <prefix>/PDFs/<name>
///     <prefix>/<control name>
///
/// This is what the Tactile Texts backup service's encrypted backups are kept in: an
/// `EncryptedBackupDestination` over this store, over an `S3Client` whose credentials provider
/// fetches temporary credentials from the service. The store itself knows nothing about the
/// service or encryption.
///
/// The protocol's contract, as kept here:
/// - Names are NFC-normalised by `S3Client` (as R2 does on its side), so listed names are the
///   names to download or delete with. Names that are not `hasValidName` are refused with
///   `BackupError.unsafeEntryName` before any request.
/// - `list` lists one folder; objects deeper down and unsafe names are left out.
/// - `size(of:)` is a `HeadObject`: `nil` when there is none.
/// - `upload` is a single `PutObject` up to `partSize`, a multipart upload beyond it (aborted
///   on failure, so nothing is left under the name). Every request is signed with its payload's
///   SHA-256, and the stored size is checked afterwards.
/// - `download` streams to a temporary file beside `file` that replaces it only when complete;
///   on failure `file` is removed. A missing object throws `BackupError.fileNotFound(name:)`.
/// - `delete` succeeds when the object is already gone.
/// - `availability()` makes no network call: the store is offered, and problems show when it
///   is used.
///
/// Errors: `CancellationError`; `BackupError` (unsafe name, missing object, local files);
/// `CloudBackupError` for the service's answers, including the two outcomes of temporary
/// credentials (`notAllowedByAccess`, `accessNeedsRenewal`); and **anything the credentials
/// provider throws, unchanged** (for example the backup service saying the reader is not
/// subscribed), so the caller can tell "ask the service" apart from "the storage failed".
nonisolated struct S3BackupBlobStore: BackupBlobStore, CustomStringConvertible, CustomReflectable {
    /// The name in reader-facing errors ("Couldn't reach <name>").
    let displayName: String
    let client: S3Client
    /// Part size for multipart uploads (see `S3Client.partSize(forFileSize:preferred:)`).
    let partSize: Int64

    /// - Parameters:
    ///   - endpoint: the bucket and the key prefix the store lives under.
    ///   - credentialsProvider: asked before every request; its errors pass through unchanged.
    ///   - displayName: the service's name in error messages.
    ///   - session, retryPolicy, now: as for `S3Client` (inject a stub session in tests).
    ///   - partSize: preferred multipart part size; files up to one part go up in one request.
    init(endpoint: S3Endpoint, credentialsProvider: any S3CredentialsProvider, displayName: String,
         session: URLSession = .shared, retryPolicy: S3RetryPolicy = .standard,
         partSize: Int64 = S3Client.defaultPartSize, now: @escaping @Sendable () -> Date = { Date() }) {
        self.displayName = displayName
        self.partSize = partSize
        client = S3Client(endpoint: endpoint, credentialsProvider: ProviderErrorPassThrough(base: credentialsProvider),
                          session: session, retryPolicy: retryPolicy, now: now)
    }

    var description: String { "S3BackupBlobStore(\(displayName), \(client.endpoint))" }

    /// The name and endpoint only: `dump` never walks into the credentials provider.
    var customMirror: Mirror {
        Mirror(self, children: ["displayName": displayName, "endpoint": client.endpoint, "partSize": partSize],
               displayStyle: .struct)
    }

    @concurrent
    func availability() async -> BackupDestinationAvailability { .available }

    @concurrent
    func list(_ folder: BackupBlobFolder) async throws -> [BackupBlobInfo] {
        let prefix = folder.rawValue + "/"
        let objects = try await run(.other) { try await client.list(prefix: prefix) }
        return objects.compactMap { object -> BackupBlobInfo? in
            guard object.key.hasPrefix(prefix) else { return nil }
            let name = String(object.key.dropFirst(prefix.count))
            guard BackupBlobKey(folder: folder, name: name).hasValidName else { return nil }
            return BackupBlobInfo(name: name, byteSize: object.size)
        }
    }

    @concurrent
    func size(of key: BackupBlobKey) async throws -> Int64? {
        try Self.check(key)
        return try await run(.object(name: key.name)) { try await client.head(key: key.path) }?.size
    }

    @concurrent
    func upload(from file: URL, to key: BackupBlobKey, progress: BackupProgress?) async throws {
        try Self.check(key)
        try await run(.object(name: key.name)) {
            try await client.upload(fileAt: file, key: key.path, partSize: partSize,
                                    progress: S3BackupDestination.transferProgress(progress))
        }
        progress?(1)
    }

    @concurrent
    func download(_ key: BackupBlobKey, to file: URL, progress: BackupProgress?) async throws {
        try Self.check(key)
        do {
            try await run(.object(name: key.name)) {
                try await client.download(key: key.path, to: file, progress: S3BackupDestination.transferProgress(progress))
            }
        } catch {
            // `S3Client` leaves `file` as it was; the contract wants nothing there.
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        progress?(1)
    }

    @concurrent
    func delete(_ key: BackupBlobKey) async throws {
        try Self.check(key)
        // `DeleteObject` succeeds when the object is already gone.
        try await run(.object(name: key.name)) { try await client.delete(key: key.path) }
    }

    // MARK: - Internals

    private static func check(_ key: BackupBlobKey) throws {
        guard key.hasValidName else { throw BackupError.unsafeEntryName(name: key.name) }
    }

    /// Runs `body`, rethrowing an error the credentials provider threw as it is and mapping
    /// everything else to the app's reader-facing errors.
    ///
    /// `S3Client` documents that provider errors pass through, but its download wraps any
    /// non-`S3Error` into `S3Error.fileAccess`, and the shared mapping would turn an unknown
    /// error into a local file error. So the provider is wrapped (`ProviderErrorPassThrough`)
    /// and records what it throws in a task-local box for this call; that error wins.
    @discardableResult
    private func run<T: Sendable>(_ subject: CloudErrorSubject, _ body: () async throws -> T) async throws -> T {
        let box = ProviderErrorBox()
        do {
            return try await ProviderErrorPassThrough.$box.withValue(box) { try await body() }
        } catch {
            if let providerError = box.error { throw providerError }
            throw CloudBackupError.mapping(s3: error, subject: subject, destination: displayName)
        }
    }
}

/// Forwards to another credentials provider, recording anything it throws in the calling
/// task's `box` (see `S3BackupBlobStore.run`).
nonisolated struct ProviderErrorPassThrough: S3CredentialsProvider, CustomStringConvertible, CustomReflectable {
    @TaskLocal static var box: ProviderErrorBox?

    let base: any S3CredentialsProvider

    func credentials() async throws -> S3Credentials {
        do {
            return try await base.credentials()
        } catch {
            Self.box?.record(error)
            throw error
        }
    }

    func credentialsRejected(_ credentials: S3Credentials) async {
        await base.credentialsRejected(credentials)
    }

    var description: String { "ProviderErrorPassThrough(\(base))" }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The first error a credentials provider threw during one store call.
nonisolated final class ProviderErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: (any Error)?

    var error: (any Error)? { lock.withLock { recorded } }

    func record(_ error: any Error) {
        lock.withLock { if recorded == nil { recorded = error } }
    }
}
