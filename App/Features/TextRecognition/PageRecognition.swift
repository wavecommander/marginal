import CoreGraphics
import Foundation
import os
import PDFKit
import ReaderCore
import Vision

// Rendering a page of a scanned book and reading its words (S2). Everything here is
// `nonisolated` and synchronous: it runs on the recognition worker's own serial queue
// (`TextRecognitionWorker`), on pages of a **private** `PDFDocument`, never the on-screen one.

let textRecognitionLog = Logger(subsystem: "software.tactile.texts", category: "TextRecognition")

/// "Does this page have text of its own?", asked the same way by the recognition queue (which
/// skips such pages) and by the search worker (which then reads the file's text, not the
/// recognised text). Always asked of a page of a private `PDFDocument` opened from the file:
/// PDFKit adds Live Text to pages of the on-screen document (`docs/SCANNED_BOOKS_FINDINGS.md`).
///
/// The rule is the one S4 uses for a highlight's text source: a page has text of its own when its
/// text in the file has at least one non-whitespace character (`numberOfCharacters == 0` or a
/// whitespace-only `string` means none), so search, recognition and highlights agree.
nonisolated enum PageTextPolicy {
    /// Whether a page whose file text is `string` has text of its own.
    static func hasOwnText(_ string: String?) -> Bool {
        guard let string, !string.isEmpty else { return false }
        return string.unicodeScalars.contains { !$0.properties.isWhitespace }
    }

    /// The same for a page of a private document (cheap when the page has no characters).
    static func hasOwnText(_ page: PDFPage) -> Bool {
        page.numberOfCharacters > 0 && hasOwnText(page.string)
    }
}

/// One word as a recogniser reports it: its text and its box in *normalised image space*
/// (0...1, origin at the image's lower-left, as Vision reports).
nonisolated struct NormalisedWord: Hashable, Sendable {
    var text: String
    var box: CGRect
}

/// Reads the words of a page image: lines in reading order, each its words in order.
nonisolated protocol PageRecognizing: Sendable {
    func recognise(_ image: CGImage) throws -> [[NormalisedWord]]
}

/// `VNRecognizeTextRequest`, accurate level, revision 3, with language correction: the request
/// the findings chose for the iPadOS 17 floor (question 7). No newer-API path: the iOS 18
/// `RecognizeTextRequest` is the same engine, and the iOS 26 document request adds nothing
/// search needs.
nonisolated struct VisionPageRecognizer: PageRecognizing {
    init() {}

    func recognise(_ image: CGImage) throws -> [[NormalisedWord]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        var lines: [[NormalisedWord]] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            var words: [NormalisedWord] = []
            for range in Self.wordRanges(in: string) {
                // Accurate word boxes are full line height (findings, question 8). A word Vision
                // cannot box gets its line's box rather than being lost.
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                words.append(NormalisedWord(text: String(string[range]), box: box))
            }
            if !words.isEmpty { lines.append(words) }
        }
        return lines
    }

    /// Maximal runs of non-whitespace, the words of `RecognisedPage`.
    static func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            let isSpace = string[index].unicodeScalars.allSatisfy { $0.properties.isWhitespace }
            if isSpace {
                if let s = start { ranges.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = next
        }
        if let s = start { ranges.append(s..<string.endIndex) }
        return ranges
    }
}

/// Renders a page's crop box, unrotated, to a greyscale bitmap, and maps boxes in that bitmap
/// back to PDFKit page space (findings, question 8).
nonisolated enum PageImageRenderer {
    /// About 200 dpi: the findings' starting point (accurate recognition reads 11 pt print
    /// exactly at 150 to 300 dpi; 200 keeps the buffer at about 3.7 MB for a Letter page).
    static let defaultDPI: CGFloat = 200
    /// No bitmap is larger than this many pixels (a poster-sized page is rendered at a lower
    /// resolution instead), which bounds the memory of one page.
    static let maximumPixels = 6_000_000

    /// A rendered page: the bitmap and the page-space box it shows.
    struct Rendered {
        var image: CGImage
        /// The page-space rect the bitmap covers (the crop box, unrotated).
        var box: CGRect
    }

    /// Renders `page` (of a private document: its rotation is reset to 0, so the bitmap and the
    /// boxes stay in unrotated page space, the space highlights and search rects use).
    static func render(_ page: PDFPage, dpi: CGFloat = defaultDPI) -> Rendered? {
        if page.rotation != 0 { page.rotation = 0 }
        let box = page.bounds(for: .cropBox).standardized
        guard box.width > 1, box.height > 1, box.width.isFinite, box.height.isFinite else { return nil }
        var scale = dpi / 72
        let pixels = box.width * scale * box.height * scale
        if pixels > CGFloat(maximumPixels) { scale *= (CGFloat(maximumPixels) / pixels).squareRoot() }
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        // `draw(with: .cropBox, to:)` already puts the crop box's lower-left corner at the
        // context's origin (measured: `TextRecognitionGeometryTests`). The findings' extra
        // `translateBy(-box.minX, -box.minY)` was verified only on a crop box at the origin, and
        // shifts every box on a page whose crop box is not.
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, box: box)
    }

    /// A normalised image rect (origin lower-left, as Vision reports) in page space. No y flip:
    /// the bitmap's origin is the crop box's lower-left corner.
    static func pageRect(fromNormalised n: CGRect, box: CGRect) -> CGRect {
        CGRect(x: box.minX + n.minX * box.width, y: box.minY + n.minY * box.height,
               width: n.width * box.width, height: n.height * box.height)
    }

    /// A recogniser's lines as a `RecognisedPage` in page space.
    static func recognisedPage(pageIndex: Int, lines: [[NormalisedWord]], box: CGRect) -> RecognisedPage {
        RecognisedPage(pageIndex: pageIndex, lines: lines.map { line in
            line.map { RecognisedPage.Token(text: $0.text, bounds: pageRect(fromNormalised: $0.box, box: box)) }
        })
    }
}
