import Foundation
import ReaderBackup
import ReaderCore

/// The hashes of a book's files as they were in the base. No ink bytes: the base ink of a page
/// or note is fetched from its blob when a merge needs it.
public struct SyncBaseFiles: Codable, Hashable, Sendable {
    /// One per inked page, ascending by page.
    public var pageInk: [SyncPageInkReference]
    /// One per note with ink.
    public var noteInk: [SyncNoteInkReference]
    /// `cover.jpg`.
    public var cover: ContentDigest?
    /// `conversion.json`.
    public var conversion: ContentDigest?

    public init(pageInk: [SyncPageInkReference] = [], noteInk: [SyncNoteInkReference] = [], cover: ContentDigest? = nil,
                conversion: ContentDigest? = nil) {
        self.pageInk = pageInk
        self.noteInk = noteInk
        self.cover = cover
        self.conversion = conversion
    }

    /// The files a head names.
    public init(_ references: SyncReferences) {
        self.init(pageInk: references.pageInk, noteInk: references.noteInk, cover: references.cover,
                  conversion: references.conversion)
    }
}

/// A book's base: what this device and the account last agreed the book was
/// (`docs/CLOUD_SYNC_PLAN.md` "The model"). It moves forward only after a sync round for the
/// book succeeds, so an interrupted round is simply repeated.
public struct SyncBase: Codable, Hashable, Sendable {
    /// The base format this code writes and reads.
    public static let currentFormatVersion = 1

    /// `currentFormatVersion` when written.
    public var formatVersion: Int
    /// The book's sync key.
    public var bookKey: String
    /// The head this base corresponds to: its version and the ETag it had.
    public var headVersion: Int
    public var headETag: String
    /// The records as they were.
    public var archive: BookArchive
    /// The hash of every ink file, the cover and `conversion.json` as they were.
    public var files: SyncBaseFiles

    public init(bookKey: String, headVersion: Int, headETag: String, archive: BookArchive, files: SyncBaseFiles) {
        self.formatVersion = Self.currentFormatVersion
        self.bookKey = bookKey
        self.headVersion = headVersion
        self.headETag = headETag
        self.archive = archive
        self.files = files
    }
}

/// The bases of one account, on disk: `<root>/<book ID>/base.json`, one per synced book.
///
/// The caller roots it at `Application Support/Sync/<account>/bases`, outside every book's own
/// directory, so backups, restores and older versions never see it. `base.json` is the
/// `SyncBase` in the backup format's JSON coding (`BackupCoding`), replaced atomically (written
/// beside it, then renamed), so a crash leaves the old base or the new one, never a mix.
/// A base that cannot be read (damaged, or from a newer app) throws `baseUnreadable`; the caller
/// treats that book as having no base, which makes the next round a join (add-only, so nothing is
/// lost).
public struct SyncBaseStore: Sendable {
    /// The account's bases directory.
    public let root: URL
    static let fileName = "base.json"

    public init(root: URL) {
        self.root = root
    }

    /// The book's base, or `nil` when it has none.
    public func base(bookID: UUID) throws -> SyncBase? {
        let url = file(bookID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try mappingFileErrors(url) { try Data(contentsOf: url) }
        guard let base = try? BackupCoding.makeDecoder().decode(SyncBase.self, from: data),
              base.formatVersion == SyncBase.currentFormatVersion, base.archive.book.id == bookID else {
            throw SyncError.baseUnreadable(bookID: bookID)
        }
        return base
    }

    /// Replaces the book's base (the book is `base.archive.book.id`) atomically.
    public func replace(_ base: SyncBase) throws {
        let bookID = base.archive.book.id
        let data = try BackupCoding.makeEncoder().encode(base)
        let url = file(bookID)
        try mappingFileErrors(url) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Removes the book's base (it is no longer synced, or was deleted everywhere).
    public func remove(bookID: UUID) throws {
        let directory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try mappingFileErrors(directory) {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }

    /// Removes every base of the account.
    public func removeAll() throws {
        try mappingFileErrors(root) {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
    }

    /// The books that have a base, in no particular order.
    public func bookIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let names = try mappingFileErrors(root) { try FileManager.default.contentsOfDirectory(atPath: root.path) }
        return names.compactMap { name in
            guard let id = UUID(uuidString: name), id.uuidString == name,
                  FileManager.default.fileExists(atPath: file(id).path) else { return nil }
            return id
        }
    }

    private func file(_ bookID: UUID) -> URL {
        root.appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }
}
