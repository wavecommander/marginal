import CoreGraphics
import Testing
import UIKit
@testable import Marginal

/// The arithmetic behind "the reading position is stable", against a model of a continuous
/// vertical document whose scale follows the view width (PDFKit's fit-width behaviour).
struct ReadingAnchorTests {
    /// Pages of `pageSize` points stacked vertically, scaled to fit `viewWidth`, separated by
    /// `gap` view points, with `margin` view points above the first page.
    struct Layout {
        var pageSize = CGSize(width: 612, height: 792)
        var pageCount = 12
        var viewWidth: CGFloat
        var gap: CGFloat = 20
        var margin: CGFloat = 10
        var fixedScale: CGFloat?

        var scale: CGFloat { fixedScale ?? (viewWidth - 2 * margin) / pageSize.width }
        var pageHeight: CGFloat { pageSize.height * scale }
        var contentSize: CGSize {
            CGSize(width: max(viewWidth, pageSize.width * scale + 2 * margin),
                   height: margin * 2 + CGFloat(pageCount) * pageHeight + CGFloat(pageCount - 1) * gap)
        }

        /// Page point → content point (y up in page space, y down in content).
        func content(page: Int, point: CGPoint) -> CGPoint {
            CGPoint(x: margin + point.x * scale,
                    y: margin + CGFloat(page) * (pageHeight + gap) + (pageSize.height - point.y) * scale)
        }

        /// Content point → (nearest page, page point): the inverse of `content`.
        func anchor(at content: CGPoint) -> ReadingAnchor {
            let stride = pageHeight + gap
            let page = min(max(Int(((content.y - margin) / stride).rounded(.down)), 0), pageCount - 1)
            let y = pageSize.height - (content.y - margin - CGFloat(page) * stride) / scale
            return ReadingAnchor(pageIndex: page, point: CGPoint(x: (content.x - margin) / scale, y: y))
        }
    }

    let insets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    private func capture(_ layout: Layout, offset: CGPoint, insets: UIEdgeInsets) -> ReadingAnchor {
        layout.anchor(at: ViewportAnchorMath.topLeftContentPoint(contentOffset: offset, insets: insets))
    }

    private func restore(_ anchor: ReadingAnchor, in layout: Layout, viewHeight: CGFloat, insets: UIEdgeInsets) -> CGPoint {
        ViewportAnchorMath.contentOffset(placing: layout.content(page: anchor.pageIndex, point: anchor.point),
                                         insets: insets, contentSize: layout.contentSize,
                                         boundsSize: CGSize(width: layout.viewWidth, height: viewHeight))
    }

    @Test func topLeftPointAndOffsetAreInverses() {
        let insets = UIEdgeInsets(top: 50, left: 4, bottom: 20, right: 0)
        let offset = CGPoint(x: 0, y: 1234.5)
        let point = ViewportAnchorMath.topLeftContentPoint(contentOffset: offset, insets: insets)
        #expect(point == CGPoint(x: 4, y: 1284.5))
        let back = ViewportAnchorMath.contentOffset(placing: point, insets: insets,
                                                    contentSize: CGSize(width: 800, height: 10_000),
                                                    boundsSize: CGSize(width: 800, height: 700))
        #expect(back == offset)
    }

    @Test(arguments: [CGFloat(10), 1234.5, 3000, 5321.25])  // 10: exactly the top of page 1
    func panelToggleRoundTripsExactlyAcrossScaleChanges(startY: CGFloat) {
        let wide = Layout(viewWidth: 587.5)      // both panels open
        let wider = Layout(viewWidth: 868)       // Contents closed
        let widest = Layout(viewWidth: 1210)     // both closed
        let start = CGPoint(x: 0, y: startY)
        let anchor = capture(wide, offset: start, insets: insets)

        // The anchor is restored, never re-derived: any sequence of widths returns exactly.
        for layout in [wider, widest, wider, wide, widest, wide] {
            let offset = restore(anchor, in: layout, viewHeight: 748, insets: insets)
            let seen = capture(layout, offset: offset, insets: insets)
            #expect(seen.pageIndex == anchor.pageIndex)
            #expect(abs(seen.point.y - anchor.point.y) < 0.0001)
        }
        #expect(abs(restore(anchor, in: wide, viewHeight: 748, insets: insets).y - start.y) < 1e-6)
    }

    @Test func topOfDocumentClampsAndStillReturnsExactly() {
        // Offset 0 shows the margin above page 1; at another scale that point is above the
        // scrollable range and is clamped, but the kept anchor brings the exact offset back.
        let wide = Layout(viewWidth: 587.5), widest = Layout(viewWidth: 1210)
        let anchor = capture(wide, offset: .zero, insets: insets)
        #expect(restore(anchor, in: widest, viewHeight: 748, insets: insets).y >= 0)
        #expect(abs(restore(anchor, in: wide, viewHeight: 748, insets: insets).y) < 1e-6)
    }

    @Test func manualZoomKeepsThePointAcrossWidths() {
        let narrow = Layout(viewWidth: 587.5, fixedScale: 1.8)
        let wide = Layout(viewWidth: 1210, fixedScale: 1.8)
        let start = CGPoint(x: 250, y: 4000)
        let anchor = capture(narrow, offset: start, insets: insets)
        let offset = restore(anchor, in: wide, viewHeight: 748, insets: insets)
        let seen = capture(wide, offset: offset, insets: insets)
        #expect(seen.pageIndex == anchor.pageIndex)
        #expect(abs(seen.point.y - anchor.point.y) < 0.0001)
        #expect(abs(restore(anchor, in: narrow, viewHeight: 748, insets: insets).y - start.y) < 1e-6)
        #expect(abs(restore(anchor, in: narrow, viewHeight: 748, insets: insets).x - start.x) < 1e-6)
    }

    @Test func pointInThePageGapRoundTrips() {
        let layout = Layout(viewWidth: 587.5)
        let gapTop = layout.content(page: 3, point: CGPoint(x: 0, y: 0)).y + 5  // inside the gap below page 3
        let anchor = capture(layout, offset: CGPoint(x: 0, y: gapTop), insets: insets)
        #expect(anchor.point.y < 0)  // below the page's bottom edge: outside its bounds, still linear
        let other = Layout(viewWidth: 1210)
        let offset = restore(anchor, in: other, viewHeight: 748, insets: insets)
        #expect(abs(capture(other, offset: offset, insets: insets).point.y - anchor.point.y) < 0.0001)
        #expect(abs(restore(anchor, in: layout, viewHeight: 748, insets: insets).y - gapTop) < 1e-6)
    }

    @Test func clampingNearTheEndDoesNotLoseTheAnchor() {
        let tall = Layout(viewWidth: 1210)
        let short = Layout(viewWidth: 400)  // smaller scale, shorter content
        let end = tall.contentSize.height - 748
        let anchor = capture(tall, offset: CGPoint(x: 0, y: end), insets: insets)
        let clamped = restore(anchor, in: short, viewHeight: 748, insets: insets)
        #expect(clamped.y <= short.contentSize.height - 748 + 0.0001)
        // Back at the original width the exact place returns, because the anchor was kept.
        #expect(abs(restore(anchor, in: tall, viewHeight: 748, insets: insets).y - end) < 1e-6)
    }

    @Test func insetsChangeLikeTheKeyboard() {
        let layout = Layout(viewWidth: 868)
        let start = CGPoint(x: 0, y: 2222)
        let anchor = capture(layout, offset: start, insets: insets)
        let keyboard = UIEdgeInsets(top: 0, left: 0, bottom: 320, right: 0)
        let offset = restore(anchor, in: layout, viewHeight: 428, insets: keyboard)
        #expect(abs(offset.y - start.y) < 1e-6)  // top inset unchanged: the top edge keeps its point
    }

    @Test func descriptionIsTheTestHookFormat() {
        let anchor = ReadingAnchor(pageIndex: 2, point: CGPoint(x: 12, y: 412.5))
        #expect(anchor.description(scale: 1.25) == "page 3 x 12.00 y 412.50 scale 1.2500")
    }
}
