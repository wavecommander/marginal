import CryptoKit
import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import UIKit
@testable import Marginal

/// Helpers for the highlight tests (hosting reuses `PageInkTestSupport.Host`).
@MainActor
enum HighlightsTestSupport {
    static let phrase = "the quick amber fox annotates margins"

    /// An ephemeral store holding a copy of `small.pdf` (12 pages; the phrase is on page 3,
    /// index 2).
    static func makeSmallStore() throws -> (LibraryStore, Book) {
        try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
    }

    /// An ephemeral store with a book and no document.
    static func makeStore() throws -> (LibraryStore, Book) {
        try PageInkTestSupport.makeStore()
    }

    /// A session on `book` hosted in a window, opened at `pageIndex`, once its controller has
    /// seen the visible pages.
    static func host(_ book: Book, _ store: LibraryStore, pageIndex: Int,
                     size: CGSize = CGSize(width: 800, height: 1000)) async throws -> PageInkTestSupport.Host {
        let host = PageInkTestSupport.Host(book: book, store: store, size: size) {
            $0.initialPageIndex = pageIndex
            $0.notebookRebuildDelay = .milliseconds(10)
        }
        let ready = await PageInkTestSupport.waitUntil {
            host.session.loadState == .ready && controller(host).targetPages.contains(pageIndex)
        }
        guard ready else { throw CocoaError(.fileReadUnknown) }
        return host
    }

    static func controller(_ host: PageInkTestSupport.Host) -> HighlightController {
        host.session.highlights!
    }

    /// Selects `text` (its `occurrence`-th match) on a page of the on-screen document through
    /// the PDF view, and returns the bridge's view of the selection.
    static func select(_ text: String, onPage pageIndex: Int, in host: PageInkTestSupport.Host,
                       occurrence: Int = 0) throws -> ReaderTextSelection {
        let page = try require(host.session.pdf.page(at: pageIndex))
        let string = (page.string ?? "") as NSString
        var range = string.range(of: text)
        for _ in 0..<occurrence where range.location != NSNotFound {
            let start = range.location + range.length
            range = string.range(of: text, range: NSRange(location: start, length: string.length - start))
        }
        guard range.location != NSNotFound, let selection = page.selection(for: range) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        host.pdfView.setCurrentSelection(selection, animate: false)
        return try require(host.session.pdf.currentSelection)
    }

    /// Selects from character `from` of page `fromPage` to character `to` of page `toPage`.
    static func select(fromPage: Int, character from: Int, toPage: Int, character to: Int,
                       in host: PageInkTestSupport.Host) throws -> ReaderTextSelection {
        let document = try require(host.pdfView.document)
        let start = try require(document.page(at: fromPage)), end = try require(document.page(at: toPage))
        let selection = try require(document.selection(from: start, atCharacterIndex: from, to: end, atCharacterIndex: to))
        host.pdfView.setCurrentSelection(selection, animate: false)
        return try require(host.session.pdf.currentSelection)
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadUnknown) }
        return value
    }

    /// SHA-256 of a file's bytes.
    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Highlight-subtype annotations of a document's page.
    static func highlightAnnotations(_ page: PDFPage?) -> [PDFAnnotation] {
        (page?.annotations ?? []).filter { $0.type == PDFAnnotationSubtype.highlight.rawValue
            || $0.type == "Highlight" || $0 is HighlightAnnotation }
    }

    /// A snapshot of a view at 2 px per point, sampled in the view's coordinates.
    struct Snapshot {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        let scale: CGFloat = 2

        func pixel(_ point: CGPoint) -> (r: Int, g: Int, b: Int) {
            let x = min(max(Int(point.x * scale), 0), width - 1), y = min(max(Int(point.y * scale), 0), height - 1)
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
    }

    static func snapshot(_ view: UIView) -> Snapshot {
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        UIGraphicsPopContext()
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return Snapshot(pixels: Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)), width: width, height: height)
    }

    /// The yellow page fill over white paper (multiply at 45%): high red and green, low blue.
    static func isTinted(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        p.r > 200 && p.g > 200 && p.b < 190
    }
}
