import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import Marginal

/// Ink space (`PageInkGeometry`): pure mapping, and registration with PDFKit's own page
/// coordinates in a real PDF view at several zooms, page sizes, rotations and crop boxes, and
/// after a window resize.
@MainActor
struct PageInkGeometryTests {
    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    // MARK: Pure mapping

    @Test(arguments: [0, 90, 180, 270])
    func cornersMapToTheUprightPage(rotation: Int) {
        let crop = CGRect(x: 30, y: 100, width: 500, height: 700)
        let geometry = PageInkGeometry(cropBox: crop, rotation: rotation)
        let w = crop.width, h = crop.height
        // The page's top-left (minX, maxY) is where the rotation puts it on screen.
        let topLeft = CGPoint(x: crop.minX, y: crop.maxY).applying(geometry.pageToInk)
        let expected: CGPoint = switch rotation {
        case 90: CGPoint(x: h, y: 0)        // clockwise: top-left goes to top-right
        case 180: CGPoint(x: w, y: h)
        case 270: CGPoint(x: 0, y: w)
        default: .zero
        }
        #expect(close(topLeft, expected), "\(rotation): \(topLeft) vs \(expected)")
        #expect(geometry.size == (rotation % 180 == 0 ? crop.size : CGSize(width: h, height: w)))
        // Round trip.
        for point in [CGPoint(x: 12, y: 34), CGPoint(x: 400, y: 5), CGPoint(x: 0, y: 0)] {
            #expect(close(point.applying(geometry.inkToPage).applying(geometry.pageToInk), point))
        }
        // The whole crop box maps onto ink space exactly.
        #expect(crop.applying(geometry.pageToInk).standardized.integral == geometry.bounds)
    }

    @Test func rotationIsNormalised() {
        #expect(PageInkGeometry(cropBox: CGRect(x: 0, y: 0, width: 10, height: 20), rotation: -90).rotation == 270)
        #expect(PageInkGeometry(cropBox: CGRect(x: 0, y: 0, width: 10, height: 20), rotation: 450).rotation == 90)
    }

    @Test func overlayTransformCountersTheOverlayRotation() {
        let crop = CGRect(x: 0, y: 0, width: 400, height: 600)
        // 0°: identity.
        #expect(PageInkGeometry(cropBox: crop, rotation: 0).inkToOverlay(displayBox: crop) == .identity)
        // 90°: PDFKit rotates the overlay +90°, so ink space sits at −90° inside it.
        let t = PageInkGeometry(cropBox: crop, rotation: 90).inkToOverlay(displayBox: crop)
        #expect(t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0)
        // A cropped page shown with its media box: ink space is offset inside the overlay.
        let cropped = PageInkGeometry(cropBox: CGRect(x: 30, y: 100, width: 522, height: 642), rotation: 0)
        let media = CGRect(x: 0, y: 0, width: 612, height: 792)
        #expect(CGPoint.zero.applying(cropped.inkToOverlay(displayBox: media)) == CGPoint(x: 30, y: 50))
    }

    // MARK: Registration with PDFKit

    /// Page sizes, rotations and a crop box; at several zooms and after a resize, every canvas
    /// point lands exactly where PDFKit draws the same page point.
    @Test func canvasRegistersWithPDFKitPageSpace() async throws {
        let pdf = try PageInkTestSupport.makePDF(
            sizes: [CGSize(width: 612, height: 792), CGSize(width: 400, height: 600), CGSize(width: 612, height: 792),
                    CGSize(width: 842, height: 595), CGSize(width: 300, height: 500)],
            rotations: [0, 90, 0, 180, 270],
            cropInsets: [nil, nil, UIEdgeInsets(top: 50, left: 30, bottom: 100, right: 60), nil,
                         UIEdgeInsets(top: 20, left: 10, bottom: 40, right: 30)])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let (store, book) = try PageInkTestSupport.makeStore(pdf: pdf, pageCount: 5)
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = PageInkTestSupport.Host(book: book, store: store, size: CGSize(width: 900, height: 1100))
        #expect(await PageInkTestSupport.waitUntil { host.session.loadState == .ready })
        await PageInkTestSupport.pause(0.5)

        var checked: Set<String> = []
        for size in [CGSize(width: 900, height: 1100), CGSize(width: 500, height: 800)] {
            host.resize(to: size)
            await PageInkTestSupport.pause(0.5)
            for scale in [1.0, 2.5, 4.0] as [CGFloat] {
                for pageIndex in 0..<5 {
                    let page = try #require(host.pdfView.document?.page(at: pageIndex))
                    // The reader's own zoom, as a zoom command reports it. A scale change the
                    // controller was not told about counts as PDFKit refitting, and it puts the
                    // reading anchor back over `showTop(of:)` below (TSOFT-223).
                    host.session.pdf.readerDidZoom()
                    host.pdfView.autoScales = false
                    host.pdfView.scaleFactor = scale
                    var shown = false
                    for _ in 0..<5 where !shown {
                        host.pdfView.layoutIfNeeded()
                        host.pdfView.showTop(of: page)
                        shown = await PageInkTestSupport.waitUntil(timeout: 2) {
                            host.provider?.liveSurfaces[pageIndex]?.overlay?.window != nil
                        }
                    }
                    #expect(shown, "page \(pageIndex) at scale \(scale), size \(size): live \(host.provider?.liveSurfaces.keys.sorted() ?? [])")
                    await PageInkTestSupport.pause(0.1)
                    let surface = try #require(host.provider?.liveSurfaces[pageIndex])
                    let geometry = surface.geometry
                    #expect(geometry == PageInkGeometry(page: page))
                    for ink in [CGPoint.zero, CGPoint(x: geometry.size.width, y: 0), CGPoint(x: 37, y: 91),
                                CGPoint(x: geometry.size.width, y: geometry.size.height)] {
                        let viaCanvas = surface.canvas.convert(ink, to: host.pdfView)
                        let viaPDFKit = host.pdfView.convert(ink.applying(geometry.inkToPage), from: page)
                        #expect(close(viaCanvas, viaPDFKit, 0.05),
                                "page \(pageIndex) rot \(page.rotation) scale \(scale) size \(size) ink \(ink): \(viaCanvas) vs \(viaPDFKit)")
                    }
                    checked.insert("\(pageIndex)-\(scale)-\(size.width)")
                }
            }
        }
        #expect(checked.count == 2 * 3 * 5)
        await host.close()
    }
}
