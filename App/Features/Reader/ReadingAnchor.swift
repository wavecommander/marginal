import CoreGraphics
import UIKit

/// The reader's place in the book: the page point (PDFKit page space) at the top-left corner
/// of the visible area. It changes only when the reader scrolls or zooms or a jump happens;
/// every change of the PDF view's size (panels, divider, window resize, rotation, keyboard)
/// puts the same page point back at the top-left corner (design: "The reading position is
/// stable").
nonisolated struct ReadingAnchor: Equatable, Sendable {
    /// Zero-based page the point belongs to.
    var pageIndex: Int
    /// Page-space point (y up). May lie outside the page's bounds when the top edge of the
    /// view is in the gap between pages; the mapping is linear, so that is exact too.
    var point: CGPoint

    /// Test-hook text: `"page 3 x 12.00 y 412.50 scale 1.2500"` (1-based page).
    func description(scale: CGFloat) -> String {
        String(format: "page %d x %.2f y %.2f scale %.4f", pageIndex + 1, point.x, point.y, scale)
    }
}

/// Pure scroll-view arithmetic behind `ReadingAnchor` (unit-tested). "Content" coordinates are
/// the scroll view's bounds space, where `contentOffset` is the top-left of the bounds.
nonisolated enum ViewportAnchorMath {
    /// The content point at the top-left corner of the visible (inset-adjusted) area.
    static func topLeftContentPoint(contentOffset: CGPoint, insets: UIEdgeInsets) -> CGPoint {
        CGPoint(x: contentOffset.x + insets.left, y: contentOffset.y + insets.top)
    }

    /// The content offset that puts `contentPoint` at the top-left corner of the visible area,
    /// clamped to the scrollable range (so near the end of a document, or when the content is
    /// narrower than the view, the nearest reachable offset is used; the anchor itself is kept,
    /// so a later size change can still restore it exactly).
    static func contentOffset(placing contentPoint: CGPoint, insets: UIEdgeInsets, contentSize: CGSize,
                              boundsSize: CGSize) -> CGPoint {
        let minX = -insets.left, minY = -insets.top
        let maxX = max(minX, contentSize.width + insets.right - boundsSize.width)
        let maxY = max(minY, contentSize.height + insets.bottom - boundsSize.height)
        let x = min(max(contentPoint.x - insets.left, minX), maxX)
        let y = min(max(contentPoint.y - insets.top, minY), maxY)
        return CGPoint(x: x, y: y)
    }
}
