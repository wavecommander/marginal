import Foundation
import ReaderCore

/// Revealing a highlight (WP7's jump API for the notes panel's list, the Notebook and search).
extension ReaderSession {
    /// Jumps to a highlight: scrolls its page so the highlight's lines are in view. It is a
    /// *jump* (section history records it, as for any row tapped in a list). The highlight is
    /// already drawn on its page, so by default nothing else is marked; pass `mark: true` to
    /// also flash PDFKit's search mark over it until `pdf.clearMarks()`.
    ///
    ///     session.jump(toHighlight: highlight)
    ///
    /// Returns `false` (and changes nothing) for a page outside the book.
    @discardableResult
    func jump(toHighlight highlight: Highlight, mark: Bool = false) -> Bool {
        jump(toPage: highlight.pageIndex, revealing: highlight.rects, mark: mark)
    }

    /// Jumps to a stored highlight by id. Returns `false` if it no longer exists or belongs to
    /// another book.
    @discardableResult
    func jump(toHighlightID id: UUID, mark: Bool = false) -> Bool {
        guard let highlight = try? store.highlights.highlight(id: id), highlight.bookID == book.id else { return false }
        return jump(toHighlight: highlight, mark: mark)
    }
}
