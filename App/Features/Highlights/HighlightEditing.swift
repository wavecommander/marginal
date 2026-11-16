import PDFKit
import ReaderCore

/// Turns a text selection into stored highlights, applying the overlap rule.
///
/// ## The overlap rule (one rule, per page)
/// A new highlight **absorbs every existing highlight on that page that it overlaps** (shares
/// part of a line with, see `HighlightGeometry.overlaps`): the result is one highlight covering
/// the union of their text, in the **colour just chosen**. So:
/// - selecting inside a highlight and choosing its own colour changes nothing (no duplicate);
/// - selecting inside or across a highlight and choosing another colour recolours the whole
///   merged highlight (no colours stacked on top of each other);
/// - selecting across two highlights joins them, and the text between them, into one.
/// The merged highlight keeps the id and creation date of the oldest highlight it absorbed (so
/// lists keep their place), the others are deleted, and nothing is saved if the result equals
/// what is stored. Highlights that only touch end to end are separate. A selection across a page
/// boundary makes one highlight per page, and the rule applies on each page independently.
///
/// The merged text and line rects come from the page itself (a `PDFSelection` over the new
/// lines and the absorbed highlights' lines), so they follow the page's reading order; if the
/// page cannot be consulted the rects are unioned per line and the new selection's text kept.
///
/// ## The text source (S4)
/// A highlight made, or merged, on a page that has no text of its own **in the file**
/// (`textLayer` answers `.noText`) records `HighlightTextSource.liveText`. On a page with text
/// the source is left as it was (`nil` for a new highlight, exactly as before scanned books).
/// When `textLayer` does not know the page yet (`nil`), the source is left as it was too, and
/// the caller corrects it once the file has been read (`HighlightController`).
@MainActor
struct HighlightEditing {
    let store: LibraryStore
    let bookID: UUID
    /// The on-screen page for a zero-based index (for merging text), or `nil`.
    let page: (Int) -> PDFPage?
    /// Whether the page has text of its own in the file, or `nil` when not known yet. A cheap
    /// lookup: never reads a file.
    let textLayer: (Int) -> PageTextLayer?

    init(store: LibraryStore, bookID: UUID, textLayer: @escaping (Int) -> PageTextLayer? = { _ in nil },
         page: @escaping (Int) -> PDFPage?) {
        self.store = store
        self.bookID = bookID
        self.textLayer = textLayer
        self.page = page
    }

    /// Applies `color` to the selection. Returns the highlights now covering it (one per page
    /// part, in page order). Call inside `session.perform` so the changes are attributed.
    func apply(_ color: HighlightColor, to selection: ReaderTextSelection, now: Date = Date()) throws -> [Highlight] {
        var results: [Highlight] = []
        for part in selection.parts {
            let rects = part.lineRects.filter { !$0.isNull && !$0.isEmpty }
            guard !rects.isEmpty else { continue }
            let existing = try store.highlights.highlights(bookID: bookID, pageIndex: part.pageIndex)
            let absorbed = existing.filter { HighlightGeometry.overlaps($0.rects, rects) }
            var lines = rects
            var text = HighlightGeometry.normalizedText(part.string)
            if !absorbed.isEmpty {
                let merged = mergedLinesAndText(newPart: part, selection: selection.selection, absorbed: absorbed)
                lines = merged.lines
                text = merged.text ?? text
            }
            if text.isEmpty && absorbed.isEmpty { continue }
            let keeper = absorbed.min { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
            var result = keeper ?? Highlight(bookID: bookID, pageIndex: part.pageIndex, rects: lines, color: color,
                                             text: text, createdAt: now)
            result.rects = lines
            result.color = color
            result.text = text
            if textLayer(part.pageIndex) == .noText {
                result.textSource = .liveText
            }
            if result != keeper {
                try store.highlights.save(result)
            }
            for other in absorbed where other.id != result.id {
                try store.highlights.deleteHighlight(id: other.id)
            }
            results.append(result)
        }
        return results
    }

    private func mergedLinesAndText(newPart: ReaderTextSelection.PagePart, selection: PDFSelection,
                                    absorbed: [Highlight]) -> (lines: [CGRect], text: String?) {
        let fallback = HighlightGeometry.mergedLines(newPart.lineRects + absorbed.flatMap(\.rects))
        guard let page = page(newPart.pageIndex) else { return (fallback, nil) }
        // The new selection's lines on this page (from the selection itself when it has them,
        // else re-derived from the part's rects).
        var pieces = selection.selectionsByLine().filter { $0.pages.contains(page) }
        if pieces.isEmpty { pieces = newPart.lineRects.compactMap { Self.selection(on: page, line: $0) } }
        pieces += absorbed.flatMap(\.rects).compactMap { Self.selection(on: page, line: $0) }
        guard let combined = pieces.first.map({ $0.copy() as? PDFSelection ?? $0 }) else { return (fallback, nil) }
        for piece in pieces.dropFirst() { combined.add(piece) }
        let lines = combined.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isNull && !$0.isEmpty }
        let text = combined.string.map(HighlightGeometry.normalizedText)
        guard !lines.isEmpty else { return (fallback, nil) }
        return (lines, text?.isEmpty == false ? text : nil)
    }

    /// The text on `page` under a stored line rect. The rect is narrowed a little (a quarter of
    /// its height top and bottom, half a point at the ends) so neighbouring lines and the
    /// characters just outside it are not picked up.
    static func selection(on page: PDFPage, line rect: CGRect) -> PDFSelection? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let narrowed = rect.insetBy(dx: min(0.5, rect.width / 4), dy: rect.height / 4)
        guard let selection = page.selection(for: narrowed), let string = selection.string,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }
}
