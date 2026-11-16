import Foundation
import PDFKit
import ReaderCore

// S4 · Where a new highlight's text comes from (design: "Scanned books" ▸ Highlights on scanned
// pages). A highlight made on a page that has no text of its own in the PDF file is a
// scanned-page highlight (`HighlightTextSource.liveText`): its text is PDFKit's Live Text.
//
// The question is asked of the **file**, never of the on-screen `PDFDocument`: PDFKit adds the
// text it recognises to the pages it shows, in memory, so the on-screen page of a scanned book
// reports text a few seconds after it appears (docs/SCANNED_BOOKS_FINDINGS.md, item 1).

/// Whether a page of the PDF file has text of its own.
nonisolated enum PageTextLayer: Sendable, Equatable {
    /// The page has at least one non-whitespace character in the file.
    case hasText
    /// The page has none: any text selected on it is Live Text.
    case noText

    /// The source a highlight made on such a page records: `.liveText` for a page without text
    /// of its own, `nil` (the text layer, as every highlight before scanned books) otherwise.
    var highlightSource: HighlightTextSource? {
        self == .noText ? .liveText : nil
    }

    /// The answer for a page of a document that is not shown on screen (so PDFKit has added no
    /// Live Text to it).
    static func of(_ page: PDFPage) -> PageTextLayer {
        guard page.numberOfCharacters > 0, let string = page.string,
              string.contains(where: { !$0.isWhitespace }) else { return .noText }
        return .hasText
    }
}

/// Reads pages' own text from a **private** `PDFDocument` opened from the book's file, off the
/// main thread. Requests are serialised.
actor PageTextLayerReader {
    private let url: URL
    private var document: PDFDocument?
    /// Pages read (tests and diagnostics).
    private(set) var readCount = 0

    init(url: URL) {
        self.url = url
    }

    /// The answer for each page in `pages` that exists (pages outside the book are left out).
    func layers(of pages: [Int]) -> [Int: PageTextLayer] {
        if document == nil { document = PDFDocument(url: url) }
        guard let document else { return [:] }
        var result: [Int: PageTextLayer] = [:]
        for index in pages where index >= 0 && index < document.pageCount {
            guard let page = document.page(at: index) else { continue }
            result[index] = PageTextLayer.of(page)
            readCount += 1
        }
        return result
    }

    /// Releases the private document. The next request reopens it.
    func purge() {
        document = nil
    }
}

/// One reader window's answers to "does this page have text of its own in the file", cached.
///
/// The controller prefetches the pages coming into view (`prefetch`), so by the time a
/// selection exists on a scanned page (PDFKit needs seconds to read it), making a highlight is a
/// dictionary lookup on the main thread (`cachedLayer`). A page whose answer is not cached yet is
/// answered off the main thread (`layer(forPage:)`); the controller then corrects the highlight
/// it has already saved.
@MainActor
final class HighlightTextSourceProbe {
    let reader: PageTextLayerReader
    private var known: [Int: PageTextLayer] = [:]
    private var requested: Set<Int> = []

    init(documentURL: URL) {
        reader = PageTextLayerReader(url: documentURL)
    }

    /// The cached answer for a page, or `nil` when it has not been read yet. Never reads a file.
    func cachedLayer(forPage pageIndex: Int) -> PageTextLayer? {
        known[pageIndex]
    }

    /// Reads, off the main thread, the pages in `pages` whose answer is not cached or requested.
    func prefetch(_ pages: some Sequence<Int>) {
        let missing = pages.filter { known[$0] == nil && !requested.contains($0) }.sorted()
        guard !missing.isEmpty else { return }
        requested.formUnion(missing)
        let reader = reader
        Task { [weak self] in
            let result = await reader.layers(of: missing)
            self?.remember(result, asked: missing)
        }
    }

    /// The answer for a page: cached, or read now off the main thread. `nil` for a page outside
    /// the book (or an unreadable file).
    func layer(forPage pageIndex: Int) async -> PageTextLayer? {
        if let known = known[pageIndex] { return known }
        let result = await reader.layers(of: [pageIndex])
        remember(result, asked: [])
        return result[pageIndex]
    }

    private func remember(_ result: [Int: PageTextLayer], asked: [Int]) {
        for (page, layer) in result { known[page] = layer }
        requested.subtract(asked)
    }

    /// Drops the private document (memory warning). The cached answers stay: the file never
    /// changes.
    func purge() {
        let reader = reader
        Task { await reader.purge() }
    }
}
