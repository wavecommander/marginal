import Foundation
import PDFKit
import UIKit

// What the PDF bridge (`ReaderPDFController`) hands to the session's features, and the values it
// hands them. The bridge calls the features directly, through the session's typed properties:
//
// - Page overlays (WP6, page ink): `session.pageInk` supplies one overlay view per displayed
//   page (`makeOverlayView`, `overlayWillAppear`, `overlayDidDisappear`). PDFKit owns the
//   overlay's frame: it sizes the overlay to the page and scales it with the page under zoom, so
//   draw in the overlay's own bounds (one point = one page point at 100%) and never set its
//   frame. PDFKit asks for an overlay when a page comes near the screen and ends it when the
//   page goes away; release everything per page in `overlayDidDisappear`.
// - The edit menu of a text selection (`ReaderPDFController.selectionMenuElements()`): the
//   highlight colours from `session.highlights` (WP7), then "Add as Heading"
//   (`SidebarHeadingActions`, WP5), inserted as an inline group at the start of the menu
//   whenever there is a non-empty selection. Use `session.pdf.clearSelection()` after acting.
// - Single taps on a page: `session.highlights` first (it consumes a tap on a highlight), then
//   the window's search if it exists (it clears its mark). The bridge's tap recogniser runs
//   alongside PDFKit's own gestures (text selection, links), never instead.
// - The set of on-screen pages (ascending, deduplicated): `session.highlights`. SwiftUI code
//   reads `session.visiblePageIndices`.
//
// Every call runs on the main actor. `pageIndex` is zero-based. "Page space" is
// PDFKit page space: points, origin at the lower-left of the page's media box, y up, unrotated
// (the space of `PDFSelection.bounds(for:)`, `PDFPage.bounds(for:)` and stored `Highlight.rects`).
//
// Accessibility: where a feature's elements must live to be exposed.
//
// The PDF view (`session.pdf.view`) does not expose PDFKit's document view to accessibility:
// it is a text input spanning the whole book, and reading it makes PDFKit extract every page's
// text on the main thread (9.7 s for `large.pdf`, per query). Its accessibility children are,
// in this order, recomputed on every query:
//   1. the on-screen page views, in reading order (PDFKit's own page text);
//   2. every other **direct subview** of `session.pdf.view` that is not PDFKit's own view and
//      not a `UITextInput`, in subview order.
// So to expose elements over the page (handwriting, highlights, probes), add one container view
// as a direct subview of `session.pdf.view`, non-interactive (`isUserInteractionEnabled =
// false`) unless it must take touches, with `isAccessibilityElement = false` and its elements
// in `accessibilityElements`, framed in its own coordinates wherever the content is now. The
// PDF view posts a layout-changed notification when such a view is added or removed. Elements
// placed anywhere else are not reached: subviews of a page view or page overlay (PDFKit exposes
// only its page text there), and subviews of PDFKit's scroll or document view. A hidden view
// (`isHidden` or `accessibilityElementsHidden`) is skipped. Example: `PageInkAccessibilityView`.

/// A text selection on the on-screen document, split per page and per line.
struct ReaderTextSelection {
    /// The part of the selection on one page.
    struct PagePart: Equatable {
        /// Zero-based page.
        var pageIndex: Int
        /// One rect per selected line, in page space (store these as `Highlight.rects`).
        var lineRects: [CGRect]
        /// The text selected on this page.
        var string: String
    }

    /// Parts in page order (one for a single-page selection).
    var parts: [PagePart]
    /// The whole selected text.
    var string: String
    /// The underlying PDFKit selection on the **on-screen** document (main actor only).
    var selection: PDFSelection
}

/// A single tap on a page.
struct ReaderPageTap {
    /// Zero-based page that was tapped.
    var pageIndex: Int
    /// The PDFKit page.
    var page: PDFPage
    /// The tap location in page space.
    var pointInPage: CGPoint
    /// The tap location in the PDF view's coordinates (for presenting menus).
    var pointInView: CGPoint
    /// The PDF view (for presenting an edit menu or converting rects).
    var view: PDFView
}
