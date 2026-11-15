import Foundation
import CoreGraphics

// Value types for everything the app stores. All IDs are UUIDs; all page references are
// zero-based page indices (see `PageNumbering`). The SwiftData models in WP2 mirror these
// field-for-field and convert at the repository boundary.

/// One book in the Library: a PDF, either imported as it was or made from another format at import.
public struct Book: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Display title (initially the file name without extension; the reader can rename it).
    public var title: String
    /// Opaque content identity computed by the importer (WP3), e.g. a SHA-256 hex digest of the
    /// file. Two imports with equal fingerprints are the same book (`BookRepository.book(fingerprint:)`).
    /// For a converted book this is the fingerprint of the original file, not of the generated PDF.
    public var fingerprint: String
    /// File name of the PDF inside the book's directory (`BookStorageLayout.documentPath`).
    public var fileName: String
    /// Number of pages; page indices are `0..<pageCount`.
    public var pageCount: Int
    /// Size of the book's files in bytes: the PDF, plus for a converted book the kept original.
    public var fileSize: Int64
    /// When the book was imported.
    public var addedAt: Date
    /// When the book was last opened in the reader, `nil` if never.
    public var lastOpenedAt: Date?
    /// The page to restore when the book is reopened (zero-based).
    public var lastReadPageIndex: Int
    /// The format the book was converted from; `nil` for a book imported as a PDF.
    public var sourceFormat: ImportFormat?
    /// The original file's name as the reader chose it (e.g. `Middlemarch.epub`); `nil` for a PDF.
    /// The kept copy on disk is `BookStorageLayout.originalFileName(extension:)`, not this name.
    public var originalFileName: String?
    /// Version of the converter that made the PDF; `nil` for a PDF. Lets a later release tell
    /// which books an improved converter could redo.
    public var converterVersion: Int?

    public init(id: UUID = UUID(), title: String, fingerprint: String, fileName: String, pageCount: Int,
                fileSize: Int64, addedAt: Date = Date(), lastOpenedAt: Date? = nil, lastReadPageIndex: Int = 0,
                sourceFormat: ImportFormat? = nil, originalFileName: String? = nil, converterVersion: Int? = nil) {
        self.id = id
        self.title = title
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastReadPageIndex = lastReadPageIndex
        self.sourceFormat = sourceFormat
        self.originalFileName = originalFileName
        self.converterVersion = converterVersion
    }

    /// Whether the PDF was made from another format at import.
    public var isConverted: Bool { sourceFormat?.isConverted == true }

    /// Reading progress in `0...1`: `(lastReadPageIndex + 1) / pageCount`, clamped; `0` for a book
    /// with no pages. The last page reads as 1.0 (finished).
    public var progress: Double {
        guard pageCount > 0 else { return 0 }
        let fraction = Double(lastReadPageIndex + 1) / Double(pageCount)
        return min(1, max(0, fraction))
    }
}

/// The colours a highlight can have. A fixed set of four; `rawValue` is the stored form.
public enum HighlightColor: String, CaseIterable, Hashable, Codable, Sendable {
    case yellow, green, blue, pink
}

/// A coloured text range on one PDF page.
public struct Highlight: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var bookID: UUID
    /// Zero-based page the highlight is on.
    public var pageIndex: Int
    /// One rect per selected line, in PDFKit *page space* for `pageIndex`: points, origin at the
    /// lower-left of the page's media box, y up, unrotated (`PDFSelection.bounds(for:)` of each
    /// `selectionsByLine()` element). Stored verbatim; this layer only uses them for ordering.
    public var rects: [CGRect]
    public var color: HighlightColor
    /// The highlighted text (`PDFSelection.string`), for lists, search and export.
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), bookID: UUID, pageIndex: Int, rects: [CGRect], color: HighlightColor,
                text: String, createdAt: Date = Date()) {
        self.id = id
        self.bookID = bookID
        self.pageIndex = pageIndex
        self.rects = rects
        self.color = color
        self.text = text
        self.createdAt = createdAt
    }

    /// Union of `rects` (`.null` when there are none).
    public var bounds: CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }

    /// Reading order on a page, used everywhere highlights are listed: by `pageIndex`; then top
    /// to bottom (larger page-space `bounds.maxY` first; a highlight without rects sorts last on
    /// its page), then left to right (`bounds.minX`), then `createdAt`, then `id.uuidString`.
    public static func readingOrder(_ a: Highlight, _ b: Highlight) -> Bool {
        if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
        let ab = a.bounds, bb = b.bounds
        if ab.isNull != bb.isNull { return !ab.isNull }
        if !ab.isNull {
            if ab.maxY != bb.maxY { return ab.maxY > bb.maxY }
            if ab.minX != bb.minX { return ab.minX < bb.minX }
        }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}

/// A flagged page. At most one per page per book.
public struct Bookmark: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var bookID: UUID
    /// Zero-based page.
    public var pageIndex: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), bookID: UUID, pageIndex: Int, createdAt: Date = Date()) {
        self.id = id
        self.bookID = bookID
        self.pageIndex = pageIndex
        self.createdAt = createdAt
    }
}

/// A heading the reader added ("Add heading at page N"). Merged into the PDF outline by
/// `Outline.init(pdfEntries:userHeadings:pageCount:)`.
public struct UserHeading: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var bookID: UUID
    /// The heading's title (normalised when the outline is built).
    public var title: String
    /// Zero-based page the heading starts on.
    public var pageIndex: Int
    /// The heading this one is nested under, `nil` for top level. May be a PDF heading's anchor
    /// or another user heading's anchor (`HeadingAnchor(userHeadingID:)`). The UI should offer
    /// the nodes of `Outline.headingPath(forPage: pageIndex)` (plus "top level") as choices; the
    /// chosen node's level + 1 is the new heading's level. A parent that no longer resolves makes
    /// the heading top level.
    public var parent: HeadingAnchor?
    /// Creation time; orders user headings that share a parent and a page.
    public var createdAt: Date

    public init(id: UUID = UUID(), bookID: UUID, title: String, pageIndex: Int, parent: HeadingAnchor?,
                createdAt: Date = Date()) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.pageIndex = pageIndex
        self.parent = parent
        self.createdAt = createdAt
    }

    /// The anchor notes on this heading use: `HeadingAnchor(userHeadingID: id)`.
    public var anchor: HeadingAnchor { HeadingAnchor(userHeadingID: id) }
}
