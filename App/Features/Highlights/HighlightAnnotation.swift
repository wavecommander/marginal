import PDFKit
import ReaderCore
import UIKit

/// How a stored highlight is shown on its page: an in-memory `PDFAnnotation` added to the
/// on-screen document's `PDFPage` while that page is displayed (see `HighlightController`).
///
/// - **Drawing.** `draw(with:in:)` is overridden: PDFKit calls it in page space, with the page's
///   rotation and the view's zoom already applied, so the fill stays registered to the text at
///   every zoom, after resizes and on rotated pages. Each line rect is filled with
///   `HighlightPalette.pageFill` in a **multiply** blend, so glyphs keep their colour (black stays
///   black) and only the paper takes the tint. PDFKit draws annotations after the page content
///   and before page overlays, so the fill sits on the text and under page ink.
/// - **Never written.** The annotation exists only in memory on the on-screen `PDFDocument`; the
///   app never writes that document (`write(to:)` / `dataRepresentation()` are never called on
///   it), and the controller removes the annotation when the page leaves the screen. The stored
///   record (`Highlight`) is the only persistent form.
/// - It is read-only, never printed, and carries no action, so PDFKit neither edits it nor
///   follows it; taps are handled by `HighlightController` through the bridge's tap hook.
///
/// Drawing may happen on PDFKit's rendering threads, so everything `draw` reads is immutable.
nonisolated final class HighlightAnnotation: PDFAnnotation {
    /// The stored highlight's id.
    let highlightID: UUID
    /// The colour (the record's), for tests and accessibility.
    let highlightColor: HighlightColor
    /// The line rects (page space).
    let lineRects: [CGRect]
    private let fill: CGColor

    init(highlight: Highlight) {
        highlightID = highlight.id
        highlightColor = highlight.color
        lineRects = highlight.rects.filter { !$0.isNull && !$0.isEmpty }
        fill = HighlightPalette.pageFill(highlight.color).cgColor
        let bounds = HighlightGeometry.union(lineRects)
        super.init(bounds: bounds.isNull ? .zero : bounds, forType: .highlight, withProperties: nil)
        color = HighlightPalette.pageFill(highlight.color)
        isReadOnly = true
        shouldPrint = false
        shouldDisplay = true
        userName = "Marginal"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !lineRects.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setFillColor(fill)
        for rect in lineRects {
            context.fill(rect)
        }
        context.restoreGState()
    }
}
