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
    /// The note page's size at 100%: `NotePageStyle.pageWidth` wide, or as wide as its ink reaches
    /// when that is further (ink written in a widened notes pane), and tall enough for the text
    /// and the ink plus a margin (no blank writing room). The text is always wrapped at
    /// `NotePageStyle.pageWidth`.
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
        let hasInk = !bounds.isNull && !drawing.strokes.isEmpty
        let inkBottom = hasInk ? bounds.maxY + NotePageStyle.renderBottomMargin : 0
        // Ink written in a widened notes pane can lie to the right of the default page; the page
        // grows to hold it, so no view or export of the note cuts it off.
        let inkRight = hasInk ? bounds.maxX : 0
        return CGSize(width: ceil(max(NotePageStyle.pageWidth, inkRight)), height: ceil(max(textBottom, inkBottom)))
    }

    // MARK: Bitmap (Markdown export, and the on-screen read-only view)

    /// PNG of the whole note (text and ink) for export: always the light appearance on white
    /// paper with the strokes' stored colours, whatever the app's appearance. `width` points wide
    /// (default: the page width) at `scale` pixels per point (default 3).
    static func pngData(note: Note, inkData: Data?, scale: CGFloat = 3, width: CGFloat? = nil) -> Data? {
        pngData(snapshot(note: note, inkData: inkData), scale: scale, width: width)
    }

    static func pngData(_ snapshot: NotePageSnapshot, scale: CGFloat = 3, width: CGFloat? = nil) -> Data? {
        image(snapshot, scale: scale, width: width).pngData()
    }

    /// The note as an image (see `pngData`). Its `size` is in points. `appearance` is
    /// `NotePageStyle.exportAppearance` (light) unless a caller asks for the on-screen look of
    /// another appearance; exports never pass it.
    static func image(_ snapshot: NotePageSnapshot, scale: CGFloat = 3, width: CGFloat? = nil,
                      appearance: UIUserInterfaceStyle = NotePageStyle.exportAppearance) -> UIImage {
        let factor = (width ?? snapshot.size.width) / snapshot.size.width
        let size = CGSize(width: snapshot.size.width * factor, height: snapshot.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let traits = UITraitCollection(userInterfaceStyle: appearance)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawPage(snapshot, in: context.cgContext, factor: factor, inkScale: scale * factor, traits: traits,
                     paper: size)
        }
    }

    /// Draws the page (paper, text, ink) scaled by `factor`, everything resolved in `traits`
    /// (made current for the duration, so the dynamic paper and `.label` text resolve in it and
    /// PencilKit renders the ink for its user interface style). `paper` is the area to fill with
    /// the paper colour, in the context's points (`nil`: no fill).
    static func drawPage(_ snapshot: NotePageSnapshot, in context: CGContext, factor: CGFloat, inkScale: CGFloat,
                         traits: UITraitCollection, paper: CGSize?, cachedInk: UIImage? = nil) {
        traits.performAsCurrent {
            if let paper {
                context.setFillColor(NotePageStyle.paperColor.resolvedColor(with: traits).cgColor)
                context.fill(CGRect(origin: .zero, size: paper))
            }
            context.saveGState()
            context.scaleBy(x: factor, y: factor)
            NotePageLayoutEngine.shared.drawText(snapshot.text, in: context)
            if snapshot.hasInk {
                let page = CGRect(origin: .zero, size: snapshot.size)
                let ink = cachedInk ?? inkImage(snapshot, scale: inkScale, traits: traits)
                UIGraphicsPushContext(context)
                ink.draw(in: page)
                UIGraphicsPopContext()
            }
            context.restoreGState()
        }
    }

    /// The note's ink alone as a transparent image of the page at `scale`, rendered by PencilKit
    /// for `traits`' user interface style (light: the stored colours; dark: PencilKit's dark
    /// rendering of them). Never changes the strokes.
    static func inkImage(_ snapshot: NotePageSnapshot, scale: CGFloat, traits: UITraitCollection) -> UIImage {
        var image = UIImage()
        traits.performAsCurrent {
            image = snapshot.drawing.image(from: CGRect(origin: .zero, size: snapshot.size), scale: scale)
        }
        return image
    }

    // MARK: Vector (PDF export)

    /// Draws the note (text as glyphs, ink as vector paths where the ink allows; see the type
    /// documentation) into `context` in the light appearance (`NotePageStyle.exportTraits`,
    /// whatever the app's appearance: this is the export path), with its top-left at `origin`,
    /// `width` points wide (default: the page width). `context` must be in UIKit orientation
    /// (y down), as in `UIGraphicsPDFRenderer`; flip a raw Core Graphics PDF context first.
    /// Paints no background. - Returns: the size drawn, in the context's points.
    @discardableResult
    static func draw(_ snapshot: NotePageSnapshot, in context: CGContext, at origin: CGPoint = .zero,
                     width: CGFloat? = nil) -> CGSize {
        let factor = (width ?? snapshot.size.width) / snapshot.size.width
        NotePageStyle.exportTraits.performAsCurrent {
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
            let color = stroke.ink.color.resolvedColor(with: NotePageStyle.exportTraits)
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
            // Called inside `exportTraits.performAsCurrent`, so PencilKit renders the stored colour.
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
/// changes, never a scaled bitmap). Follows the appearance like the editor: dark paper, light
/// text and PencilKit's dark ink rendering in Dark Mode, re-drawn live when the appearance
/// changes (the ink image is cached per scale and appearance). Its height is
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

    /// The ink rendered for one scale and appearance (re-rendered from the strokes when either
    /// changes, so a live appearance switch never shows the other appearance's ink).
    private var inkImage: (key: InkImageKey, image: UIImage)?

    struct InkImageKey: Equatable {
        var scale: CGFloat
        var style: UIUserInterfaceStyle
    }

    /// The appearance the view last drew in (tests).
    private(set) var renderedStyle: UIUserInterfaceStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
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
        let traits = traitCollection
        let scale = factor * contentScaleFactor
        var ink: UIImage?
        if snapshot.hasInk {
            let key = InkImageKey(scale: scale, style: traits.userInterfaceStyle)
            if inkImage?.key != key {
                inkImage = (key, NotePageRenderer.inkImage(snapshot, scale: scale, traits: traits))
            }
            ink = inkImage?.image
        }
        // The background colour (dynamic paper) is the paper; draw text and ink over it.
        NotePageRenderer.drawPage(snapshot, in: context, factor: factor, inkScale: scale, traits: traits,
                                  paper: nil, cachedInk: ink)
        renderedStyle = traits.userInterfaceStyle
    }
}
