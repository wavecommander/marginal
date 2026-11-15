import Foundation
import ReaderCore

/// What the restore preview needs to know about one book already in the Library.
public struct LocalBookSummary: Hashable, Sendable {
    /// The local book record.
    public var book: Book
    /// `true` when the book's PDF file is on disk.
    public var hasPDF: Bool
    /// The PDF's full-content SHA-256 (from the `document.sha256` sidecar), `nil` when not yet
    /// computed.
    public var sha256: String?
    /// The local book's record counts (same shape as the manifest's).
    public var counts: BackupManifest.RecordCounts
    /// `BookArchive.lastModifiedAt` of the local book.
    public var lastModifiedAt: Date

    public init(book: Book, hasPDF: Bool, sha256: String?, counts: BackupManifest.RecordCounts, lastModifiedAt: Date) {
        self.book = book
        self.hasPDF = hasPDF
        self.sha256 = sha256
        self.counts = counts
        self.lastModifiedAt = lastModifiedAt
    }
}

/// The restore preview: for each book in a backup, whether it is already in the Library, whether
/// it is ticked by default, and where its PDF would come from. A pure function of the manifest,
/// the local Library and the PDFs the destination holds, so it is built before anything is
/// downloaded or extracted.
public struct RestorePlan: Hashable, Sendable {
    /// Whether a backed-up book is already in the Library.
    public enum Status: Hashable, Sendable {
        /// No local book has the same ID or fingerprint.
        case new
        /// At least one local book has the same ID or the same fingerprint; restoring replaces
        /// all of them (`Item.replacedBookIDs`).
        case inLibrary
    }

    /// Where a restored book's PDF comes from, in priority order. Whatever the source, the
    /// restore verifies the bytes against the manifest's SHA-256 before linking them.
    public enum PDFSource: Hashable, Sendable {
        /// Embedded in the archive (`BackupArchiveReader.extractPDF`).
        case embedded
        /// At the destination's `PDFs/<sha256>.pdf` (`BackupDestination.downloadPDF`).
        case destination
        /// Copied from this local book's PDF: one whose full SHA-256 is the backup's, or, when
        /// its SHA-256 is not known yet, whose fingerprint is the backup book's (the hash is then
        /// computed and checked during the restore).
        case localBook(UUID)
        /// Nowhere: the book is restored as "PDF missing".
        case missing
    }

    /// One backed-up book.
    public struct Item: Hashable, Sendable, Identifiable {
        /// The manifest's entry.
        public var entry: BackupManifest.BookEntry
        public var status: Status
        /// The local books with the same ID or the same fingerprint, in Library order (the
        /// preview shows their counts and dates beside the backup's).
        public var localMatches: [LocalBookSummary]
        /// Whether the book is ticked when the preview opens: every book is (owner decision,
        /// 15 November 2026: a book already in the Library is ticked and set to Merge, which
        /// keeps everything on this iPad; the reader can switch it to Replace or Leave as is).
        public var isSelectedByDefault: Bool
        /// What restoring this book does unless the reader picks otherwise: `.restore` for a new
        /// book, `.merge` for a book already in the Library (owner decision, 15 November 2026:
        /// a merge keeps everything on this iPad and adds what the backup has).
        public var defaultAction: RestoreAction
        public var pdfSource: PDFSource

        /// The backed-up book's ID.
        public var id: UUID { entry.book.id }
        /// IDs of the local books a restore of this item replaces.
        public var replacedBookIDs: [UUID] { localMatches.map(\.book.id) }
    }

    /// One item per manifest book, in manifest order.
    public var items: [Item]

    /// Builds the plan. `destinationPDFHashes` are the PDF hashes the destination holds (empty
    /// for a single-file backup); hashes are compared case-insensitively.
    public init(manifest: BackupManifest, localLibrary: [LocalBookSummary], destinationPDFHashes: Set<String>) {
        let destination = Set(destinationPDFHashes.map { $0.lowercased() })
        items = manifest.books.map { entry in
            let book = entry.book
            let matches = localLibrary.filter { $0.book.id == book.id || $0.book.fingerprint == book.fingerprint }
            let status: Status = matches.isEmpty ? .new : .inLibrary
            let hash = entry.pdf.sha256.lowercased()

            let source: PDFSource
            if entry.pdf.embedded {
                source = .embedded
            } else if destination.contains(hash) {
                source = .destination
            } else if let local = localLibrary.first(where: { $0.hasPDF && $0.sha256?.lowercased() == hash }) {
                source = .localBook(local.book.id)
            } else if let local = localLibrary.first(where: { $0.hasPDF && $0.sha256 == nil && $0.book.fingerprint == book.fingerprint }) {
                source = .localBook(local.book.id)
            } else {
                source = .missing
            }
            return Item(entry: entry, status: status, localMatches: matches, isSelectedByDefault: true,
                        defaultAction: status == .new ? .restore : .merge, pdfSource: source)
        }
    }
}

/// Which snapshots to delete to keep a destination's history bounded.
public enum SnapshotRetention {
    /// Snapshots kept by default.
    public static let defaultKeepCount = 10

    /// The snapshots beyond the newest `keepCount` (`BackupSnapshotInfo.newestFirst`), oldest
    /// last. `keepCount` is at least 1, so the newest snapshot is never returned.
    public static func snapshotsToDelete(_ snapshots: [BackupSnapshotInfo], keeping keepCount: Int = defaultKeepCount) -> [BackupSnapshotInfo] {
        Array(snapshots.sorted(by: BackupSnapshotInfo.newestFirst).dropFirst(max(1, keepCount)))
    }
}
