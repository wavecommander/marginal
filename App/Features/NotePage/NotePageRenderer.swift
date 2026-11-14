import PencilKit
import ReaderCore
import SwiftUI
import UIKit

/// A note laid out for read-only display or export: its text, and its ink relocated to the
/// text's current layout (exactly what the editor would show), at 100% zoom.
struct NotePageSnapshot {
    /// The note's text.
    let text: String
    /// The band layout of `text` on a note page.
    let layout: NoteBandLayout
    /// The ink in note-page coordinates (relocated from its stored layout to `layout`).
    let drawing: PKDrawing
    /// The note page's size at 100%: `NotePageStyle.pageWidth` wide, tall enough for the text and
    /// the ink plus a margin (no blank writing room).
    let size: CGSize
    /// `true` when the stored ink could not be read (written by a newer app version); the
    /// snapshot then shows the text only.
    let inkUnreadable: Bool

    var hasInk: Bool { !drawing.strokes.isEmpty }
}

/// Everything that shows a note read-only (Notebook, "page notes in this section", exports).
///
/// All entry points work off-screen for notes that are not open, given `(Note, ink Data)` as
/// stored (`LibraryStore.noteInk(bookID:noteID:)`), and never re-wrap: a note drawn at another
/// width is the same layout scaled. Main actor (they use TextKit and PencilKit rendering).
///
/// **Ink in PDF export** (`draw(_:in:)`): strokes whose ink can be reproduced faithfully from
/// their `PKStrokePath` points are drawn as **vector paths**: `.pen`, `.marker` (multiply blend,
/// uniform alpha), `.monoline`. Everything else is drawn as a high-resolution image of that one
/// stroke, in z-order: textured inks (`.pencil`, `.crayon`, `.watercolor`), `.fountainPen` and
/// `.reed` (angled nibs whose outline the points do not describe), inks added by later systems,
/// and any stroke with an eraser mask.
@MainActor
enum NotePageRenderer {
    /// Scale of the per-stroke images used for inks that cannot be drawn as vectors.
    static let fallbackImageScale: CGFloat = 4

    // MARK: Snapshot

    /// Lays out a stored note. `inkData` is the note's ink as stored (`nil` for none).
    static func snapshot(note: Note, inkData: Data?) -> NotePageSnapshot {
        snapshot(text: note.text, inkData: inkData, savedLayout: note.bandLayout)
    }

    /// The open note of a model, as it is now (including unsaved edits).
    static func snapshot(of model: NotePageModel) -> NotePageSnapshot {
        let layout = NotePageLayoutEngine.shared.bandLayout(for: model.text)
        let drawing = model.ink.relaid(to: layout).composedDrawing()
        return NotePageSnapshot(text: model.text, layout: layout, drawing: drawing,
                                size: pageSize(layout: layout, drawing: drawing), inkUnreadable: false)
    }

    static func snapshot(text: String, inkData: Data?, savedLayout: NoteBandLayout?) -> NotePageSnapshot {
        let layout = NotePageLayoutEngine.shared.bandLayout(for: text)
        var drawing = PKDrawing()
        var unreadable = false
        if let inkData {
            do {
                let ink = try NoteInkArchive.decode(inkData, fallbackLayout: savedLayout ?? layout)
                drawing = ink.relaid(to: layout).composedDrawing()
            } catch {
                unreadable = true
            }
        }
        return NotePageSnapshot(text: text, layout: layout, drawing: drawing,
                                size: pageSize(layout: layout, drawing: drawing), inkUnreadable: unreadable)
    }

    /// The note page's size at 100% (see `NotePageSnapshot.size`).
    static func pageSize(note: Note, inkData: Data?) -> CGSize {
        snapshot(note: note, inkData: inkData).size
    }

    private static func pageSize(layout: NoteBandLayout, drawing: PKDrawing) -> CGSize {
        let textBottom = layout.trailingTop + NotePageStyle.textInsets.bottom
        let bounds = drawing.bounds
        let inkBottom = bounds.isNull || drawing.strokes.isEmpty ? 0 : bounds.maxY + NotePageStyle.renderBottomMargin
        return CGSize(width: NotePageStyle.pageWidth, height: ceil(max(textBottom, inkBottom)))
    }

    // MARK: Bitmap (Markdown export)

    /// PNG of the whole note (text and ink) on white paper in the light appearance, `width`
    /// points wide (default: the page width) at `scale` pixels per point (default 3).
    static func pngData(note: Note, inkData: Data?, scale: CGFloat = 3, width: CGFloat? = nil) -> Data? {
        pngData(snapshot(note: note, inkData: inkData), scale: scale, width: width)
    }

    static func pngData(_ snapshot: NotePageSnapshot, scale: CGFloat = 3, width: CGFloat? = nil) -> Data? {
        image(snapshot, scale: scale, width: width).pngData()
    }

    /// The note as an image (see `pngData`). Its `size` is in points.
    static func image(_ snapshot: NotePageSnapshot, scale: CGFloat = 3, width: CGFloat? = nil) -> UIImage {
        let factor = (width ?? snapshot.size.width) / snapshot.size.width
        let size = CGSize(width: snapshot.size.width * factor, height: snapshot.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let light = UITraitCollection(userInterfaceStyle: .light)
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            light.performAsCurrent {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let cg = context.cgContext
                cg.saveGState()
                cg.scaleBy(x: factor, y: factor)
                NotePageLayoutEngine.shared.drawText(snapshot.text, in: cg)
                if snapshot.hasInk {
                    let page = CGRect(origin: .zero, size: snapshot.size)
                    snapshot.drawing.image(from: page, scale: scale * factor).draw(in: page)
                }
                cg.restoreGState()
            }
        }
    }

    // MARK: Vector (PDF export)

    /// Draws the note (text as glyphs, ink as vector paths where the ink allows; see the type
    /// documentation) into `context` in the light appearance, with its top-left at `origin`,
    /// `width` points wide (default: the page width). `context` must be in UIKit orientation
    /// (y down), as in `UIGraphicsPDFRenderer`; flip a raw Core Graphics PDF context first.
    /// Paints no background. - Returns: the size drawn, in the context's points.
    @discardableResult
    static func draw(_ snapshot: NotePageSnapshot, in context: CGContext, at origin: CGPoint = .zero,
                     width: CGFloat? = nil) -> CGSize {
        let factor = (width ?? snapshot.size.width) / snapshot.size.width
        let light = UITraitCollection(userInterfaceStyle: .light)
        light.performAsCurrent {
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: factor, y: factor)
            NotePageLayoutEngine.shared.drawText(snapshot.text, in: context)
            for stroke in snapshot.drawing.strokes {
                drawStroke(stroke, in: context, imageScale: fallbackImageScale * factor)
            }
            context.restoreGState()
        }
        return CGSize(width: snapshot.size.width * factor, height: snapshot.size.height * factor)
    }

    /// Convenience: `draw(snapshot(note:inkData:), in:at:width:)`.
    @discardableResult
    static func draw(note: Note, inkData: Data?, in context: CGContext, at origin: CGPoint = .zero,
                     width: CGFloat? = nil) -> CGSize {
        draw(snapshot(note: note, inkData: inkData), in: context, at: origin, width: width)
    }

    /// How a stroke is exported to PDF.
    enum StrokeExport: Equatable {
        case vector
        case image
    }

    /// Vector for `.pen`, `.marker` and `.monoline` without an eraser mask; image otherwise.
    static func export(for stroke: PKStroke) -> StrokeExport {
        guard stroke.mask == nil else { return .image }
        let vectorInks: [PKInk.InkType] = [.pen, .marker, .monoline]
        return vectorInks.contains(stroke.ink.inkType) ? .vector : .image
    }

    private static func drawStroke(_ stroke: PKStroke, in context: CGContext, imageScale: CGFloat) {
        if export(for: stroke) == .vector, let path = outline(of: stroke) {
            let color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
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
            UIGraphicsPushContext(context)
            image.draw(in: bounds)
            UIGraphicsPopContext()
        }
    }

    /// The filled outline of a stroke in note-page coordinates: per interpolated point a disc of
    /// the point's width, joined by tangent quads, all wound the same way so one non-zero fill is
    /// their union (uniform alpha, no seams). `nil` for an empty path.
    static func outline(of stroke: PKStroke) -> CGPath? {
        let transform = stroke.transform
        let widthScale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        var points: [(CGPoint, CGFloat)] = []
        for point in stroke.path.interpolatedPoints(by: .distance(1)) {
            let radius = max(point.size.width * widthScale / 2, 0.05)
            points.append((point.location.applying(transform), radius))
        }
        if points.isEmpty, let point = stroke.path.first {
            points.append((point.location.applying(transform), max(point.size.width * widthScale / 2, 0.05)))
        }
        guard !points.isEmpty else { return nil }
        let path = CGMutablePath()
        for (index, (center, radius)) in points.enumerated() {
            addDisc(to: path, center: center, radius: radius)
            guard index > 0 else { continue }
            let (previous, previousRadius) = points[index - 1]
            addQuad(to: path, from: previous, previousRadius, to: center, radius)
        }
        return path
    }

    /// A disc as four cubic arcs with increasing angle (positive shoelace orientation).
    private static func addDisc(to path: CGMutablePath, center c: CGPoint, radius r: CGFloat) {
        let k = 0.5522847498 * r
        path.move(to: CGPoint(x: c.x + r, y: c.y))
        path.addCurve(to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x + r, y: c.y + k),
                      control2: CGPoint(x: c.x + k, y: c.y + r))
        path.addCurve(to: CGPoint(x: c.x - r, y: c.y), control1: CGPoint(x: c.x - k, y: c.y + r),
                      control2: CGPoint(x: c.x - r, y: c.y + k))
        path.addCurve(to: CGPoint(x: c.x, y: c.y - r), control1: CGPoint(x: c.x - r, y: c.y - k),
                      control2: CGPoint(x: c.x - k, y: c.y - r))
        path.addCurve(to: CGPoint(x: c.x + r, y: c.y), control1: CGPoint(x: c.x + k, y: c.y - r),
                      control2: CGPoint(x: c.x + r, y: c.y - k))
        path.closeSubpath()
    }

    /// The quad joining two discs, wound like the discs.
    private static func addQuad(to path: CGMutablePath, from p0: CGPoint, _ r0: CGFloat, to p1: CGPoint, _ r1: CGFloat) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.0001 else { return }
        let nx = -dy / length, ny = dx / length
        var corners = [CGPoint(x: p0.x + nx * r0, y: p0.y + ny * r0), CGPoint(x: p1.x + nx * r1, y: p1.y + ny * r1),
                       CGPoint(x: p1.x - nx * r1, y: p1.y - ny * r1), CGPoint(x: p0.x - nx * r0, y: p0.y - ny * r0)]
        var area: CGFloat = 0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            area += a.x * b.y - b.x * a.y
        }
        if area < 0 { corners.reverse() }
        path.addLines(between: corners)
        path.closeSubpath()
    }
}

// MARK: - Read-only view

/// A note drawn read-only at the width SwiftUI offers (Notebook rows, "page notes in this
/// section"): the same layout as the editor, scaled, never re-wrapped. Text is drawn as glyphs
/// and ink is rendered from the strokes at the displayed scale (re-rendered when the size
/// changes, never a scaled bitmap). Drawn on light paper in every appearance, like the editor
/// (`NotePageStyle.pageAppearance`). Its height is
/// `width × snapshot.size.height / snapshot.size.width`.
struct NotePageReadOnlyView: View {
    let snapshot: NotePageSnapshot

    init(snapshot: NotePageSnapshot) {
        self.snapshot = snapshot
    }

    /// Lays out a stored note (`inkData` as stored).
    init(note: Note, inkData: Data?) {
        self.snapshot = NotePageRenderer.snapshot(note: note, inkData: inkData)
    }

    var body: some View {
        NotePageReadOnlyRepresentable(snapshot: snapshot)
            .aspectRatio(snapshot.size.width / max(snapshot.size.height, 1), contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.hasInk ? "Note with handwriting" : "Note")
            .accessibilityValue(snapshot.text)
    }
}

private struct NotePageReadOnlyRepresentable: UIViewRepresentable {
    let snapshot: NotePageSnapshot

    func makeUIView(context: Context) -> NotePageReadOnlyUIView {
        let view = NotePageReadOnlyUIView()
        view.snapshot = snapshot
        return view
    }

    func updateUIView(_ view: NotePageReadOnlyUIView, context: Context) {
        view.snapshot = snapshot
    }
}

/// Draws a `NotePageSnapshot` scaled to its bounds' width.
final class NotePageReadOnlyUIView: UIView {
    var snapshot: NotePageSnapshot? {
        didSet {
            inkImage = nil
            setNeedsDisplay()
        }
    }

    private var inkImage: (key: String, image: UIImage)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        overrideUserInterfaceStyle = NotePageStyle.pageAppearance
        backgroundColor = NotePageStyle.paperColor
        contentMode = .redraw
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (view: NotePageReadOnlyUIView, _: UITraitCollection) in
            view.inkImage = nil
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }


    override func draw(_ rect: CGRect) {
        guard let snapshot, let context = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        let factor = bounds.width / snapshot.size.width
        context.saveGState()
        context.scaleBy(x: factor, y: factor)
        NotePageLayoutEngine.shared.drawText(snapshot.text, in: context)
        if snapshot.hasInk {
            let page = CGRect(origin: .zero, size: snapshot.size)
            let scale = factor * contentScaleFactor
            let key = "\(scale)-\(traitCollection.userInterfaceStyle.rawValue)"
            if inkImage?.key != key {
                inkImage = (key, snapshot.drawing.image(from: page, scale: scale))
            }
            inkImage?.image.draw(in: page)
        }
        context.restoreGState()
    }
}
