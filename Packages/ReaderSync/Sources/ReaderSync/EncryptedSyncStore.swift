import CryptoKit
import Foundation
import ReaderBackup

/// One head in a listing.
public struct SyncHeadListing: Hashable, Sendable {
    public var bookKey: String
    /// Compare with the ETag a device last saw to skip unchanged heads.
    public var eTag: String
    public var size: Int64

    public init(bookKey: String, eTag: String, size: Int64) {
        self.bookKey = bookKey
        self.eTag = eTag
        self.size = size
    }
}

/// A head as read, with the ETag a conditional write over it must name.
public struct SyncHeadRead: Hashable, Sendable {
    public var head: SyncHead
    public var eTag: String

    public init(head: SyncHead, eTag: String) {
        self.head = head
        self.eTag = eTag
    }
}

/// What reading a head back says about a write whose answer was lost.
public enum SyncHeadReconciliation: Hashable, Sendable {
    /// The head stored now is the one written (same write ID): the write won, and this is the
    /// ETag to keep.
    case committed(eTag: String)
    /// The head stored now is another (or there is none): the write did not win, or was already
    /// replaced. Pull, merge and try again.
    case notCommitted(currentETag: String?)
}

/// Sync's encrypted objects over a plain `SyncObjectStore`: heads written with compare-and-swap,
/// immutable content-named blobs, history, and the PDFs shared with backups. The store sees only
/// ciphertext, keyed hashes and sizes (`docs/CLOUD_SYNC_PLAN.md` "What the operator can and
/// cannot see").
///
/// This type does not check that the store's data was written with this key: with a different
/// key every object reads as `SyncError.objectDamaged`. Run `EncryptedBackupDestination.checkKey()`
/// on the account first, as backups do, before reading or writing anything.
///
/// ## Heads and history: the sync envelope
///
/// A head (`Sync/v1/books/<book key>`) and a history object (`Sync/v1/history/<book key>/<n>`)
/// are one AES-256-GCM box each. All integers unsigned big-endian; offsets in bytes:
///
///     offset  size  field
///     0       8     magic: 89 54 54 53 59 4E 0D 0A  ("\x89TTSYN\r\n")
///     8       1     envelope version: 1
///     9       1     kind: 0x01 head, 0x02 history
///     10      32    salt: random
///     42      12    nonce: random
///     54      P     ciphertext of the head's JSON (`SyncHead.encoded()`), P bytes
///     54+P    16    tag
///
/// - Object key `K_o` = HKDF-SHA256(`K_sync`, salt: the 32-byte salt, info:
///   `"tactile-texts.sync.v1.envelope"`, 32 bytes), where `K_sync` is the
///   `tactile-texts.sync.v1.content` sub-key (`SyncKeys`). Every object has its own key, so a
///   nonce is never reused under one key (and the random nonce guards a salt collision too).
/// - Associated data: bytes 0 ..< 54 followed by the object's key in UTF-8
///   (`Sync/v1/books/<book key>`). The header cannot be altered, and an object renamed or copied
///   to another key, or a head passed off as a history object, does not open.
/// - Reading also requires the head's PDF to give the book key in its name, and a history
///   object's version to be the one in its name.
/// - An envelope version above 1 (up to 15) is `newerFormatVersion`; anything else that does not
///   open is `objectDamaged`. A head is at most `maximumHeadSize` bytes.
///
/// The head's write ID is also stored in the clear as the object's `write-id` metadata, for
/// tools without the key; `reconcileHeadWrite` itself compares the authenticated one, so a
/// forged metadata value cannot make a lost write look committed.
///
/// ## Blobs
///
/// A blob (`Sync/v1/blobs/<blob name>`, the name a keyed hash of the plaintext's SHA-256) is a
/// file in `BackupFileEncryption`'s `.ttenc` format (chunked AES-256-GCM, a key per file) whose
/// master key is `K_sync` rather than the reader's key, so blob keys are independent of backup
/// keys. Its encrypted metadata binds it to its name and content:
/// `{"kind":"sync-blob","object":"Sync/v1/blobs/<name>","sha256":<hex>,"size":<decimal>}`.
/// Reading refuses an object whose metadata names another object or content, and checks the
/// decrypted plaintext's SHA-256 and size. Writing skips a blob already stored at its exact
/// encrypted size (a blob is written once and never changed).
///
/// ## PDFs
///
/// A PDF is `EncryptedBackupDestination`'s PDF object (`PDFs/<keyed hash>.ttenc`, the reader's
/// key, its metadata), so one object serves snapshot backups and sync.
public struct EncryptedSyncStore: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The largest head or history object read, in bytes: 4 MiB.
    public static let maximumHeadSize = 4 * 1024 * 1024
    /// The largest blob `blob(_:)` reads into memory: 64 MiB. Use `downloadBlob` for more.
    public static let maximumInMemoryBlobSize: Int64 = 64 * 1024 * 1024
    /// The plaintext metadata name of a head's write ID (S3 `x-amz-meta-write-id`).
    public static let writeIDMetadataName = "write-id"

    /// Encrypts a file in `.ttenc` format: `(source, destination, master key, metadata)`.
    typealias FileEncryptor = @Sendable (URL, URL, BackupEncryptionKey, [String: String]) throws -> ContentDigest

    /// The plain store the ciphertext goes to.
    public let store: any SyncObjectStore
    let keys: SyncKeys
    private let temporaryDirectory: URL
    private let randomness: SyncRandomness
    private let encryptFile: FileEncryptor

    /// A store keeping `store`'s sync objects encrypted with `key`. Temporary files go in
    /// `temporaryDirectory` and are removed in every outcome.
    public init(store: any SyncObjectStore, key: BackupEncryptionKey,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.init(store: store, key: key, temporaryDirectory: temporaryDirectory, randomness: .system,
                  encryptFile: { try BackupFileEncryption.encrypt($0, to: $1, key: $2, metadata: $3) })
    }

    /// With fixed randomness and file encryption (the fixture generator only).
    init(store: any SyncObjectStore, key: BackupEncryptionKey, temporaryDirectory: URL, randomness: SyncRandomness,
         encryptFile: @escaping FileEncryptor) {
        self.store = store
        self.keys = SyncKeys(key: key)
        self.temporaryDirectory = temporaryDirectory
        self.randomness = randomness
        self.encryptFile = encryptFile
    }

    public var description: String { "EncryptedSyncStore(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    // MARK: Names

    /// The book key for the book whose PDF has this SHA-256 (see `SyncKeys.bookKey(pdfSHA256:)`).
    public func bookKey(pdfSHA256: String) throws -> String {
        try keys.bookKey(pdfSHA256: pdfSHA256)
    }

    /// `Sync/v1/blobs/<blob name>` for content with this SHA-256.
    public func blobKey(sha256: String) throws -> String {
        try SyncLayout.blobKey(name: keys.blobName(sha256: sha256))
    }

    /// `PDFs/<keyed hash>.ttenc` for the PDF with this SHA-256.
    public func pdfKey(sha256: String) throws -> String {
        try SyncLayout.pdfKey(sha256: sha256, key: keys.master)
    }

    // MARK: Heads

    /// Every head's book key, ETag and size, from one listing of `Sync/v1/books/`. Keys that are
    /// not head keys are left out.
    public func listHeads() async throws -> [SyncHeadListing] {
        try await store.list(prefix: SyncLayout.headsPrefix).compactMap { object in
            SyncLayout.bookKey(fromHeadKey: object.key).map { SyncHeadListing(bookKey: $0, eTag: object.eTag, size: object.size) }
        }
    }

    /// The book's head and its ETag, or `nil` when the book has none. Throws `objectDamaged` for
    /// one that does not open or is not this book's, and `newerFormatVersion` for a newer format.
    /// The caller applies the rollback check (`SyncRollbackGuard`) and the version rules.
    public func readHead(bookKey: String) async throws -> SyncHeadRead? {
        let key = try SyncLayout.headKey(bookKey: bookKey)
        guard let object = try await store.get(key, maxBytes: Self.maximumHeadSize) else { return nil }
        let head = try openHead(object.data, kind: .head, key: key, bookKey: bookKey)
        return SyncHeadRead(head: head, eTag: object.eTag)
    }

    /// Writes the book's head under `condition` (`.ifAbsent` for a book's first head, otherwise
    /// `.ifMatch` with the ETag read) and returns the new ETag. Throws `preconditionFailed` when
    /// another write got there first. The head must be well formed (else `invalidHead`) and its
    /// PDF must give `bookKey` (else `invalidName`). If the call fails without an answer, use `reconcileHeadWrite` with
    /// `head.writeID`.
    @discardableResult
    public func writeHead(_ head: SyncHead, bookKey: String, condition: SyncWriteCondition) async throws -> String {
        let key = try SyncLayout.headKey(bookKey: bookKey)
        let sealed = try sealHead(head, kind: .head, key: key, bookKey: bookKey)
        return try await store.put(sealed, at: key, metadata: [Self.writeIDMetadataName: head.writeID], condition: condition)
    }

    /// After a head write that failed ambiguously (no answer, or a `preconditionFailed` from a
    /// retry of a write that had in fact committed), reads the head back and compares its
    /// authenticated write ID with `writeID`.
    public func reconcileHeadWrite(bookKey: String, writeID: String) async throws -> SyncHeadReconciliation {
        guard let read = try await readHead(bookKey: bookKey) else { return .notCommitted(currentETag: nil) }
        let matches = constantTimeEqual(Array(read.head.writeID.utf8), Array(writeID.utf8))
        return matches ? .committed(eTag: read.eTag) : .notCommitted(currentETag: read.eTag)
    }

    // MARK: History

    /// Stores `head` as `Sync/v1/history/<book key>/<head.version>` (replacing any object there).
    public func writeHistory(_ head: SyncHead, bookKey: String) async throws {
        let key = try SyncLayout.historyKey(bookKey: bookKey, version: head.version)
        let sealed = try sealHead(head, kind: .history, key: key, bookKey: bookKey)
        _ = try await store.put(sealed, at: key, metadata: [Self.writeIDMetadataName: head.writeID], condition: nil)
    }

    /// The versions in the book's history, ascending.
    public func historyVersions(bookKey: String) async throws -> [Int] {
        try await store.list(prefix: SyncLayout.historyPrefix(bookKey: bookKey))
            .compactMap { SyncLayout.version(fromHistoryKey: $0.key, bookKey: bookKey) }
            .sorted()
    }

    /// The book's head as it was at `version`, or `nil` when history does not hold it.
    public func readHistory(bookKey: String, version: Int) async throws -> SyncHead? {
        let key = try SyncLayout.historyKey(bookKey: bookKey, version: version)
        guard let object = try await store.get(key, maxBytes: Self.maximumHeadSize) else { return nil }
        let head = try openHead(object.data, kind: .history, key: key, bookKey: bookKey)
        guard head.version == version else { throw SyncError.objectDamaged(key: key) }
        return head
    }

    /// Deletes the history object (housekeeping).
    public func deleteHistory(bookKey: String, version: Int) async throws {
        try await store.delete(SyncLayout.historyKey(bookKey: bookKey, version: version))
    }

    // MARK: Blobs

    /// Whether the blob is stored, at its exact encrypted size.
    public func hasBlob(_ content: ContentDigest) async throws -> Bool {
        let key = try blobKey(sha256: content.sha256)
        return try await store.head(key)?.size == Self.encryptedSize(of: content, metadata: blobMetadata(content, key: key))
    }

    /// Stores `data` as a blob, unless it is already there, and returns its SHA-256 and size.
    @discardableResult
    public func putBlob(_ data: Data) async throws -> ContentDigest {
        let file = try temporaryFile()
        defer { removeQuietly(file) }
        try mappingFileErrors(file) { try data.write(to: file) }
        return try await putBlob(fileAt: file)
    }

    /// Stores the file as a blob, unless it is already there, and returns its SHA-256 and size.
    /// Throws `BackupError.sourceFileChanged` if the file changes while it is read.
    @discardableResult
    public func putBlob(fileAt file: URL) async throws -> ContentDigest {
        let content = try ContentHash.digest(ofFileAt: file)
        let key = try blobKey(sha256: content.sha256)
        let metadata = blobMetadata(content, key: key)
        if try await store.head(key)?.size == Self.encryptedSize(of: content, metadata: metadata) { return content }
        let sealed = try temporaryFile()
        defer { removeQuietly(sealed) }
        let encrypted = try encryptFile(file, sealed, keys.content, metadata)
        guard encrypted == content else { throw BackupError.sourceFileChanged(name: file.lastPathComponent) }
        try await store.upload(fileAt: sealed, to: key, metadata: [:])
        return content
    }

    /// The blob's plaintext, read into memory (at most `maximumInMemoryBlobSize` bytes). Throws
    /// `objectNotFound` when it is not stored, `objectDamaged` when it does not open or is not
    /// the blob asked for, and `contentMismatch` when its plaintext is not `content`.
    public func blob(_ content: ContentDigest) async throws -> Data {
        let key = try blobKey(sha256: content.sha256)
        guard content.size <= Self.maximumInMemoryBlobSize else {
            throw SyncError.objectTooLarge(key: key, limit: Int(Self.maximumInMemoryBlobSize))
        }
        let metadata = blobMetadata(content, key: key)
        let limit = Int(Self.encryptedSize(of: content, metadata: metadata))
        guard let object = try await store.get(key, maxBytes: limit) else { throw SyncError.objectNotFound(key: key) }
        let sealed = try temporaryFile()
        let plain = try temporaryFile()
        defer { removeQuietly(sealed); removeQuietly(plain) }
        try mappingFileErrors(sealed) { try object.data.write(to: sealed) }
        try open(sealed, to: plain, master: keys.content, key: key, metadata: metadata, content: content)
        return try mappingFileErrors(plain) { try Data(contentsOf: plain) }
    }

    /// Downloads and decrypts the blob to `file` (replacing it only when everything checked
    /// out). Errors as `blob(_:)`.
    public func downloadBlob(_ content: ContentDigest, to file: URL) async throws {
        let key = try blobKey(sha256: content.sha256)
        try await downloadAndOpen(key: key, to: file, master: keys.content, metadata: blobMetadata(content, key: key),
                                  content: content)
    }

    /// Deletes the blob (housekeeping; only for blobs nothing refers to).
    public func deleteBlob(_ content: ContentDigest) async throws {
        try await store.delete(blobKey(sha256: content.sha256))
    }

    // MARK: PDFs

    /// Whether the PDF object is stored, at its exact encrypted size.
    public func hasPDF(_ pdf: ContentDigest) async throws -> Bool {
        let key = try pdfKey(sha256: pdf.sha256)
        return try await store.head(key)?.size == Self.encryptedSize(of: pdf, metadata: pdfMetadata(pdf, key: key))
    }

    /// Uploads the PDF at `file`, whose SHA-256 and size are `pdf`, unless it is already there.
    /// Throws `contentMismatch` when the file is not `pdf`.
    public func uploadPDF(fileAt file: URL, content pdf: ContentDigest) async throws {
        let key = try pdfKey(sha256: pdf.sha256)
        let metadata = pdfMetadata(pdf, key: key)
        if try await store.head(key)?.size == Self.encryptedSize(of: pdf, metadata: metadata) { return }
        let sealed = try temporaryFile()
        defer { removeQuietly(sealed) }
        let encrypted = try encryptFile(file, sealed, keys.master, metadata)
        guard encrypted == ContentDigest(sha256: pdf.sha256.lowercased(), size: pdf.size) else {
            throw SyncError.contentMismatch(key: key)
        }
        try await store.upload(fileAt: sealed, to: key, metadata: [:])
    }

    /// Downloads and decrypts the PDF to `file`. Errors as `blob(_:)`.
    public func downloadPDF(_ pdf: ContentDigest, to file: URL) async throws {
        let key = try pdfKey(sha256: pdf.sha256)
        try await downloadAndOpen(key: key, to: file, master: keys.master, metadata: pdfMetadata(pdf, key: key),
                                  content: pdf)
    }

    // MARK: Envelope

    enum EnvelopeKind: UInt8 {
        case head = 0x01
        case history = 0x02
    }

    /// `89 54 54 53 59 4E 0D 0A`
    static let envelopeMagic: [UInt8] = [0x89, 0x54, 0x54, 0x53, 0x59, 0x4E, 0x0D, 0x0A]
    static let envelopeVersion: UInt8 = 1
    static let envelopeHeaderSize = 54
    static let envelopeKeyInfo = Data("tactile-texts.sync.v1.envelope".utf8)
    /// Envelope versions above 1 up to this are "newer"; any other unknown version is damage.
    static let highestPlausibleEnvelopeVersion: UInt8 = 15

    func sealHead(_ head: SyncHead, kind: EnvelopeKind, key: String, bookKey: String) throws -> Data {
        guard head.isWellFormed else { throw SyncError.invalidHead }
        guard try keys.bookKey(pdfSHA256: head.references.pdf.sha256) == bookKey else { throw SyncError.invalidName(bookKey) }
        let salt = randomness.bytes(32)
        let nonce = randomness.bytes(12)
        precondition(salt.count == 32 && nonce.count == 12)
        var header = Self.envelopeMagic
        header.append(Self.envelopeVersion)
        header.append(kind.rawValue)
        header += salt
        header += nonce
        // A 12-byte nonce and a 256-bit key: sealing cannot fail.
        let sealed = try AES.GCM.seal(try head.encoded(), using: objectKey(salt: salt), nonce: try AES.GCM.Nonce(data: nonce),
                                      authenticating: Data(header) + Data(key.utf8))
        return Data(header) + sealed.ciphertext + sealed.tag
    }

    func openHead(_ data: Data, kind: EnvelopeKind, key: String, bookKey: String) throws -> SyncHead {
        let damaged = SyncError.objectDamaged(key: key)
        let bytes = [UInt8](data)
        guard bytes.count >= Self.envelopeHeaderSize + 16, Array(bytes[0..<8]) == Self.envelopeMagic else { throw damaged }
        guard bytes[8] == Self.envelopeVersion else {
            if bytes[8] > Self.envelopeVersion, bytes[8] <= Self.highestPlausibleEnvelopeVersion {
                throw SyncError.newerFormatVersion(Int(bytes[8]))
            }
            throw damaged
        }
        guard bytes[9] == kind.rawValue else { throw damaged }
        let header = Array(bytes[0..<Self.envelopeHeaderSize])
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: bytes[42..<54]),
                                            ciphertext: bytes[Self.envelopeHeaderSize..<(bytes.count - 16)],
                                            tag: bytes[(bytes.count - 16)...])
            plaintext = try AES.GCM.open(box, using: objectKey(salt: Array(bytes[10..<42])),
                                         authenticating: Data(header) + Data(key.utf8))
        } catch {
            throw damaged
        }
        let head = try SyncHead.decode(plaintext, key: key)
        guard (try? keys.bookKey(pdfSHA256: head.references.pdf.sha256)) == bookKey else { throw damaged }
        return head
    }

    private func objectKey(salt: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: keys.contentKey, salt: salt, info: Self.envelopeKeyInfo, outputByteCount: 32)
    }

    // MARK: Files

    private func blobMetadata(_ content: ContentDigest, key: String) -> [String: String] {
        ["kind": "sync-blob", "object": key, "sha256": content.sha256.lowercased(), "size": String(content.size)]
    }

    private func pdfMetadata(_ pdf: ContentDigest, key: String) -> [String: String] {
        EncryptedBackupDestination.pdfObjectMetadata(sha256: pdf.sha256, size: pdf.size,
                                                     objectName: String(key.dropFirst(SyncLayout.pdfsPrefix.count)))
    }

    static func encryptedSize(of content: ContentDigest, metadata: [String: String]) -> Int64 {
        BackupFileEncryption.encryptedSize(plaintextSize: content.size, metadata: metadata)
    }

    private func downloadAndOpen(key: String, to file: URL, master: BackupEncryptionKey, metadata: [String: String],
                                 content: ContentDigest) async throws {
        let sealed = try temporaryFile()
        defer { removeQuietly(sealed) }
        try await store.download(key, to: sealed)
        try open(sealed, to: file, master: master, key: key, metadata: metadata, content: content)
    }

    /// Decrypts a `.ttenc` file, requiring exactly `metadata` and a plaintext of `content`.
    private func open(_ sealed: URL, to file: URL, master: BackupEncryptionKey, key: String,
                      metadata expected: [String: String], content: ContentDigest) throws {
        let expectedContent = ContentDigest(sha256: content.sha256.lowercased(), size: content.size)
        do {
            try BackupFileEncryption.decrypt(sealed, to: file, key: master, name: key, checkMetadata: { metadata in
                guard metadata == expected else { throw SyncError.objectDamaged(key: key) }
            }, checkPlaintext: { digest in
                guard digest == expectedContent else { throw SyncError.contentMismatch(key: key) }
            })
        } catch BackupError.encryptedObjectDamaged {
            throw SyncError.objectDamaged(key: key)
        } catch BackupError.newerFormatVersion(let version) {
            throw SyncError.newerFormatVersion(version)
        }
    }

    private func temporaryFile() throws -> URL {
        try mappingFileErrors(temporaryDirectory) {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        }
        return temporaryDirectory.appendingPathComponent("TactileTexts-Sync-\(UUID().uuidString).tmp", isDirectory: false)
    }

    private func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs a Foundation file operation, reporting its failure as a `BackupError` naming `url`'s file.
func mappingFileErrors<T>(_ url: URL, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
        throw BackupError.notEnoughSpace
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        throw BackupError.fileNotFound(name: url.lastPathComponent)
    } catch let error as CocoaError {
        throw BackupError.fileAccessFailed(name: url.lastPathComponent, code: error.code.rawValue)
    }
}

/// `true` when the byte arrays are equal, in time that depends only on their lengths.
func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<a.count { difference |= a[index] ^ b[index] }
    return difference == 0
}
