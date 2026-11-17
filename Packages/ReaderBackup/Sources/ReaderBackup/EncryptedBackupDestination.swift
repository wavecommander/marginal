import Foundation
import CryptoKit

/// What a store's key check says about a key.
public enum BackupKeyCheckResult: Hashable, Sendable {
    /// The store's backups were encrypted with this key.
    case matches
    /// The store's backups were encrypted with a different key: the reader must enter their
    /// recovery key. Nothing is uploaded or deleted meanwhile.
    case differentKey
    /// The store holds nothing that says which key it uses (a new, empty store). The first
    /// upload records this key.
    case nothingStored
}

/// A `BackupDestination` that encrypts everything on the device before it reaches a
/// `BackupBlobStore`, so the store (and whoever runs it) holds only unreadable data. The backup
/// engine uses it like any other destination.
///
/// ## Objects
///
///     Backups/<timestamp>.<protected device name>.ttenc   one per snapshot
///     PDFs/<keyed hash of the PDF's SHA-256>.ttenc          one per PDF
///     key-check                                             one per store
///
/// Every `.ttenc` object is a file in `BackupFileEncryption`'s format, whose encrypted metadata
/// says what it is: `{"kind":"snapshot","name":<snapshot name>,"object":<object name>}` or
/// `{"kind":"pdf","object":<object name>,"sha256":<hex>,"size":<decimal>}`. A download checks it,
/// so an object renamed over another (authentic, but not the one asked for) is refused.
///
/// **Snapshot names.** The timestamp stays in the clear (`YYYY-MM-DDTHH-MM-SSZ`, as in
/// `SnapshotName`) so listing and retention can order snapshots without downloading them. The
/// device name is encrypted deterministically with a synthetic nonce (the SIV pattern):
///
///     A  = the 20 timestamp bytes (ASCII)
///     P  = the device name in UTF-8, cut at a character boundary to at most 64 bytes and
///          padded with 0x00 to exactly 64 bytes (sanitised names contain no NUL)
///     N  = first 12 bytes of HMAC-SHA256(K_siv, A ‖ P)
///     C‖T = AES-256-GCM(K_enc, nonce N, plaintext P, associated data A)   (64 + 16 bytes)
///     object name = A ‖ "." ‖ base32(N ‖ C ‖ T) ‖ ".ttenc"
///
/// with `K_siv` and `K_enc` the `snapshot-name.siv` and `snapshot-name.encryption` sub-keys of
/// `BackupEncryptionKey`, and base32 the lower-case Crockford alphabet
/// `0123456789abcdefghjkmnpqrstvwxyz` over the 92 bytes, big-endian, zero-padded (148
/// characters). Reading a name opens the GCM box (authenticating the device name and binding
/// it to its timestamp), recomputes `N` from what it opened and requires it to match, then
/// strips the padding. Names that do not open are ignored.
///
/// *Why determinism is safe here:* the same timestamp and device name must give the same object
/// name, so that uploading a snapshot name again replaces it and deleting finds it. A GCM nonce
/// is only dangerous when reused for *different* inputs; here the nonce is a PRF of the whole
/// input (timestamp and padded name), so equal nonces mean equal inputs and identical outputs,
/// and distinct inputs collide on a 96-bit nonce with negligible probability. What determinism
/// reveals is only equality: an observer sees that two names with the same timestamp have the
/// same device, which the identical name already shows. Padding to 64 bytes hides the name's
/// length. A device name longer than 64 UTF-8 bytes is listed cut short (the full name is in the
/// encrypted metadata).
///
/// **PDF names** are `hex(HMAC-SHA256(K_pdf, <lower-case hex SHA-256>)) + ".ttenc"`, so the
/// operator cannot recognise a well-known PDF by its hash, and two keys give unrelated names.
///
/// ## The key check
///
/// `key-check` is a 49-byte object written on first upload:
///
///     0   8   magic 89 54 54 4B 45 59 0D 0A ("\x89TTKEY\r\n")
///     8   1   version 1
///     9   32  HMAC-SHA256(K_check, "tactile-texts.backup.v1.key-check.identifier")
///     41  8   first 8 bytes of SHA-256(bytes 0 ..< 41)
///
/// The unkeyed checksum tells random damage apart from a different key. When the key check is
/// missing or damaged, the snapshot names (authenticated with the key) are the evidence: if any
/// opens, the key matches; if there are snapshot objects and none opens, the key is different;
/// otherwise nothing is stored yet. Uploads and deletes are refused (`wrongEncryptionKey`)
/// unless the key matches or nothing is stored; the first upload then writes the key check and
/// reads it back. A confirmed key is remembered for the life of the destination value (and its
/// copies). Listing and downloading with a different key throw `wrongEncryptionKey` rather than
/// showing nothing or reporting damage.
///
/// ## Temporary space
///
/// A file is encrypted to (or downloaded into) `temporaryDirectory` first; the temporary file
/// is removed in every outcome. Before that, `availableCapacity` is asked for the free space
/// and a transfer that does not fit throws `notEnoughSpace`.
public struct EncryptedBackupDestination: BackupDestination, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Free bytes on the volume holding a directory, or `nil` when unknown (not checked then).
    public typealias AvailableCapacity = @Sendable (_ directory: URL) -> Int64?

    /// The system's figure for important work (`volumeAvailableCapacityForImportantUsage`).
    public static let volumeAvailableCapacity: AvailableCapacity = { directory in
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Name of the top-level key check object.
    public static let keyCheckObjectName = "key-check"
    /// Extension of every encrypted object.
    public static let objectExtension = "ttenc"

    public let id: String
    public let displayName: String
    /// Where the encrypted objects are kept.
    public let store: any BackupBlobStore
    private let key: BackupEncryptionKey
    private let names: ObjectNames
    private let temporaryDirectory: URL
    private let availableCapacity: AvailableCapacity
    private let keyState = KeyState()

    /// A destination keeping `store`'s objects encrypted with `key`. Temporary files go in
    /// `temporaryDirectory`, whose free space `availableCapacity` reports.
    public init(id: String, displayName: String, store: any BackupBlobStore, key: BackupEncryptionKey,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                availableCapacity: @escaping AvailableCapacity = EncryptedBackupDestination.volumeAvailableCapacity) {
        self.id = id
        self.displayName = displayName
        self.store = store
        self.key = key
        self.names = ObjectNames(key: key)
        self.temporaryDirectory = temporaryDirectory
        self.availableCapacity = availableCapacity
    }

    public var description: String { "EncryptedBackupDestination(id: \(id), displayName: \(displayName))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id, "displayName": displayName], displayStyle: .struct) }

    // MARK: - Key check

    /// Whether `key` is the store's key, reading the key check (or, without one, the snapshot
    /// names). Throws the store's errors, `newerFormatVersion` for a key check from a newer app.
    public func checkKey() async throws -> BackupKeyCheckResult {
        let (result, stored) = try await examineKey()
        if result == .matches, stored { keyState.confirm() }
        return result
    }

    public func availability() async -> BackupDestinationAvailability {
        let storeAvailability = await store.availability()
        guard storeAvailability.isAvailable else { return storeAvailability }
        do {
            return try await checkKey() == .differentKey
                ? .unavailable(reason: BackupError.wrongEncryptionKey.localizedDescription) : .available
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Snapshots

    public func listSnapshots() async throws -> [BackupSnapshotInfo] {
        try await requireKey(forWriting: false)
        return try await store.list(.backups).compactMap { object in
            guard let parsed = names.openSnapshotObjectName(object.name) else { return nil }
            return Self.info(objectName: object.name, createdAt: parsed.createdAt, deviceName: parsed.deviceName, byteSize: object.byteSize)
        }
        .sorted(by: BackupSnapshotInfo.newestFirst)
    }

    @discardableResult
    public func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        guard !name.contains("/"), !name.hasPrefix("."), !name.utf8.contains(0), let parsed = SnapshotName.parse(name) else {
            throw BackupError.invalidSnapshotName(name: name)
        }
        try await requireKey(forWriting: true)
        let deviceName = ObjectNames.storedDeviceName(parsed.deviceName)
        let objectName = names.snapshotObjectName(createdAt: parsed.createdAt, deviceName: deviceName)
        guard let plaintextSize = FileOps.regularFileSize(file) else { throw BackupError.fileNotFound(name: file.lastPathComponent) }
        let metadata = ["kind": "snapshot", "name": name, "object": objectName]
        try ensureSpace(BackupFileEncryption.encryptedSize(plaintextSize: plaintextSize, metadata: metadata))

        let temporary = try temporaryFile()
        defer { FileOps.removeQuietly(temporary) }
        try BackupFileEncryption.encrypt(file, to: temporary, key: key, metadata: metadata, progress: part(progress, 0, 0.5))
        let storedSize = FileOps.regularFileSize(temporary) ?? 0
        try await store.upload(from: temporary, to: .backup(objectName), progress: part(progress, 0.5, 1))
        progress?(1)
        return Self.info(objectName: objectName, createdAt: parsed.createdAt, deviceName: deviceName, byteSize: storedSize)
    }

    public func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        guard ObjectNames.decodeSnapshotObjectName(snapshot.id) != nil else { throw BackupError.invalidSnapshotName(name: snapshot.id) }
        try await requireKey(forWriting: false)
        guard names.openSnapshotObjectName(snapshot.id) != nil else { throw BackupError.invalidSnapshotName(name: snapshot.id) }
        let object = BackupBlobKey.backup(snapshot.id)
        let notFound = BackupError.snapshotNotFound(name: snapshot.name)
        let damaged = BackupError.encryptedObjectDamaged(name: snapshot.name)
        guard let size = try await store.size(of: object) else { throw notFound }
        try ensureSpace(size)

        let temporary = try temporaryFile()
        defer { FileOps.removeQuietly(temporary) }
        try await download(object, to: temporary, notFound: notFound, progress: part(progress, 0, 0.5))
        try BackupFileEncryption.decrypt(temporary, to: file, key: key, name: snapshot.name, progress: part(progress, 0.5, 1),
                                         checkMetadata: { metadata in
            guard metadata["kind"] == "snapshot", metadata["object"] == snapshot.id else { throw damaged }
        })
        progress?(1)
    }

    public func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        guard ObjectNames.decodeSnapshotObjectName(snapshot.id) != nil else { throw BackupError.invalidSnapshotName(name: snapshot.id) }
        try await requireKey(forWriting: false)
        guard names.openSnapshotObjectName(snapshot.id) != nil else { throw BackupError.invalidSnapshotName(name: snapshot.id) }
        try await store.delete(.backup(snapshot.id))
    }

    // MARK: - PDFs

    public func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        let hash = try Self.validHash(sha256)
        try await requireKey(forWriting: false)
        let objectName = names.pdfObjectName(sha256: hash)
        return try await store.size(of: .pdf(objectName)) == Self.encryptedPDFSize(sha256: hash, size: size, objectName: objectName)
    }

    public func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        try await requireKey(forWriting: true)
        let objectName = names.pdfObjectName(sha256: hash)
        let object = BackupBlobKey.pdf(objectName)
        let encryptedSize = Self.encryptedPDFSize(sha256: hash, size: size, objectName: objectName)
        if try await store.size(of: object) == encryptedSize {
            progress?(1)
            return
        }
        try ensureSpace(encryptedSize)

        let temporary = try temporaryFile()
        defer { FileOps.removeQuietly(temporary) }
        let digest = try BackupFileEncryption.encrypt(file, to: temporary, key: key,
                                                      metadata: Self.pdfMetadata(sha256: hash, size: size, objectName: objectName),
                                                      progress: part(progress, 0, 0.5))
        guard digest == ContentDigest(sha256: hash, size: size) else { throw BackupError.contentMismatch(name: file.lastPathComponent) }
        try await store.upload(from: temporary, to: object, progress: part(progress, 0.5, 1))
        progress?(1)
    }

    public func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        let hash = try Self.validHash(sha256)
        try await requireKey(forWriting: false)
        let objectName = names.pdfObjectName(sha256: hash)
        let object = BackupBlobKey.pdf(objectName)
        let notFound = BackupError.pdfNotAtDestination(sha256: hash)
        guard let size = try await store.size(of: object) else { throw notFound }
        try ensureSpace(size)

        let temporary = try temporaryFile()
        defer { FileOps.removeQuietly(temporary) }
        try await download(object, to: temporary, notFound: notFound, progress: part(progress, 0, 0.5))
        let fileName = BackupFolderLayout.pdfFileName(sha256: hash)
        let mismatch = BackupError.contentMismatch(name: fileName)
        try BackupFileEncryption.decrypt(temporary, to: file, key: key, name: fileName, progress: part(progress, 0.5, 1),
                                         checkMetadata: { metadata in
            guard metadata["kind"] == "pdf", metadata["sha256"] == hash else { throw mismatch }
        }, checkPlaintext: { digest in
            guard digest.sha256 == hash else { throw mismatch }
        })
        progress?(1)
    }

    // MARK: - PDF objects for other packages

    /// The name, within `PDFs/` (`BackupBlobFolder.pdfs`), of the object holding the PDF whose
    /// SHA-256 is `sha256` under `key`: `hex(HMAC-SHA256(K_pdf, <lower-case hex SHA-256>)).ttenc`
    /// (see "PDF names"). Sync stores a book's PDF under this same name, in this same format
    /// (`BackupFileEncryption` with `key` and `pdfObjectMetadata`), so a PDF is stored once for
    /// backups and sync. Throws `pdfNotAtDestination` when `sha256` is not 64 hex digits.
    public static func pdfObjectName(sha256: String, key: BackupEncryptionKey) throws -> String {
        ObjectNames(key: key).pdfObjectName(sha256: try validHash(sha256))
    }

    /// The encrypted metadata of a PDF object (see "Objects"):
    /// `{"kind":"pdf","object":<objectName>,"sha256":<hex>,"size":<decimal>}`. A download refuses
    /// an object whose metadata does not name the PDF asked for.
    public static func pdfObjectMetadata(sha256: String, size: Int64, objectName: String) -> [String: String] {
        pdfMetadata(sha256: sha256.lowercased(), size: size, objectName: objectName)
    }

    // MARK: - Internals

    private static func info(objectName: String, createdAt: Date, deviceName: String, byteSize: Int64) -> BackupSnapshotInfo {
        BackupSnapshotInfo(id: objectName, name: SnapshotName.make(createdAt: createdAt, deviceName: deviceName),
                           createdAt: createdAt, deviceName: deviceName, byteSize: byteSize)
    }

    private static func pdfMetadata(sha256: String, size: Int64, objectName: String) -> [String: String] {
        ["kind": "pdf", "object": objectName, "sha256": sha256, "size": String(size)]
    }

    private static func encryptedPDFSize(sha256: String, size: Int64, objectName: String) -> Int64 {
        BackupFileEncryption.encryptedSize(plaintextSize: size, metadata: pdfMetadata(sha256: sha256, size: size, objectName: objectName))
    }

    private static func validHash(_ sha256: String) throws -> String {
        let hash = sha256.lowercased()
        guard ContentHash.isValidSHA256(hash) else { throw BackupError.pdfNotAtDestination(sha256: sha256) }
        return hash
    }

    /// Downloads through the store, reporting a missing object as `notFound`.
    private func download(_ object: BackupBlobKey, to file: URL, notFound: BackupError, progress: BackupProgress?) async throws {
        do {
            try await store.download(object, to: file, progress: progress)
        } catch BackupError.fileNotFound(name: object.name) {
            throw notFound
        }
    }

    private func temporaryFile() throws -> URL {
        try FileOps.createDirectory(temporaryDirectory)
        return temporaryDirectory.appendingPathComponent("TactileTexts-\(UUID().uuidString).\(Self.objectExtension)", isDirectory: false)
    }

    private func ensureSpace(_ bytes: Int64) throws {
        if let available = availableCapacity(temporaryDirectory), available < bytes { throw BackupError.notEnoughSpace }
    }

    /// `progress` mapped onto `from ... to`.
    private func part(_ progress: BackupProgress?, _ from: Double, _ to: Double) -> BackupProgress? {
        guard let progress else { return nil }
        return { progress(from + (to - from) * min(max($0, 0), 1)) }
    }

    /// Throws `wrongEncryptionKey` unless the key may be used: it matches, or (for reading)
    /// nothing is stored. For writing with no key check stored, writes one and reads it back.
    private func requireKey(forWriting: Bool) async throws {
        if keyState.isConfirmed { return }
        let (result, stored) = try await examineKey()
        switch result {
        case .differentKey:
            throw BackupError.wrongEncryptionKey
        case .matches where stored:
            keyState.confirm()
        case .matches, .nothingStored:
            guard forWriting else { return }
            try await writeKeyCheck()
            let (again, storedAgain) = try await examineKey()
            // Another device wrote a different key check at the same moment.
            guard again == .matches, storedAgain else { throw BackupError.wrongEncryptionKey }
            keyState.confirm()
        }
    }

    /// The key check's verdict, and whether a usable key check object is stored.
    private func examineKey() async throws -> (BackupKeyCheckResult, Bool) {
        let checkObject = BackupBlobKey.control(Self.keyCheckObjectName)
        if let size = try await store.size(of: checkObject), size <= 1024 {
            let temporary = try temporaryFile()
            defer { FileOps.removeQuietly(temporary) }
            var data: Data?
            do {
                try await store.download(checkObject, to: temporary, progress: nil)
                data = try mappingFileErrors(temporary) { try Data(contentsOf: temporary) }
            } catch BackupError.fileNotFound(name: checkObject.name) {
                data = nil // deleted in the meantime
            }
            if let data {
                switch KeyCheckObject.read(data, key: names.keyCheckKey) {
                case .matches: return (.matches, true)
                case .differentKey: return (.differentKey, true)
                case .newerVersion(let version): throw BackupError.newerFormatVersion(version)
                case .damaged: break // fall back on the snapshot names
                }
            }
        }
        var sawSnapshotObject = false
        for object in try await store.list(.backups) where ObjectNames.decodeSnapshotObjectName(object.name) != nil {
            sawSnapshotObject = true
            if names.openSnapshotObjectName(object.name) != nil { return (.matches, false) }
        }
        return (sawSnapshotObject ? .differentKey : .nothingStored, false)
    }

    private func writeKeyCheck() async throws {
        let temporary = try temporaryFile()
        defer { FileOps.removeQuietly(temporary) }
        try mappingFileErrors(temporary) { try KeyCheckObject.make(key: names.keyCheckKey).write(to: temporary) }
        try await store.upload(from: temporary, to: .control(Self.keyCheckObjectName), progress: nil)
    }
}

/// Whether the key has been confirmed against the store, shared by copies of a destination.
private final class KeyState: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed = false

    var isConfirmed: Bool { lock.withLock { confirmed } }
    func confirm() { lock.withLock { confirmed = true } }
}

/// The key check object (see `EncryptedBackupDestination`).
enum KeyCheckObject {
    static let magic: [UInt8] = [0x89, 0x54, 0x54, 0x4B, 0x45, 0x59, 0x0D, 0x0A]
    static let version: UInt8 = 1
    static let size = 49
    static let identifierMessage = Data("tactile-texts.backup.v1.key-check.identifier".utf8)

    enum Verdict: Equatable {
        case matches, differentKey, damaged
        case newerVersion(Int)
    }

    static func make(key: SymmetricKey) -> Data {
        var bytes = magic
        bytes.append(version)
        bytes.append(contentsOf: HMAC<SHA256>.authenticationCode(for: identifierMessage, using: key))
        bytes.append(contentsOf: SHA256.hash(data: bytes).prefix(8))
        return Data(bytes)
    }

    static func read(_ data: Data, key: SymmetricKey) -> Verdict {
        let bytes = [UInt8](data)
        guard bytes.count == size, Array(bytes[0..<8]) == magic,
              Array(SHA256.hash(data: bytes[0..<41]).prefix(8)) == Array(bytes[41..<49]) else { return .damaged }
        guard bytes[8] == version else {
            return bytes[8] > version ? .newerVersion(Int(bytes[8])) : .damaged
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes[9..<41], authenticating: identifierMessage, using: key)
            ? .matches : .differentKey
    }
}

/// The object names of `EncryptedBackupDestination` (see there).
struct ObjectNames: Sendable, CustomStringConvertible, CustomReflectable {
    static let deviceNameBlockSize = 64
    static let nonceSize = 12
    static let tokenSize = nonceSize + deviceNameBlockSize + 16
    static let timestampLength = 20
    static let suffix = ".\(EncryptedBackupDestination.objectExtension)"

    let nameEncryptionKey: SymmetricKey
    let nameSIVKey: SymmetricKey
    let pdfNameKey: SymmetricKey
    let keyCheckKey: SymmetricKey

    init(key: BackupEncryptionKey) {
        nameEncryptionKey = key.subkey(.snapshotNameEncryption)
        nameSIVKey = key.subkey(.snapshotNameSIV)
        pdfNameKey = key.subkey(.pdfName)
        keyCheckKey = key.subkey(.keyCheck)
    }

    var description: String { "ObjectNames(redacted)" }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// The device name as it is stored and listed: cut at a character boundary to at most 64
    /// UTF-8 bytes (`iPad` if nothing is left).
    static func storedDeviceName(_ deviceName: String) -> String {
        var result = ""
        var bytes = 0
        for character in deviceName {
            let count = character.utf8.count
            guard bytes + count <= deviceNameBlockSize else { break }
            result.append(character)
            bytes += count
        }
        return result.isEmpty ? "iPad" : result
    }

    /// `<timestamp>.<base32 token>.ttenc` for a device name already cut by `storedDeviceName`.
    func snapshotObjectName(createdAt: Date, deviceName: String) -> String {
        let timestamp = SnapshotName.timestamp(createdAt)
        let associated = Data(timestamp.utf8)
        var padded = [UInt8](deviceName.utf8)
        precondition(padded.count <= Self.deviceNameBlockSize)
        padded += [UInt8](repeating: 0, count: Self.deviceNameBlockSize - padded.count)
        let nonceBytes = syntheticNonce(associated: associated, padded: padded)
        // 12 bytes: always a valid nonce; sealing with a valid key cannot fail.
        let sealed = try! AES.GCM.seal(padded, using: nameEncryptionKey, nonce: try! AES.GCM.Nonce(data: nonceBytes), authenticating: associated)
        let token = nonceBytes + [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
        return "\(timestamp).\(Base32.lowercaseString(token))\(Self.suffix)"
    }

    /// The timestamp, date and token of a name with the shape of a snapshot object name, or
    /// `nil`; nothing is authenticated yet.
    static func decodeSnapshotObjectName(_ name: String) -> (timestamp: String, createdAt: Date, token: [UInt8])? {
        guard name.hasSuffix(suffix), name.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let stem = name.dropLast(suffix.count)
        guard stem.count > timestampLength + 1 else { return nil }
        let timestamp = String(stem.prefix(timestampLength))
        let rest = stem.dropFirst(timestampLength)
        guard rest.first == ".", let date = SnapshotName.parseTimestamp(timestamp),
              let token = Base32.bytes(fromLowercase: rest.dropFirst(), byteCount: tokenSize) else { return nil }
        return (timestamp, date, token)
    }

    /// The date and device name of a snapshot object name made with this key, or `nil` when the
    /// name is not one (another key's, or altered).
    func openSnapshotObjectName(_ name: String) -> (createdAt: Date, deviceName: String)? {
        guard let decoded = Self.decodeSnapshotObjectName(name) else { return nil }
        let token = decoded.token
        let associated = Data(decoded.timestamp.utf8)
        let nonceBytes = Array(token[0..<Self.nonceSize])
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: token[Self.nonceSize..<(Self.tokenSize - 16)],
                                               tag: token[(Self.tokenSize - 16)...]),
              let opened = try? AES.GCM.open(box, using: nameEncryptionKey, authenticating: associated) else { return nil }
        let padded = [UInt8](opened)
        guard constantTimeEqual(syntheticNonce(associated: associated, padded: padded), nonceBytes) else { return nil }
        let end = (padded.lastIndex(where: { $0 != 0 }) ?? -1) + 1
        guard end > 0, !padded[0..<end].contains(0),
              let deviceName = String(bytes: padded[0..<end], encoding: .utf8) else { return nil }
        return (decoded.createdAt, deviceName)
    }

    /// `<hex HMAC-SHA256(K_pdf, sha256)>.ttenc`
    func pdfObjectName(sha256: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(sha256.utf8), using: pdfNameKey).map { String(format: "%02x", $0) }.joined() + Self.suffix
    }

    private func syntheticNonce(associated: Data, padded: [UInt8]) -> [UInt8] {
        var message = associated
        message.append(contentsOf: padded)
        return Array(HMAC<SHA256>.authenticationCode(for: message, using: nameSIVKey).prefix(Self.nonceSize))
    }
}
