import Foundation
import UIKit

// Printing one loaded document in segments, shared by every web-family converter (an EPUB's
// chapters, a text or Office document, a slide deck). See `WebPDFRenderer.planSegments` for why
// long documents are cut, and `WebTargetLocator` for what happens to the parts afterwards.

/// A heading as the web view laid it out, for an outline built from the document's own headings.
nonisolated struct WebHeading: Sendable, Equatable, Codable {
    /// 1 for `h1` … 6 for `h6`.
    var level: Int
    /// Collapsed, at most 120 characters.
    var text: String
    /// Fraction of the document height (0 = top).
    var top: Double
}

/// One printed part: a whole document, or one segment of a long one.
nonisolated struct WebPrintedPart: Sendable {
    /// The document the part was printed from (a chapter's path in an EPUB).
    var path: String
    /// Zero-based segment of the document (see `WebPDFRenderer.planSegments`).
    var part: Int = 0
    /// How many segments the document was printed in.
    var parts: Int = 1
    var pdf: URL
    var pageCount: Int
    var layout: WebDocumentLayout
    /// The visible `h1`–`h6`, when asked for.
    var headings: [WebHeading] = []
    var report: WebPrintReport
}

extension WebPDFRenderer {
    /// Prints the loaded document into `workspace`, in segments when it is long, with each
    /// segment's layout (and headings when `headings` is set). Files are named
    /// `<prefix>-<segment>.pdf`. `progress` gets the fraction of segments printed.
    func printSegments(path: String, into workspace: URL, prefix: String, pagesPerSegment: Int = EPUBStyle.pagesPerSegment,
                       splitAbove: Int = EPUBStyle.splitAbove, headings: Bool = false,
                       progress: (Double) -> Void = { _ in }) async throws -> [WebPrintedPart] {
        let segments = try await planSegments(pagesPerSegment: pagesPerSegment, splitAbove: splitAbove)
        var printed: [WebPrintedPart] = []
        for segment in 0..<segments {
            try Task.checkCancellation()
            if segments > 1 { try await showSegment(segment) }
            let layout = try await collectLayout()
            let found = headings ? try await collectHeadings() : []
            let url = workspace.appendingPathComponent(String(format: "%@-%03d.pdf", prefix, segment))
            let report = try await printPDF(to: url)
            printed.append(WebPrintedPart(path: path, part: segment, parts: segments, pdf: url, pageCount: report.pageCount,
                                          layout: layout, headings: found, report: report))
            progress(Double(segment + 1) / Double(segments))
        }
        return printed
    }

    /// The visible headings (`h1`–`h6`, and elements with `role="heading"`), in document order.
    func collectHeadings() async throws -> [WebHeading] {
        let json = try await evaluate(Self.headingsScript)
        do {
            return try JSONDecoder().decode([WebHeading].self, from: Data(json.utf8))
        } catch {
            throw WebRenderError.scriptFailed("unexpected heading data")
        }
    }

    nonisolated static let headingsScript = """
        const root = document.documentElement;
        if (!root) { return '[]'; }
        const body = document.body || root;
        const height = Math.max(root.scrollHeight, body.scrollHeight || 0, 1);
        const scrollY = window.scrollY || 0;
        const clean = s => (s || '').replace(/[\\u00AD\\u200B-\\u200D\\u2060\\uFEFF]/g, '').replace(/\\s+/g, ' ').trim();
        const out = [];
        for (const el of document.querySelectorAll('h1, h2, h3, h4, h5, h6, [role="heading"]')) {
          if (out.length >= 5000) { break; }
          if (el.getClientRects().length === 0) { continue; }
          const text = clean(el.textContent).slice(0, 120);
          if (!text) { continue; }
          const tag = /^H([1-6])$/i.exec(el.nodeName);
          const aria = parseInt(el.getAttribute('aria-level') || '2', 10);
          const level = tag ? parseInt(tag[1], 10) : Math.min(6, Math.max(1, isNaN(aria) ? 2 : aria));
          const top = Math.min(1, Math.max(0, (el.getBoundingClientRect().top + scrollY) / height));
          out.push({level: level, text: text, top: top});
        }
        return JSON.stringify(out);
        """
}
