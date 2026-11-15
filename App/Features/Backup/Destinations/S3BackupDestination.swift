import Foundation
import ReaderBackup
import S3Kit

/// Backups in an S3-compatible bucket (Amazon S3, Cloudflare R2, MinIO), in the folder layout
/// under the configured key prefix:
///
///     <prefix>/Backups/<snapshot name>.ttbackup
///     <prefix>/PDFs/<sha256>.pdf            (with user metadata `sha256`)
///
/// - Snapshot `id`s are keys relative to the prefix (`Backups/<name>`). Names are stored in
///   Unicode NFC, as `S3Client` normalises every key (and R2 does on its side), so a name read back
///   from the listing is the key to download or delete with; the returned `BackupSnapshotInfo`
///   already carries the NFC form.
/// - Uploads replace an object of the same key only when complete (a single `PutObject`, or a
///   multipart upload that is aborted on failure). A PDF is checked against the caller's hash
///   before it is sent; every request is signed with its payload's SHA-256, so the service
///   refuses bytes that change on the way.
/// - Downloads go to a temporary file first: a PDF is checked against its hash, a snapshot
///   against the size the listing reported.
/// - `availability()` makes no network call: a configured bucket is offered, and problems show
///   when it is used.
/// - Errors: `CancellationError`, `BackupError` (not found, mismatch, local files) or
///   `CloudBackupError` (credentials, clock, access, bucket, storage limit, network, service).
nonisolated struct S3BackupDestination: BackupDestination {
    static let destinationID = "s3"
    /// The user-metadata name that records a PDF's SHA-256.
    static let sha256MetadataKey = "sha256"

    let id = S3BackupDestination.destinationID
    let displayName: String
    let client: S3Client

    init(configuration: S3BackupConfiguration, urlSession: URLSession = .shared,
         retryPolicy: S3RetryPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        displayName = configuration.displayName
        client = S3Client(configuration: configuration.s3, session: urlSession, retryPolicy: retryPolicy, now: now)
    }

    @concurrent
    func availability() async -> BackupDestinationAvailability { .available }

    // MARK: Snapshots

    @concurrent
    func listSnapshots() async throws -> [BackupSnapshotInfo] {
        let prefix = BackupFolderLayout.backupsDirectory + "/"
        let objects = try await run(.other) { try await client.list(prefix: prefix) }
        return objects.compactMap { object -> BackupSnapshotInfo? in
            guard object.key.hasPrefix(prefix) else { return nil }
            return Self.info(name: String(object.key.dropFirst(prefix.count)), size: object.size)
        }
        .sorted(by: BackupSnapshotInfo.newestFirst)
    }

    @discardableResult @concurrent
    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        let stored = name.precomposedStringWithCanonicalMapping
        guard Self.info(name: stored, size: 0) != nil else { throw BackupError.invalidSnapshotName(name: name) }
        let size = try Self.fileSize(file)
        try await run(.snapshot(name: stored)) {
            try await client.upload(fileAt: file, key: BackupFolderLayout.snapshotPath(name: stored),
                                    progress: Self.transferProgress(progress))
        }
        progress?(1)
        return Self.info(name: stored, size: size)!
    }

    @concurrent
    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        try Self.checkSnapshotID(snapshot)
        let written = try await run(.snapshot(name: snapshot.name)) {
            try await client.download(key: snapshot.id, to: file, progress: Self.transferProgress(progress))
        }
        guard written == snapshot.byteSize else {
            try? FileManager.default.removeItem(at: file)
            throw BackupError.contentMismatch(name: snapshot.name)
        }
        progress?(1)
    }

    @concurrent
    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        try Self.checkSnapshotID(snapshot)
        // `DeleteObject` succeeds when the object is already gone.
        try await run(.snapshot(name: snapshot.name)) { try await client.delete(key: snapshot.id) }
    }

    // MARK: PDFs

    @concurrent
    func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        let hash = try Self.validHash(sha256)
        let head = try await run(.pdf(sha256: hash)) {
            try await client.head(key: BackupFolderLayout.pdfPath(sha256: hash))
        }
        return Self.matches(head, hash: hash, size: size)
    }

    @concurrent
    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        let key = BackupFolderLayout.pdfPath(sha256: hash)
        let existing = try await run(.pdf(sha256: hash)) { try await client.head(key: key) }
        if Self.matches(existing, hash: hash, size: size) {
            progress?(1)
            return
        }
        // Check the file is the one the caller hashed (a fifth of the progress), then send it.
        let local: ContentDigest
        do {
            local = try ContentHash.digest(ofFileAt: file, progress: Self.scaled(progress, from: 0, to: 0.2))
        } catch let error as BackupError {
            throw error
        } catch {
            throw CloudBackupError.mapping(s3: error, subject: .pdf(sha256: hash), destination: displayName)
        }
        guard local == ContentDigest(sha256: hash, size: size) else {
            throw BackupError.contentMismatch(name: file.lastPathComponent)
        }
        let upload = Self.transferProgress(Self.scaled(progress, from: 0.2, to: 1))
        try await run(.pdf(sha256: hash)) {
            try await client.upload(fileAt: file, key: key, metadata: [Self.sha256MetadataKey: hash], progress: upload)
        }
        progress?(1)
    }

    @concurrent
    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        do {
            try await run(.pdf(sha256: hash)) {
                try await client.download(key: BackupFolderLayout.pdfPath(sha256: hash), to: file, expectedSHA256: hash,
                                          progress: Self.transferProgress(progress))
            }
        } catch BackupError.contentMismatch(let name) {
            // `S3Client` leaves the destination as it was; the contract wants nothing there.
            try? FileManager.default.removeItem(at: file)
            throw BackupError.contentMismatch(name: name)
        }
        progress?(1)
    }

    // MARK: - Internals

    @discardableResult
    private func run<T: Sendable>(_ subject: CloudErrorSubject, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw CloudBackupError.mapping(s3: error, subject: subject, destination: displayName)
        }
    }

    /// The info for a snapshot stored as `Backups/<name>`, or `nil` when `name` is not a snapshot
    /// name (other files, deeper keys, hidden names).
    static func info(name: String, size: Int64) -> BackupSnapshotInfo? {
        guard !name.contains("/"), !name.hasPrefix("."), let parsed = SnapshotName.parse(name) else { return nil }
        return BackupSnapshotInfo(id: BackupFolderLayout.snapshotPath(name: name), name: name,
                                  createdAt: parsed.createdAt, deviceName: parsed.deviceName, byteSize: size)
    }

    /// A snapshot `id` from this destination: `Backups/<snapshot name>`.
    private static func checkSnapshotID(_ snapshot: BackupSnapshotInfo) throws {
        let prefix = BackupFolderLayout.backupsDirectory + "/"
        guard snapshot.id.hasPrefix(prefix), info(name: String(snapshot.id.dropFirst(prefix.count)), size: 0) != nil else {
            throw BackupError.invalidSnapshotName(name: snapshot.name)
        }
    }

    static func matches(_ head: S3ObjectHead?, hash: String, size: Int64) -> Bool {
        guard let head, head.size == size else { return false }
        return head.metadata[sha256MetadataKey].map { $0.lowercased() == hash } ?? true
    }

    static func validHash(_ sha256: String) throws -> String {
        let hash = sha256.lowercased()
        guard ContentHash.isValidSHA256(hash) else { throw BackupError.pdfNotAtDestination(sha256: sha256) }
        return hash
    }

    private static func fileSize(_ file: URL) throws -> Int64 {
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw BackupError.fileNotFound(name: file.lastPathComponent)
            }
            return Int64(size)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.fileNotFound(name: file.lastPathComponent)
        }
    }

    /// `progress` mapped from `0...1` onto `lower...upper`.
    static func scaled(_ progress: BackupProgress?, from lower: Double, to upper: Double) -> BackupProgress? {
        guard let progress else { return nil }
        return { fraction in progress(lower + fraction * (upper - lower)) }
    }

    static func transferProgress(_ progress: BackupProgress?) -> S3Progress? {
        guard let progress else { return nil }
        return { done, total in progress(total > 0 ? min(1, max(0, Double(done) / Double(total))) : 1) }
    }
}
