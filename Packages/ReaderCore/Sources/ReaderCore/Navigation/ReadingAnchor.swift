import CoreGraphics
import Foundation

/// The reader's place in the book: the page point (PDF page space) at the top-left corner of
/// the visible area. The reader keeps it through every change of the view's size (design: "The
/// reading position is stable"), and section history stores it so Back and Forward return to
/// the exact place the reader left (design: "Section history").
public struct ReadingAnchor: Hashable, Sendable, Codable {
    /// Zero-based page the point belongs to.
    public var pageIndex: Int
    /// Page-space point (y up). May lie outside the page's bounds when the top edge of the
    /// view is in the gap between pages; the mapping is linear, so that is exact too.
    public var point: CGPoint

    public init(pageIndex: Int, point: CGPoint) {
        self.pageIndex = pageIndex
        self.point = point
    }
}
