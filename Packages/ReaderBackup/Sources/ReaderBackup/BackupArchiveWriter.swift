import Foundation
import ReaderCore

/// Who made a backup, recorded in its manifest.
public struct BackupMetadata: Hashable, Sendable {
    /// When the backup was made; also every archive entry's timestamp.
    public var createdAt: Date
    /// `CFBundleShortVersionString` of the app.
    public var appVersion: String
    /// `CFBundleVersion` of the app.
    public var appBuild: String
    /// The device's name.
    public var deviceName: String

    public init(createdAt: Date = Date(), appVersion: String, appBuild: String, deviceName: String) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.deviceName = deviceName
    }
}

/// One book to back up: its records as values and where its files are.
public struct BackupBookSource: Sendable {
    /// Where the PDF's full-content hash comes from.
    public enum PDFDigest: Hashable, Sendable {
        /// The caller knows it (normally from the `document.sha256` sidecar). Required when the
        /// PDF file is absent. When the PDF is embedded, the copied bytes are checked against it.
        case known(ContentDigest)
        /// Hash the PDF file here (an extra read of the file). The file must exist.
        case compute
    }

    /// The book and its records (must be `isConsistent`).
    public var archive: BookArchive
    /// The book's directory on disk (`<root>/Books/<bookID>`). It need not exist (a book with
    /// no files yet).
    public var directory: URL
    /// The PDF's file name inside `directory`; normally `archive.book.fileName`.
    public var pdfFileName: String
    /// The PDF's hash.
    public var pdfDigest: PDFDigest

    public init(archive: BookArchive, directory: URL, pdfFileName: String? = nil, pdfDigest: PDFDigest) {
        self.archive = archive
        self.directory = directory
        self.pdfFileName = pdfFileName ?? archive.book.fileName
        self.pdfDigest = pdfDigest
    }
}

/// Writes a `.ttbackup` snapshot archive (see `BackupArchiveLayout`).
///
/// For each book it stores `records.json` and every regular file under the book's directory,
/// recursively, except the PDF itself, the `document.sha256` sidecar (restore rewrites it from
/// the manifest), a converted book's kept original (`BookStorageLayout.isOriginalFileName`: the
/// reader's own file, which can be as large as the PDF and would be repeated in every snapshot;
/// the generated PDF is the book), and hidden or temporary files (names starting with `.`, or
/// ending in `~`, `.tmp`, `.temp` or `.partial`), which are leftovers of atomic writes in
/// progress. Each file's
/// SHA-256 and size are computed in the same pass that archives it. With `includePDFs`, each
/// present PDF is embedded once per distinct hash at `pdfs/<sha256>.pdf`; a book whose PDF file
/// is absent is still backed up, not embedded, with the hash the caller supplied.
///
/// The manifest is written last (the reader finds it through the central directory), so it can
/// record digests computed while archiving. Progress is the fraction of all bytes to be read
/// across all books. On any error or cancellation no file is left at the destination.
public enum BackupArchiveWriter {
    /// Writes the archive for `books` to `url` (replacing any file there) and returns its
    /// manifest. Blocking: call it off the main actor.
    @discardableResult
    public static func write(books: [BackupBookSource], metadata: BackupMetadata, includePDFs: Bool, to url: URL,
                             progress: BackupProgress? = nil) throws -> BackupManifest {
        try write(books: books, metadata: metadata, includePDFs: includePDFs, to: url, forceZIP64: false, progress: progress)
    }

    @discardableResult
    static func write(books: [BackupBookSource], metadata: BackupMetadata, includePDFs: Bool, to url: URL,
                      forceZIP64: Bool, progress: BackupProgress?) throws -> BackupManifest {
        // Plan everything (and fail on bad input) before creating the output file.
        var plans: [BookPlan] = []
        var ids = Set<UUID>()
        for source in books {
            let book = source.archive.book
            guard ids.insert(book.id).inserted else { throw BackupError.duplicateBook(bookTitle: book.title) }
            guard source.archive.isConsistent else { throw BackupError.inconsistentBook(bookTitle: book.title) }
            plans.append(try BookPlan(source))
        }
        var totalBytes: Int64 = 0
        var embedded = Set<String>()
        for plan in plans {
            totalBytes += plan.files.reduce(0) { $0 + $1.size }
            if plan.needsHashPass { totalBytes += plan.pdfFileSize ?? 0 }
            if includePDFs, plan.pdfFileSize != nil { totalBytes += plan.pdfFileSize ?? 0 }
        }

        let tracker = ProgressTracker(total: totalBytes, report: progress)
        let writer = try ZipArchiveWriter(url: url, modificationDate: metadata.createdAt)
        writer.forceZIP64 = forceZIP64
        do {
            tracker.report()
            var entries: [BackupManifest.BookEntry] = []
            let encoder = BackupCoding.makeEncoder()
            for plan in plans {
                let source = plan.source
                let bookID = source.archive.book.id

                // The PDF's identity: supplied, or hashed now.
                var pdfDigest: ContentDigest
                switch source.pdfDigest {
                case .known(let digest):
                    pdfDigest = ContentDigest(sha256: digest.sha256.lowercased(), size: digest.size)
                    guard ContentHash.isValidSHA256(pdfDigest.sha256) else {
                        throw BackupError.pdfHashUnavailable(bookTitle: source.archive.book.title)
                    }
                case .compute:
                    guard plan.pdfFileSize != nil else { throw BackupError.pdfHashUnavailable(bookTitle: source.archive.book.title) }
                    let base = tracker.done
                    pdfDigest = try ContentHash.digest(ofFileAt: plan.pdfURL, onBytes: { done, _ in tracker.set(base + done) })
                }

                var isEmbedded = false
                if includePDFs, let size = plan.pdfFileSize {
                    if embedded.contains(pdfDigest.sha256) {
                        tracker.add(size)
                    } else {
                        let base = tracker.done
                        let (copied, _) = try writer.addEntry(
                            named: BackupArchiveLayout.embeddedPDFPath(sha256: pdfDigest.sha256),
                            contentsOf: plan.pdfURL, onBytes: { written, _ in tracker.set(base + written) })
                        guard copied == pdfDigest else { throw BackupError.contentMismatch(name: source.pdfFileName) }
                        embedded.insert(pdfDigest.sha256)
                    }
                    isEmbedded = true
                }

                try writer.addEntry(named: BackupArchiveLayout.recordsPath(bookID: bookID),
                                    data: try encoder.encode(BookRecordsFile(source.archive)))

                var files: [BackupManifest.FileInfo] = []
                for file in plan.files {
                    let base = tracker.done
                    let (digest, _) = try writer.addEntry(
                        named: BackupArchiveLayout.bookFilePath(bookID: bookID, relativePath: file.path),
                        contentsOf: file.url, onBytes: { written, _ in tracker.set(base + written) })
                    files.append(BackupManifest.FileInfo(path: file.path, size: digest.size, sha256: digest.sha256))
                }

                let archive = source.archive
                let inkedPages = plan.files.filter { file in
                    let parts = file.path.split(separator: "/")
                    return parts.count == 2 && parts[0] == "ink"
                        && BookStorageLayout.pageIndex(fromPageInkFileName: String(parts[1])) != nil
                }.count
                entries.append(BackupManifest.BookEntry(
                    book: archive.book,
                    pdf: BackupManifest.PDFInfo(sha256: pdfDigest.sha256, size: pdfDigest.size, embedded: isEmbedded),
                    counts: BackupManifest.RecordCounts(notes: archive.notes.count, highlights: archive.highlights.count,
                                                        bookmarks: archive.bookmarks.count,
                                                        userHeadings: archive.userHeadings.count, inkedPages: inkedPages),
                    lastModifiedAt: archive.lastModifiedAt,
                    files: files))
            }

            let manifest = BackupManifest(createdAt: metadata.createdAt, appVersion: metadata.appVersion,
                                          appBuild: metadata.appBuild, deviceName: metadata.deviceName,
                                          includesPDFs: includePDFs, books: entries)
            try manifest.validate()
            try writer.addEntry(named: BackupArchiveLayout.manifestPath, data: try manifest.encoded())
            try writer.finish()
            progress?(1)
            return manifest
        } catch {
            writer.abandon()
            throw error
        }
    }

    // MARK: - Planning

    private struct PlannedFile {
        let path: String
        let url: URL
        let size: Int64
    }

    private struct BookPlan {
        let source: BackupBookSource
        let pdfURL: URL
        /// Size of the PDF on disk, `nil` when absent.
        let pdfFileSize: Int64?
        let files: [PlannedFile]

        var needsHashPass: Bool { source.pdfDigest == .compute }

        init(_ source: BackupBookSource) throws {
            self.source = source
            pdfURL = source.directory.appendingPathComponent(source.pdfFileName, isDirectory: false)
            pdfFileSize = FileOps.regularFileSize(pdfURL)
            var files: [PlannedFile] = []
            try Self.collect(source.directory, prefix: "", excludingTopLevel: [source.pdfFileName, BookStorageLayout.contentHashFileName],
                             excludingOriginal: source.archive.book.isConverted, into: &files)
            self.files = files.sorted { $0.path < $1.path }
            if let reserved = self.files.first(where: { $0.path == BackupArchiveLayout.recordsFileName }) {
                throw BackupError.unsafeEntryName(name: reserved.path)
            }
        }

        /// Regular files under `directory`, recursively, as `/`-separated relative paths.
        /// Symbolic links are not followed.
        private static func collect(_ directory: URL, prefix: String, excludingTopLevel excluded: Set<String>,
                                    excludingOriginal: Bool, into files: inout [PlannedFile]) throws {
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            let children = try mappingFileErrors(directory) {
                try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            }
            for child in children {
                let name = child.lastPathComponent
                if isTemporaryOrHidden(name) { continue }
                if prefix.isEmpty, excluded.contains(name) { continue }
                if prefix.isEmpty, excludingOriginal, BookStorageLayout.isOriginalFileName(name) { continue }
                let values = try mappingFileErrors(child) { try child.resourceValues(forKeys: Set(keys)) }
                if values.isSymbolicLink == true { continue }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if values.isDirectory == true {
                    try collect(child, prefix: path, excludingTopLevel: excluded, excludingOriginal: excludingOriginal, into: &files)
                } else if values.isRegularFile == true {
                    try ZipEntryName.validate(path, allowDirectory: false)
                    files.append(PlannedFile(path: path, url: child, size: Int64(values.fileSize ?? 0)))
                }
            }
        }
    }

    /// Names skipped when collecting a book's files.
    static func isTemporaryOrHidden(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasSuffix("~") { return true }
        let lower = name.lowercased()
        return lower.hasSuffix(".tmp") || lower.hasSuffix(".temp") || lower.hasSuffix(".partial")
    }
}

/// Byte-weighted progress across a whole operation; reports monotonically increasing fractions.
final class ProgressTracker {
    private let total: Int64
    private let callback: BackupProgress?
    private(set) var done: Int64 = 0
    private var lastReported = -1.0

    init(total: Int64, report: BackupProgress?) {
        self.total = total
        self.callback = report
    }

    func set(_ value: Int64) {
        done = max(done, value)
        report()
    }

    func add(_ bytes: Int64) { set(done + bytes) }

    func report() {
        guard let callback else { return }
        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
        // Skip tiny steps so a callback that hops to the main actor is not flooded.
        if fraction - lastReported >= 0.001 || (fraction == 1 && lastReported < 1) || lastReported < 0 {
            lastReported = fraction
            callback(fraction)
        }
    }
}
