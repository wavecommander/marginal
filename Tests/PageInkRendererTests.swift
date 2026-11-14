import Foundation
import PencilKit
import Testing
import UIKit
@testable import Marginal

/// `PageInkRenderer`: vector paths for pen-like inks, per-stroke images otherwise, at any target.
@MainActor
struct PageInkRendererTests {
    private let geometry = PageInkGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)

    private func pdf(_ drawing: PKDrawing, target: CGRect = CGRect(x: 0, y: 0, width: 306, height: 396)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            PageInkRenderer.draw(drawing, geometry: geometry, in: context.cgContext, target: target)
        }
    }

    @Test func penStrokesAreVectorPaths() {
        let drawing = PKDrawing(strokes: [
            PageInkTestSupport.stroke(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 400, y: 120)),
            PageInkTestSupport.stroke(from: CGPoint(x: 50, y: 200), to: CGPoint(x: 400, y: 260), ink: .marker, width: 12),
            PageInkTestSupport.stroke(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 400, y: 300), ink: .monoline),
        ])
        let counts = NotePageTestSupport.pdfOperatorCounts(pdf(drawing))
        #expect((counts["f"] ?? 0) >= 3, "\(counts)")
        #expect((counts["c"] ?? 0) > 0, "curves of the stroke outlines: \(counts)")
        #expect((counts["Do"] ?? 0) == 0 && (counts["BI"] ?? 0) == 0, "no images: \(counts)")
    }

    @Test func texturedInksFallBackToImages() {
        let drawing = PKDrawing(strokes: [
            PageInkTestSupport.stroke(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 400, y: 120)),
            PageInkTestSupport.stroke(from: CGPoint(x: 50, y: 200), to: CGPoint(x: 400, y: 220), ink: .pencil),
        ])
        let counts = NotePageTestSupport.pdfOperatorCounts(pdf(drawing))
        #expect((counts["f"] ?? 0) >= 1, "\(counts)")
        #expect((counts["Do"] ?? 0) + (counts["BI"] ?? 0) == 1, "one image for the pencil stroke: \(counts)")
    }

    @Test func drawsScaledIntoTheTarget() {
        let stroke = PageInkTestSupport.stroke(from: CGPoint(x: 306, y: 396), to: CGPoint(x: 306, y: 396), width: 20,
                                               color: .black)
        // Page centre → target centre at half size.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 306, height: 396)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 306, height: 396))
            PageInkRenderer.draw(PKDrawing(strokes: [stroke]), geometry: geometry, in: context.cgContext,
                                 target: CGRect(x: 0, y: 0, width: 306, height: 396))
        }
        #expect(isDark(image, at: CGPoint(x: 153, y: 198)))
        #expect(!isDark(image, at: CGPoint(x: 20, y: 20)))
    }

    @Test func pageSpaceDrawingUsesTheInverseMapping() {
        let rotated = PageInkGeometry(cropBox: CGRect(x: 0, y: 0, width: 400, height: 600), rotation: 90)
        // Ink point (10, 20) of a 90° page is page point (20, 10).
        #expect(CGPoint(x: 10, y: 20).applying(rotated.inkToPage).equalTo(CGPoint(x: 20, y: 10)))
    }

    private func isDark(_ image: UIImage, at point: CGPoint) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let scale = CGFloat(cgImage.width) / image.size.width
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cgImage, in: CGRect(x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale),
                                         width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) < 200
    }
}
