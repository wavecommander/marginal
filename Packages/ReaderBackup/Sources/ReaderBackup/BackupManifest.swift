import Foundation
import ReaderCore

/// The JSON configuration shared by `manifest.json` and every `records.json`.
///
/// Dates use `.deferredToDate` (a `Double` of seconds since 2001), which round-trips every
/// `Date` exactly; ISO 8601 would drop sub-millisecond fractions and change `modifiedAt` values
/// on restore. Keys are sorted so the same content always produces the same bytes.
public enum BackupCoding {
    /// A new encoder with the backup format's settings.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// A new decoder with the backup format's settings.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

/// `manifest.json`: what a backup contains, readable without touching anything else in it, so
/// the restore preview can be built from the manifest alone.
public struct BackupManifest: Hashable, Codable, Sendable {
    /// Always `BackupFormat.name`.
    public var format: String
    /// The format version the backup was written with (`BackupFormat.currentVersion` for new
    /// backups).
    public var formatVersion: Int
    /// When the backup was made.
    public var createdAt: Date
    /// The app's marketing version (`CFBundleShortVersionString`) that made it.
    public var appVersion: String
    /// The app's build number (`CFBundleVersion`) that made it.
    public var appBuild: String
    /// The device's name, shown in the snapshot list.
    public var deviceName: String
    /// Whether the reader asked for PDFs to be embedded. A book whose PDF was absent is still
    /// not embedded; check each book's `pdf.embedded`.
    public var includesPDFs: Bool
    /// One entry per backed-up book.
    public var books: [BookEntry]

    public init(format: String = BackupFormat.name, formatVersion: Int = BackupFormat.currentVersion, createdAt: Date,
                appVersion: String, appBuild: String, deviceName: String, includesPDFs: Bool, books: [BookEntry]) {
        self.format = format
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.deviceName = deviceName
        self.includesPDFs = includesPDFs
        self.books = books
    }

    /// One book in the backup.
    public struct BookEntry: Hashable, Codable, Sendable {
        /// The book record, verbatim (the restore keeps its ID).
        public var book: Book
        /// The PDF the book needs.
        public var pdf: PDFInfo
        /// How many records of each kind the book has (for the restore preview).
        public var counts: RecordCounts
        /// `BookArchive.lastModifiedAt` when the backup was made.
        public var lastModifiedAt: Date
        /// Every file backed up from the book's directory except the PDF, sorted by `path`.
        public var files: [FileInfo]

        public init(book: Book, pdf: PDFInfo, counts: RecordCounts, lastModifiedAt: Date, files: [FileInfo]) {
            self.book = book
            self.pdf = pdf
            self.counts = counts
            self.lastModifiedAt = lastModifiedAt
            self.files = files
        }
    }

    /// The full-content identity of a book's PDF, and whether this archive holds a copy
    /// (at `BackupArchiveLayout.embeddedPDFPath(sha256:)`).
    public struct PDFInfo: Hashable, Codable, Sendable {
        /// Lower-case hex SHA-256 of the whole PDF.
        public var sha256: String
        /// Size in bytes.
        public var size: Int64
        /// `true` when the PDF is inside this archive.
        public var embedded: Bool

        public init(sha256: String, size: Int64, embedded: Bool) {
            self.sha256 = sha256
            self.size = size
            self.embedded = embedded
        }

        /// The hash and size without the `embedded` flag.
        public var digest: ContentDigest { ContentDigest(sha256: sha256, size: size) }
    }

    /// Record counts of one book.
    public struct RecordCounts: Hashable, Codable, Sendable {
        public var notes: Int
        public var highlights: Int
        public var bookmarks: Int
        public var userHeadings: Int
        /// Pages with Pencil ink (`ink/<page>.drawing` files).
        public var inkedPages: Int

        public init(notes: Int = 0, highlights: Int = 0, bookmarks: Int = 0, userHeadings: Int = 0, inkedPages: Int = 0) {
            self.notes = notes
            self.highlights = highlights
            self.bookmarks = bookmarks
            self.userHeadings = userHeadings
            self.inkedPages = inkedPages
        }
    }

    /// One file from a book's directory.
    public struct FileInfo: Hashable, Codable, Sendable {
        /// Path relative to the book's directory, `/`-separated (`ink/12.drawing`, `cover.jpg`).
        public var path: String
        /// Size in bytes.
        public var size: Int64
        /// Lower-case hex SHA-256.
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }

        /// The hash and size.
        public var digest: ContentDigest { ContentDigest(sha256: sha256, size: size) }
    }

    /// The entry for `bookID`, or `nil`.
    public func entry(for bookID: UUID) -> BookEntry? {
        books.first { $0.book.id == bookID }
    }

    // MARK: - Encoding and validation

    /// The manifest as `manifest.json` bytes.
    public func encoded() throws -> Data {
        try BackupCoding.makeEncoder().encode(self)
    }

    /// Decodes and validates `manifest.json`. The format name and version are checked first, on
    /// their own, so a backup from a newer app (whose manifest may not decode as this version's
    /// shape) is reported as `newerFormatVersion`, not as damage.
    public static func decode(_ data: Data) throws -> BackupManifest {
        struct Header: Decodable {
            var format: String?
            var formatVersion: Int?
        }
        let decoder = BackupCoding.makeDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw BackupError.notABackup }
        guard header.format == BackupFormat.name, let version = header.formatVersion else { throw BackupError.notABackup }
        guard version <= BackupFormat.currentVersion else { throw BackupError.newerFormatVersion(version) }
        let manifest: BackupManifest
        do {
            manifest = try decoder.decode(BackupManifest.self, from: data)
        } catch {
            throw BackupError.manifestInvalid(detail: String(describing: error))
        }
        try manifest.validate()
        return manifest
    }

    /// Checks the rules every manifest keeps: the format name; a version this build reads
    /// (`newerFormatVersion` when it is higher); unique book IDs; well-formed hashes and sizes;
    /// file paths that are plain relative paths, unique within the book, and never, at the top
    /// level, `records.json` (reserved by the format), the book's PDF file name or
    /// `document.sha256` (so extracting a crafted backup can never plant an unverified PDF or
    /// hash sidecar in the book's directory).
    /// Whether `name` can be a book's PDF file name: one path component, not empty, not hidden,
    /// not `.` or `..`, free of separators and control characters, and not one of the names the
    /// book directory reserves (`document.sha256`, `records.json`).
    public static func isSafeDocumentFileName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 255 else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        return name != BookStorageLayout.contentHashFileName && name != BackupArchiveLayout.recordsFileName
    }

    public func validate() throws {
        guard format == BackupFormat.name else { throw BackupError.notABackup }
        guard formatVersion <= BackupFormat.currentVersion else { throw BackupError.newerFormatVersion(formatVersion) }
        guard formatVersion >= 1 else { throw BackupError.manifestInvalid(detail: "formatVersion \(formatVersion)") }
        var ids = Set<UUID>()
        for entry in books {
            let id = entry.book.id
            guard ids.insert(id).inserted else { throw BackupError.manifestInvalid(detail: "book \(id) listed twice") }
            guard ContentHash.isValidSHA256(entry.pdf.sha256), entry.pdf.size >= 0 else {
                throw BackupError.manifestInvalid(detail: "bad PDF hash for \(id)")
            }
            // A restore writes the PDF to `Books/<id>/<fileName>`, so the name must stay inside
            // the book's directory and must not land on the hash sidecar.
            guard Self.isSafeDocumentFileName(entry.book.fileName) else {
                throw BackupError.manifestInvalid(detail: "unsafe PDF file name in \(id)")
            }
            var paths = Set<String>()
            for file in entry.files {
                do {
                    try ZipEntryName.validate(file.path, allowDirectory: false)
                } catch {
                    throw BackupError.manifestInvalid(detail: "unsafe path \(file.path) in \(id)")
                }
                let reserved = [BackupArchiveLayout.recordsFileName, entry.book.fileName, BookStorageLayout.contentHashFileName]
                guard !reserved.contains(file.path), paths.insert(file.path).inserted,
                      ContentHash.isValidSHA256(file.sha256), file.size >= 0 else {
                    throw BackupError.manifestInvalid(detail: "bad file \(file.path) in \(id)")
                }
            }
        }
    }
}

/// `books/<bookID>/records.json`: a book's records except the `Book` itself, which lives in the
/// manifest so the preview needs only the manifest.
struct BookRecordsFile: Codable, Hashable {
    var notes: [Note]
    var highlights: [Highlight]
    var bookmarks: [Bookmark]
    var userHeadings: [UserHeading]

    init(_ archive: BookArchive) {
        notes = archive.notes
        highlights = archive.highlights
        bookmarks = archive.bookmarks
        userHeadings = archive.userHeadings
    }

    func archive(for book: Book) -> BookArchive {
        BookArchive(book: book, notes: notes, highlights: highlights, bookmarks: bookmarks, userHeadings: userHeadings)
    }
}
