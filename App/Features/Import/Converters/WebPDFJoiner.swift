import CoreGraphics
import Foundation

// Joins printed parts (chapters) into the final PDF in one streaming CoreGraphics pass, and
// writes the outline and link annotations as it goes. PDFKit is not used to write: on iOS its
// `write` drops the outline (F0 finding 3). Runs off the main thread; memory stays flat because
// one part is open at a time.

/// One outline entry, by zero-based page index in the joined document.
nonisolated struct WebPDFOutlineItem: Sendable, Equatable {
    var title: String
    var pageIndex: Int
    var children: [WebPDFOutlineItem] = []
}

/// A link annotation to write: one clickable rect per line of the link's text.
nonisolated struct WebPDFLink: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        /// A page of the joined document (zero-based); the jump lands at its top.
        case page(Int)
        case url(URL)
    }

    /// Zero-based page of the joined document that shows the link.
    var pageIndex: Int
    /// In that page's space (PDF points, origin bottom left).
    var rects: [CGRect]
    var target: Target
}

nonisolated struct WebPDFDocumentInfo: Sendable, Equatable {
    var title: String?
    var author: String?
}

nonisolated enum WebPDFJoiner {
    /// Draws every page of `parts`, in order, into a new PDF at `output`, adding `links` and the
    /// `outline`. Returns the page count. Checks for cancellation between parts; on any error
    /// the output file is removed. `progress` gets the fraction of pages written.
    static func join(parts: [URL], to output: URL, outline: [WebPDFOutlineItem], links: [WebPDFLink],
                     info: WebPDFDocumentInfo, progress: (Double) -> Void) throws -> Int {
        var auxiliary: [CFString: Any] = [kCGPDFContextCreator: "Tactile Texts"]
        if let title = info.title { auxiliary[kCGPDFContextTitle] = title }
        if let author = info.author { auxiliary[kCGPDFContextAuthor] = author }
        guard let context = CGContext(output as CFURL, mediaBox: nil, auxiliary as CFDictionary) else {
            throw ConversionError.failed(reason: "The PDF could not be created.")
        }
        var closed = false
        do {
            let linksByPage = Dictionary(grouping: links, by: \.pageIndex)
            var targetPages = Set<Int>()
            for link in links { if case let .page(page) = link.target { targetPages.insert(page) } }
            let total = parts.reduce(0) { $0 + (CGPDFDocument($1 as CFURL)?.numberOfPages ?? 0) }
            var pageIndex = 0
            for part in parts {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let document = CGPDFDocument(part as CFURL) else {
                        throw ConversionError.failed(reason: "A printed part (\(part.lastPathComponent)) could not be read.")
                    }
                    guard document.numberOfPages > 0 else { return }
                    for number in 1...document.numberOfPages {
                        guard let page = document.page(at: number) else { continue }
                        var box = page.getBoxRect(.mediaBox)
                        context.beginPage(mediaBox: &box)
                        context.drawPDFPage(page)
                        if targetPages.contains(pageIndex) {
                            context.addDestination(destinationName(pageIndex), at: CGPoint(x: box.minX, y: box.maxY))
                        }
                        for link in linksByPage[pageIndex] ?? [] {
                            for rect in link.rects {
                                switch link.target {
                                case let .page(target): context.setDestination(destinationName(target), for: rect)
                                case let .url(url): context.setURL(url as CFURL, for: rect)
                                }
                            }
                        }
                        context.endPage()
                        pageIndex += 1
                        if total > 0, pageIndex % 16 == 0 { progress(Double(pageIndex) / Double(total)) }
                    }
                }
            }
            if !outline.isEmpty {
                let children = outline.map { dictionary(for: $0, pageCount: pageIndex) }
                CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: children] as CFDictionary)
            }
            context.closePDF()
            closed = true
            progress(1)
            return pageIndex
        } catch {
            if !closed { context.closePDF() }
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func destinationName(_ pageIndex: Int) -> CFString { "tt-page-\(pageIndex)" as CFString }

    private static func dictionary(for item: WebPDFOutlineItem, pageCount: Int) -> CFDictionary {
        var entry: [CFString: Any] = [
            kCGPDFOutlineTitle: item.title,
            // One-based page number.
            kCGPDFOutlineDestination: min(max(item.pageIndex, 0), max(pageCount - 1, 0)) + 1,
        ]
        if !item.children.isEmpty {
            entry[kCGPDFOutlineChildren] = item.children.map { dictionary(for: $0, pageCount: pageCount) }
        }
        return entry as CFDictionary
    }
}
