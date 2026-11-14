import PencilKit
import UIKit

/// Draws a page's stored ink into a `CGContext` from its strokes (for the Notebook, thumbnails,
/// and later an annotated export). Nothing is cached: every call renders at the scale it is
/// given, so the result is sharp at any size.
///
/// **Vector where the ink allows** (the note page's rule, `NotePageRenderer.export(for:)`):
/// `.pen`, `.marker` (multiply blend, uniform alpha) and `.monoline` strokes without an eraser
/// mask are filled as vector paths (`NotePageRenderer.outline(of:)`); every other stroke
/// (pencil, crayon, watercolour, fountain pen, reed, inks added by later systems, masked
/// strokes) is drawn as an image of that one stroke at `fallbackImageScale` × the drawing
/// scale, in z-order. Colours are resolved in the light appearance: ink is drawn as stored,
/// as on the white page.
@MainActor
enum PageInkRenderer {
    /// Pixels per ink point of the per-stroke fallback images, before the drawing scale.
    static let fallbackImageScale: CGFloat = 4

    /// Draws `drawing` (ink space) so that `source` (ink space; default: the whole page given by
    /// `geometry`) fills `target` in `context`, which must be y-down (UIKit orientation, as in
    /// `UIGraphicsImageRenderer` / `UIGraphicsPDFRenderer`). The aspect ratio follows `target`.
    static func draw(_ drawing: PKDrawing, geometry: PageInkGeometry, source: CGRect? = nil,
                     in context: CGContext, target: CGRect) {
        let source = source ?? geometry.bounds
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return }
        let sx = target.width / source.width
        let sy = target.height / source.height
        context.saveGState()
        context.clip(to: target)
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: sx, y: sy)
        context.translateBy(x: -source.minX, y: -source.minY)
        draw(drawing.strokes, in: context, scale: max(sx, sy))
        context.restoreGState()
    }

    /// Draws stored ink data (see `draw(_:geometry:source:in:target:)`).
    /// - Throws: when the data is not a readable drawing.
    static func draw(inkData: Data, geometry: PageInkGeometry, source: CGRect? = nil,
                     in context: CGContext, target: CGRect) throws {
        let drawing = try PKDrawing(data: inkData)
        draw(drawing, geometry: geometry, source: source, in: context, target: target)
    }

    /// Draws `drawing` in **page space** (PDF points, y up, as a `PDFPage.draw(with:to:)` context
    /// is set up), e.g. on top of a page in an annotated export.
    static func drawInPageSpace(_ drawing: PKDrawing, geometry: PageInkGeometry, in context: CGContext) {
        context.saveGState()
        context.concatenate(geometry.inkToPage)
        context.clip(to: geometry.bounds)
        draw(drawing.strokes, in: context, scale: 1)
        context.restoreGState()
    }

    /// An image of the ink alone (transparent background), `size` points at `scale`.
    static func image(_ drawing: PKDrawing, geometry: PageInkGeometry, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(drawing, geometry: geometry, in: context.cgContext, target: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Private

    /// Draws strokes in the context's current (ink-space) coordinates; `scale` is device units
    /// per ink point, for the fallback images.
    private static func draw(_ strokes: [PKStroke], in context: CGContext, scale: CGFloat) {
        let light = UITraitCollection(userInterfaceStyle: .light)
        light.performAsCurrent {
            for stroke in strokes {
                drawStroke(stroke, in: context, imageScale: fallbackImageScale * max(scale, 0.25), traits: light)
            }
        }
    }

    private static func drawStroke(_ stroke: PKStroke, in context: CGContext, imageScale: CGFloat,
                                   traits: UITraitCollection) {
        if NotePageRenderer.export(for: stroke) == .vector, let path = NotePageRenderer.outline(of: stroke) {
            let color = stroke.ink.color.resolvedColor(with: traits)
            var alpha: CGFloat = 1
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            context.saveGState()
            if stroke.ink.inkType == .marker { context.setBlendMode(.multiply) }
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.setAlpha(alpha)
            context.addPath(path)
            context.fillPath(using: .winding)
            context.restoreGState()
        } else {
            let bounds = stroke.renderBounds
            guard !bounds.isNull, !bounds.isEmpty else { return }
            let image = PKDrawing(strokes: [stroke]).image(from: bounds, scale: imageScale)
            guard let cgImage = image.cgImage else { return }
            // Draw y-down: flip around the image's own rect.
            context.saveGState()
            context.translateBy(x: bounds.minX, y: bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }
    }
}
