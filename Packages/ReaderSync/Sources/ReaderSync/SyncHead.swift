import Foundation
import ReaderBackup
import ReaderCore

/// The versions of the sync format this code writes and reads.
public enum SyncFormat {
    /// The head format version this code writes, and the highest it reads. A head (or head
    /// envelope) with a higher one stops sync for the account (`SyncVersionRules`).
    public static let formatVersion = 1
    /// This app's writer level: the highest head writer level it may write over (it reads every
    /// level, `SyncVersionRules`). Raised by a release that stores something in a head or a
    /// records blob that an older release would drop, or misread, if it wrote the book back.
    ///
    /// Level 2 (C5, 18 November 2026) adds the **tombstone**: a deleted head whose content has
    /// been collected (`SyncHead.isTombstone`). A level-1 app would read its missing records as
    /// damage, so a tombstone carries level 2 and such an app pulls it (deleting its own
    /// unchanged copy) but never pushes over it.
    public static let writerLevel = 2
    /// The level a head carries: the lowest app level that can write it back without loss. An
    /// ordinary head (live or deleted with its content) needs nothing above level 1, so older
    /// apps keep syncing every ordinary book.
    public static let ordinaryHeadLevel = 1
    /// The level a tombstone carries.
    public static let tombstoneLevel = 2
}

/// A book's head: one small encrypted object at `Sync/v1/books/<book key>` saying what the
/// book is now. Everything a head names is content-addressed (plaintext SHA-256 and size), so a
/// device fetches only what it lacks; a head is replaced only by a conditional write on the
/// ETag the writer read (`EncryptedSyncStore`).
///
/// **Coding.** JSON with sorted keys, dates as seconds since 2001-01-01 (`Date`'s default, as
/// in backups). Decoding ignores keys this version does not know, so a newer app's additions
/// are read past (and the version rules stop this app from pushing over them). Field names are
/// frozen; a change of meaning raises `SyncFormat.formatVersion`.
public struct SyncHead: Codable, Hashable, Sendable {
    /// The head format version it was written in (`SyncFormat.formatVersion`).
    public var formatVersion: Int
    /// The lowest app writer level that may write over it (`SyncFormat.ordinaryHeadLevel`, or
    /// `tombstoneLevel` for a tombstone; a newer app's own levels above).
    public var writerLevel: Int
    /// 1 for a book's first head, then one more for each head written over it.
    public var version: Int
    /// The version this head replaced; `nil` for the first.
    public var previousVersion: Int?
    /// 32 random lower-case hex digits, new for every write. Also stored in the clear as the
    /// object's `write-id` metadata, so a write whose answer was lost can be reconciled.
    public var writeID: String
    /// The writing device's sync identity.
    public var deviceID: UUID
    /// The writing device's name, for the history view.
    public var deviceName: String
    /// When the writing device wrote it, by its own clock (shown, never used to merge).
    public var modifiedAt: Date
    /// When the book was deleted, if it was: the head stays, saying so, for 30 days.
    public var deletedAt: Date?
    /// What the Library shows before any content is fetched.
    public var book: SyncBookInfo
    /// The content that makes up the book now.
    public var references: SyncReferences

    public init(formatVersion: Int = SyncFormat.formatVersion, writerLevel: Int = SyncFormat.ordinaryHeadLevel,
                version: Int, previousVersion: Int?, writeID: String = SyncHead.makeWriteID(), deviceID: UUID,
                deviceName: String, modifiedAt: Date, deletedAt: Date? = nil, book: SyncBookInfo,
                references: SyncReferences) {
        self.formatVersion = formatVersion
        self.writerLevel = writerLevel
        self.version = version
        self.previousVersion = previousVersion
        self.writeID = writeID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.book = book
        self.references = references
    }

    /// Whether the head says the book was deleted.
    public var isDeleted: Bool { deletedAt != nil }

    /// Whether the head is a **tombstone**: deleted, and more than 30 days ago, so housekeeping
    /// has let its content go. It keeps the deletion, the version and the dates (and the PDF's
    /// digest, which binds it to its book key) and refers to nothing: its records are
    /// `SyncReferences.noRecords` and it has no files. It cannot be restored. It stays so that a
    /// device offline for longer still learns the book was deleted (its unchanged copy is
    /// deleted, an edited one goes back up as it is) and so that no device's rollback guard ever
    /// sees the book's versions start again.
    public var isTombstone: Bool { isDeleted && references.isEmpty }

    /// This deleted head as a tombstone: version `version`, written by `device` at `date`.
    public func tombstone(version: Int, deviceID: UUID, deviceName: String, at date: Date) -> SyncHead {
        SyncHead(formatVersion: SyncFormat.formatVersion, writerLevel: max(writerLevel, SyncFormat.tombstoneLevel),
                 version: version, previousVersion: self.version, deviceID: deviceID, deviceName: deviceName,
                 modifiedAt: date, deletedAt: deletedAt ?? date, book: book,
                 references: SyncReferences(records: SyncReferences.noRecords, pdf: references.pdf))
    }

    /// What this app may do with the book (`SyncVersionRules.access`).
    public func access(appFormatVersion: Int = SyncFormat.formatVersion,
                       appLevel: Int = SyncFormat.writerLevel) -> SyncVersionRules.Access {
        SyncVersionRules.access(formatVersion: formatVersion, writerLevel: writerLevel,
                                appFormatVersion: appFormatVersion, appLevel: appLevel)
    }

    /// A new write ID: 16 random bytes as 32 lower-case hex digits.
    public static func makeWriteID() -> String {
        SyncLayout.hex(SyncRandomness.system.bytes(16))
    }

    /// `true` for 32 lower-case hex digits.
    public static func isValidWriteID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Whether the head keeps the format's rules: versions from 1 and increasing, a well-formed
    /// write ID, valid hashes and sizes, page indices within the book and no page or note
    /// listed twice. A head that breaks them is treated as damaged.
    public var isWellFormed: Bool {
        guard formatVersion >= 1, writerLevel >= 1, version >= 1, Self.isValidWriteID(writeID),
              previousVersion.map({ $0 >= 1 && $0 < version }) ?? true,
              book.pageCount >= 0, book.readingPosition.map({ $0.pageIndex >= 0 }) ?? true else { return false }
        let refs = references
        var digests = [refs.records, refs.pdf] + refs.pageInk.map(\.content) + refs.noteInk.map(\.content)
        if let cover = refs.cover { digests.append(cover) }
        if let conversion = refs.conversion { digests.append(conversion) }
        guard digests.allSatisfy({ ContentHash.isValidSHA256($0.sha256) && $0.size >= 0 }) else { return false }
        let pages = refs.pageInk.map(\.pageIndex)
        guard pages.allSatisfy({ $0 >= 0 }), Set(pages).count == pages.count,
              Set(refs.noteInk.map(\.noteID)).count == refs.noteInk.count else { return false }
        return true
    }

    // MARK: Coding

    /// The head's JSON: sorted keys, no whitespace, slashes unescaped.
    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Decodes a head's JSON. A format version above `SyncFormat.formatVersion` throws
    /// `SyncError.newerFormatVersion` before the rest is looked at; anything that does not
    /// decode, or is not `isWellFormed`, throws `SyncError.objectDamaged(key:)`.
    public static func decode(_ data: Data, key: String) throws -> SyncHead {
        struct Header: Decodable { var formatVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let header = try? decoder.decode(Header.self, from: data) else { throw SyncError.objectDamaged(key: key) }
        if header.formatVersion > SyncFormat.formatVersion { throw SyncError.newerFormatVersion(header.formatVersion) }
        guard let head = try? decoder.decode(SyncHead.self, from: data), head.isWellFormed else {
            throw SyncError.objectDamaged(key: key)
        }
        return head
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// What the Library needs to show a synced book before its PDF or records are here.
public struct SyncBookInfo: Codable, Hashable, Sendable {
    /// Display title.
    public var title: String
    public var pageCount: Int
    /// `Book.fingerprint`: the importer's identity of the file (of the original, for a
    /// converted book).
    public var fingerprint: String
    /// `Book.sourceFormat`'s raw value; `nil` for a book imported as a PDF. Kept as text so a
    /// format this version does not know is carried, not lost (see `importFormat`).
    public var sourceFormat: String?
    /// `Book.originalFileName`.
    public var originalFileName: String?
    /// `Book.converterVersion`.
    public var converterVersion: Int?
    /// The page the reader last read, and when, applied when the book is next opened.
    public var readingPosition: SyncReadingPosition?

    public init(title: String, pageCount: Int, fingerprint: String, sourceFormat: String? = nil,
                originalFileName: String? = nil, converterVersion: Int? = nil, readingPosition: SyncReadingPosition? = nil) {
        self.title = title
        self.pageCount = pageCount
        self.fingerprint = fingerprint
        self.sourceFormat = sourceFormat
        self.originalFileName = originalFileName
        self.converterVersion = converterVersion
        self.readingPosition = readingPosition
    }

    /// `sourceFormat` as an `ImportFormat`, `nil` for a PDF or a format this version does not know.
    public var importFormat: ImportFormat? { sourceFormat.flatMap(ImportFormat.init(rawValue:)) }
}

/// The page last read and when (the later one wins in a merge).
public struct SyncReadingPosition: Codable, Hashable, Sendable {
    /// Zero-based.
    public var pageIndex: Int
    public var date: Date

    public init(pageIndex: Int, date: Date) {
        self.pageIndex = pageIndex
        self.date = date
    }
}

/// The content that makes up a book, each by its plaintext SHA-256 and size. Every reference
/// but `pdf` names a blob (`Sync/v1/blobs/<blob name>`); `pdf` names the shared PDF object.
public struct SyncReferences: Codable, Hashable, Sendable {
    /// The records blob: the book's `BookArchive` JSON (`SyncRecords`).
    public var records: ContentDigest
    /// The PDF (`PDFs/<keyed hash>.ttenc`); its SHA-256 is what the book key is made from.
    public var pdf: ContentDigest
    /// One per inked page (`ink/<page>.drawing`), ascending by page.
    public var pageInk: [SyncPageInkReference]
    /// One per note with ink (`notes/<note ID>.drawing`).
    public var noteInk: [SyncNoteInkReference]
    /// `cover.jpg`, when the book has one.
    public var cover: ContentDigest?
    /// `conversion.json`, for a converted book.
    public var conversion: ContentDigest?

    public init(records: ContentDigest, pdf: ContentDigest, pageInk: [SyncPageInkReference] = [],
                noteInk: [SyncNoteInkReference] = [], cover: ContentDigest? = nil, conversion: ContentDigest? = nil) {
        self.records = records
        self.pdf = pdf
        self.pageInk = pageInk
        self.noteInk = noteInk
        self.cover = cover
        self.conversion = conversion
    }

    /// The records digest of a tombstone: the SHA-256 of no bytes, size 0. No records blob is
    /// ever empty (its JSON has at least the book), so this names nothing.
    public static let noRecords = ContentDigest(sha256: ContentHash.sha256(of: Data()), size: 0)

    /// Whether it refers to no content at all (a tombstone's references): no records, no files.
    public var isEmpty: Bool {
        records == Self.noRecords && pageInk.isEmpty && noteInk.isEmpty && cover == nil && conversion == nil
    }

    /// Every blob the head names (not the PDF), without repeats; none for a tombstone's.
    public var blobs: [ContentDigest] {
        guard !isEmpty else { return [] }
        var seen = Set<ContentDigest>()
        var all = [records] + pageInk.map(\.content) + noteInk.map(\.content)
        if let cover { all.append(cover) }
        if let conversion { all.append(conversion) }
        return all.filter { seen.insert($0).inserted }
    }
}

/// A page's ink file.
public struct SyncPageInkReference: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var content: ContentDigest

    public init(pageIndex: Int, content: ContentDigest) {
        self.pageIndex = pageIndex
        self.content = content
    }
}

/// A note's ink file.
public struct SyncNoteInkReference: Codable, Hashable, Sendable {
    public var noteID: UUID
    public var content: ContentDigest

    public init(noteID: UUID, content: ContentDigest) {
        self.noteID = noteID
        self.content = content
    }
}

/// The version rules of `docs/CLOUD_SYNC_PLAN.md` "Versions", as pure functions.
///
/// - A head (or any sync object) in a **format version** above the app's stops sync for the
///   whole account, with "update the app", and changes nothing.
/// - Otherwise the app reads it, ignoring keys it does not know.
/// - It may **push** over a head (write the book back) only when its writer level is at least
///   the head's: an older app would drop what the newer one stored. Below that it pulls but
///   does not push that book, and says the iPad needs updating to send changes.
public enum SyncVersionRules {
    /// What the app may do with one book's head.
    public enum Access: Hashable, Sendable {
        /// Read it and write over it.
        case readAndPush
        /// Read it, but do not write the book back: a newer app (`requiredLevel`) wrote it.
        case readOnly(requiredLevel: Int)
        /// Stop sync for the account: the head is in a format this app cannot read.
        case formatTooNew(formatVersion: Int)
    }

    public static func access(formatVersion: Int, writerLevel: Int, appFormatVersion: Int = SyncFormat.formatVersion,
                              appLevel: Int = SyncFormat.writerLevel) -> Access {
        if stopsSync(formatVersion: formatVersion, appFormatVersion: appFormatVersion) {
            return .formatTooNew(formatVersion: formatVersion)
        }
        return appLevel >= writerLevel ? .readAndPush : .readOnly(requiredLevel: writerLevel)
    }

    /// Whether the app can read a head in this format version.
    public static func mayRead(formatVersion: Int, appFormatVersion: Int = SyncFormat.formatVersion) -> Bool {
        formatVersion <= appFormatVersion
    }

    /// Whether the app may write over a head with this format version and writer level.
    public static func mayPush(formatVersion: Int, writerLevel: Int, appFormatVersion: Int = SyncFormat.formatVersion,
                               appLevel: Int = SyncFormat.writerLevel) -> Bool {
        access(formatVersion: formatVersion, writerLevel: writerLevel, appFormatVersion: appFormatVersion,
               appLevel: appLevel) == .readAndPush
    }

    /// Whether a head in this format version stops sync for the account.
    public static func stopsSync(formatVersion: Int, appFormatVersion: Int = SyncFormat.formatVersion) -> Bool {
        !mayRead(formatVersion: formatVersion, appFormatVersion: appFormatVersion)
    }
}

/// The records blob: a book's `BookArchive` in the backup format's JSON coding
/// (`BackupCoding`), the same coding as a backup's records (`records.json` plus the manifest's
/// book entry), so decoding is as lenient with a newer version's records as a restore is.
public enum SyncRecords {
    /// The archive's JSON. Throws the encoder's error for what JSON cannot hold (a non-finite
    /// number in a highlight's rects, say).
    public static func encode(_ archive: BookArchive) throws -> Data {
        try BackupCoding.makeEncoder().encode(archive)
    }

    /// Decodes a records blob; anything that does not decode, or whose records do not all belong
    /// to its book, throws `SyncError.objectDamaged(key:)`.
    public static func decode(_ data: Data, key: String) throws -> BookArchive {
        guard let archive = try? BackupCoding.makeDecoder().decode(BookArchive.self, from: data), archive.isConsistent else {
            throw SyncError.objectDamaged(key: key)
        }
        return archive
    }
}
