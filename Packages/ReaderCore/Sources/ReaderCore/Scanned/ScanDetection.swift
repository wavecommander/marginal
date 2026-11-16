import Foundation

/// What scan detection learns about one sampled page of a book.
///
/// The caller reads it from the **file**, through a `PDFDocument` of its own, never from the
/// document on screen: PDFKit adds Live Text to pages it has shown, so the on-screen page of a
/// scanned book reports text the file does not have (`docs/SCANNED_BOOKS_FINDINGS.md`, item 1).
public struct ScanPageSample: Hashable, Codable, Sendable {
    /// Zero-based page the sample was taken from.
    public var pageIndex: Int
    /// Characters of text the page has of its own in the file (`PDFPage.numberOfCharacters`).
    public var textCharacterCount: Int
    /// How much of the page images cover, from 0 (none) to 1 (all of it): the area of the
    /// union of the page's image placements within the crop box, divided by the crop box's
    /// area. Values outside `0...1` are clamped when classified.
    public var imageCoverage: Double

    public init(pageIndex: Int, textCharacterCount: Int, imageCoverage: Double) {
        self.pageIndex = pageIndex
        self.textCharacterCount = textCharacterCount
        self.imageCoverage = imageCoverage
    }
}

/// The scan-detection rule: whether a book is a *scanned book* (pages that are pictures of text
/// with no text layer), decided from a few sampled pages at the end of an import.
///
/// **Rule.** Each sample is one of three kinds (`kind(of:)`):
/// - *text*: it has at least `textCharacterThreshold` characters of its own;
/// - *scanned*: next to no text (fewer than `textCharacterThreshold` characters) and an image
///   covering at least `imageCoverageThreshold` of the page;
/// - *blank*: next to no text and little or no image (an empty page, a page drawn with vector
///   art, a small picture). Blank samples do not count either way.
///
/// The book is scanned when at least one sample is scanned and scanned samples make up at least
/// `minimumScannedShare` of the samples that are not blank. So a few blank or picture-only pages
/// in a typed book do not make it scanned, a typed cover (or a few typed pages) on a scan does
/// not stop it being one, and a book whose samples are all blank is not scanned. A scan that
/// already carries an invisible OCR text layer has text of its own and is not scanned: search
/// can already read it.
public enum ScanDetection {
    /// The kind of one sampled page.
    public enum PageKind: Hashable, Sendable {
        /// The page has text of its own.
        case text
        /// Next to no text, and covered by an image.
        case scanned
        /// Next to no text and little or no image; neutral.
        case blank
    }

    /// Default number of pages sampled from a book (`samplePageIndices`). Reading a page's
    /// character count and image placements is cheap, so this adds no noticeable time to an
    /// import, and is enough to see past a typed cover and a few picture pages.
    public static let defaultSampleCount = 12
    /// A page with fewer characters of its own than this has "next to no text" (a stray page
    /// number or a stamp is not a text layer).
    public static let textCharacterThreshold = 50
    /// A page with next to no text whose images cover at least this share of it is scanned.
    public static let imageCoverageThreshold = 0.6
    /// The share of non-blank samples that must be scanned for the book to be scanned.
    public static let minimumScannedShare = 0.7

    /// The pages to sample from a book of `pageCount` pages: every page when there are at most
    /// `maximum`, otherwise `maximum` pages spread evenly from the first page to the last.
    /// Ascending and distinct; empty for an empty book or a non-positive `maximum`.
    public static func samplePageIndices(pageCount: Int, maximum: Int = defaultSampleCount) -> [Int] {
        guard pageCount > 0, maximum > 0 else { return [] }
        guard pageCount > maximum else { return Array(0..<pageCount) }
        guard maximum > 1 else { return [pageCount / 2] }
        let step = Double(pageCount - 1) / Double(maximum - 1)
        return (0..<maximum).map { Int((Double($0) * step).rounded()) }
    }

    /// The kind of one sampled page (see the type's rule).
    public static func kind(of sample: ScanPageSample) -> PageKind {
        if sample.textCharacterCount >= textCharacterThreshold { return .text }
        let coverage = sample.imageCoverage.isFinite ? min(1, max(0, sample.imageCoverage)) : 0
        return coverage >= imageCoverageThreshold ? .scanned : .blank
    }

    /// Whether a book with these samples is scanned (see the type's rule). `false` for no
    /// samples.
    public static func isScanned(_ samples: [ScanPageSample]) -> Bool {
        var scanned = 0, text = 0
        for sample in samples {
            switch kind(of: sample) {
            case .scanned: scanned += 1
            case .text: text += 1
            case .blank: break
            }
        }
        guard scanned > 0 else { return false }
        return Double(scanned) >= minimumScannedShare * Double(scanned + text)
    }
}
