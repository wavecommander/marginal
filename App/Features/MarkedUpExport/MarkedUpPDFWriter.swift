import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit

/// The export file of a marked-up book: a new PDF written page by page into a Core Graphics PDF
/// context that streams to disk, from a **private** `PDFDocument` of the book (never the
/// on-screen one). The imported PDF is only read.
///
/// **A book page** (`beginBookPage`) is the page as the reader sees it upright: its crop box with
/// its own rotation applied (`PageInkGeometry`'s ink space), on white. Its content is the page's
/// own content stream drawn with `CGContext.drawPDFPage` (`BookPageDrawing`), so text stays text
/// (searchable and selectable where the source's is) and vector stays vector; nothing is
/// rasterised. Over it, in the order the reader draws them: the PDF's own annotations as PDFKit
/// shows them (except links, which are re-made as links, and pop-ups), then the reader's
/// highlights (each line rect in `HighlightPalette.pageFill`, multiply blend, exactly as
/// `HighlightAnnotation` draws them, scanned-page highlights included), and the page ink, which
/// the caller draws on the main actor with `PageInkRenderer` (vector paths where the ink allows,
/// an image per textured stroke) while the context is left in ink space.
///
/// **Links.** Every book page gets the named destination `destinationName(pageIndex)` at its top.
/// The PDF's own link annotations are re-made: a web link stays a web link, a link to a page of
/// the book goes to the top of that page (the point on the page is not kept). The notes
/// appendix links its page labels to the same destinations.
///
/// **Memory.** One page at a time, each in an autorelease pool; the context writes to the file as
/// pages end. The private document is opened again every `reopenInterval` pages, and before the
/// next page after a memory warning (`reopenBeforeNextPage()`), so PDFKit's page and resource
/// caches cannot grow with the book. Not more often: Core Graphics writes a font or image the
/// pages share once per opening of the document, so each reopening costs file size (measured on
/// the 1,500-page fixture: every 32 pages, 8.1 MB; never, 6.6 MB, with 20 MB more memory at the
/// end; the source is 5.0 MB).
///
/// **Threads.** Not thread-safe; one export task uses it at a time. The page copying runs off the
/// main thread (`@concurrent`), the ink and the appendix on the main actor, never at once.
nonisolated final class MarkedUpPDFFile: @unchecked Sendable {
    /// Book pages between reopenings of the private document.
    static let reopenInterval = 200

    enum Failure: Error {
        case unreadable
        case locked
        case cannotWrite
    }

    /// The export's PDF context (y up, default user space). Ink and the appendix draw into it.
    let context: CGContext
    /// The book's page count (from the file).
    let pageCount: Int
    private let source: URL
    private var document: PDFDocument?
    private var pagesSinceOpen = 0
    private var isPageOpen = false
    private var isClosed = false

    /// Opens the book (off the main thread) and creates the export file.
    /// - Parameters:
    ///   - defaultPageSize: the media box of pages that do not give their own (the appendix).
    @concurrent
    static func create(source: URL, destination: URL, title: String, defaultPageSize: CGSize) async throws -> MarkedUpPDFFile {
        try MarkedUpPDFFile(source: source, destination: destination, title: title, defaultPageSize: defaultPageSize)
    }

    private init(source: URL, destination: URL, title: String, defaultPageSize: CGSize) throws {
        guard let document = PDFDocument(url: source) else { throw Failure.unreadable }
        guard !document.isLocked else { throw Failure.locked }
        self.source = source
        self.document = document
        pageCount = document.pageCount
        var box = CGRect(origin: .zero, size: defaultPageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Tactile Texts"]
        guard let context = CGContext(destination as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw Failure.cannotWrite
        }
        self.context = context
    }

    /// The named destination at the top of book page `pageIndex`.
    static func destinationName(_ pageIndex: Int) -> String { "page-\(pageIndex + 1)" }

    /// Begins export page `pageIndex + 1` with book page `pageIndex` drawn on it, its own
    /// annotations, links and `highlights`. The context is left in the page's ink space (origin
    /// top-left, y down, the size of `PageInkGeometry.bounds`) with its state saved for the
    /// page's ink; end the page with `endPage()`. Returns the page's geometry (`nil`: the page
    /// could not be read; an empty page of the default size stands in, so pages keep their numbers).
    @concurrent
    func beginBookPage(_ pageIndex: Int, highlights: [Highlight]) async -> PageInkGeometry? {
        autoreleasepool { drawBookPage(pageIndex, highlights: highlights) }
    }

    /// Opens the private document again before the next page (a memory warning). Call between
    /// pages only.
    func reopenBeforeNextPage() {
        pagesSinceOpen = Self.reopenInterval
    }

    /// Restores the state `beginBookPage` saved and ends the page.
    func endPage() {
        guard isPageOpen else { return }
        context.restoreGState()
        context.endPDFPage()
        isPageOpen = false
    }

    /// Sets the outline (if any items), ends any open page and closes the file (idempotent).
    func close(outline: [ExportOutlineItem] = []) {
        guard !isClosed else { return }
        endPage()
        if !outline.isEmpty { CGPDFContextSetOutline(context, Self.outlineDictionary(outline)) }
        context.closePDF()
        isClosed = true
        document = nil
    }

    /// The outline in `CGPDFContextSetOutline`'s form: a root holding only children; each
    /// entry a title and a one-based page number, with its own children.
    static func outlineDictionary(_ items: [ExportOutlineItem]) -> CFDictionary {
        func entry(_ item: ExportOutlineItem) -> NSDictionary {
            let dictionary = NSMutableDictionary()
            dictionary[kCGPDFOutlineTitle as String] = item.title
            dictionary[kCGPDFOutlineDestination as String] = NSNumber(value: item.pageNumber)
            if !item.children.isEmpty { dictionary[kCGPDFOutlineChildren as String] = item.children.map(entry) as NSArray }
            return dictionary
        }
        return [kCGPDFOutlineChildren as String: items.map(entry) as NSArray] as NSDictionary
    }

    // MARK: Drawing a book page

    private func drawBookPage(_ pageIndex: Int, highlights: [Highlight]) -> PageInkGeometry? {
        if document == nil || pagesSinceOpen >= Self.reopenInterval {
            document = PDFDocument(url: source)
            pagesSinceOpen = 0
        }
        pagesSinceOpen += 1
        guard let page = document?.page(at: pageIndex) else {
            context.beginPDFPage(nil)
            context.saveGState()
            isPageOpen = true
            return nil
        }
        let geometry = PageInkGeometry(page: page)
        let size = geometry.size
        var box = CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        isPageOpen = true
        context.addDestination(Self.destinationName(pageIndex) as CFString,
                               at: CGPoint(x: 0, y: box.height))
        // Ink space ← default space: origin at the top-left of the visible page, y down.
        let inkToDefault = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box.height)
        context.saveGState()
        context.concatenate(inkToDefault)
        let bounds = geometry.bounds
        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)
        BookPageDrawing.draw(page, geometry: geometry, in: context, target: bounds)

        var links: [PDFAnnotation] = []
        context.saveGState()
        context.clip(to: bounds)
        context.concatenate(geometry.pageToInk)
        for annotation in page.annotations {
            // `type` is the subtype without its slash ("Link"; `PDFAnnotationSubtype.link` is "/Link").
            switch annotation.type {
            case "Link":
                links.append(annotation)
            case "Popup":
                break
            default:
                if annotation.shouldDisplay { annotation.draw(with: .cropBox, in: context) }
            }
        }
        context.setBlendMode(.multiply)
        for highlight in highlights {
            context.setFillColor(HighlightPalette.pageFill(highlight.color).cgColor)
            for rect in highlight.rects where !rect.isNull && !rect.isEmpty {
                context.fill(rect)
            }
        }
        context.restoreGState()

        let pageToDefault = geometry.pageToInk.concatenating(inkToDefault)
        for link in links {
            let rect = link.bounds.applying(pageToDefault).standardized
            guard rect.width > 0, rect.height > 0 else { continue }
            if let url = link.url ?? (link.action as? PDFActionURL)?.url {
                context.setURL(url as CFURL, for: rect)
            } else if let target = (link.destination ?? (link.action as? PDFActionGoTo)?.destination)?.page,
                      let document, case let index = document.index(for: target), index != NSNotFound,
                      PageNumbering.isValid(index, pageCount: pageCount) {
                context.setDestination(Self.destinationName(index) as CFString, for: rect)
            }
        }
        return geometry
    }
}
