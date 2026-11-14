import CoreGraphics
import PDFKit

/// The coordinate space page ink is stored in, and its mapping to PDFKit page space.
///
/// ## Ink space (what every stored `PKDrawing` of a page is in)
/// The page **as the reader sees it upright**: the page's **crop box** (PDFKit's default display
/// box, the visible page) with the page's own `/Rotate` applied, one unit = one PDF point,
/// origin at the **top-left** of the visible page, y down: the page as it appears on screen at
/// 100%, so a canvas in this space is upright on screen (see `inkToOverlay`). It depends only on the PDF (never modified; principle 1), not on the
/// zoom, the window size or the display box, so ink stays registered to the page content at
/// every zoom level, after resizes and rotation of the device, on pages of different sizes, and
/// on rotated or cropped pages.
///
/// ## Page space
/// PDFKit page space: points, origin at the lower-left of the media box, y up, unrotated (the
/// space of `PDFPage.bounds(for:)`, `PDFSelection.bounds(for:)` and stored highlight rects). Use
/// `inkToPage` to place ink on the page itself (annotated PDF export).
nonisolated struct PageInkGeometry: Equatable, Sendable {
    /// The crop box in page space.
    var cropBox: CGRect
    /// The page's rotation in degrees clockwise: 0, 90, 180 or 270.
    var rotation: Int

    init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox.standardized
        self.rotation = Self.normalized(rotation)
    }

    /// The geometry of a PDFKit page (crop box and rotation).
    init(page: PDFPage) {
        self.init(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    /// The size of ink space: the crop box's size, swapped for 90° and 270°.
    var size: CGSize {
        rotation % 180 == 0 ? cropBox.size : CGSize(width: cropBox.height, height: cropBox.width)
    }

    /// Ink space as a rect (origin zero).
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// Page space → ink space.
    var pageToInk: CGAffineTransform {
        Self.pageToUpright(box: cropBox, rotation: rotation)
    }

    /// Ink space → page space.
    var inkToPage: CGAffineTransform { pageToInk.inverted() }

    /// Ink space → the space of the page's PDFKit overlay view when the PDF view shows
    /// `displayBox` (a rect in page space; the crop box by default).
    ///
    /// Verified on iOS 27.2: PDFKit sizes the overlay to the display box **unrotated** (top-left
    /// origin, y down) and shows a rotated page by rotating the overlay view itself; zoom scales
    /// an ancestor (`PDFDocumentView`), never the overlay's bounds. So for a rotated page this
    /// transform contains the inverse rotation, which keeps the canvas upright on screen.
    func inkToOverlay(displayBox: CGRect) -> CGAffineTransform {
        let box = displayBox.standardized
        let pageToOverlay = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        return Self.snapped(inkToPage.concatenating(pageToOverlay))
    }

    /// The size of the overlay's space for `displayBox` (the box unrotated).
    static func overlaySize(displayBox: CGRect) -> CGSize { displayBox.standardized.size }

    // MARK: Private

    /// Rounds coefficients within 1e-9 of 0 or ±1 (rotations computed through inversion).
    private static func snapped(_ t: CGAffineTransform) -> CGAffineTransform {
        func snap(_ value: CGFloat) -> CGFloat {
            for target in [0, 1, -1] as [CGFloat] where abs(value - target) < 1e-9 { return target }
            return value
        }
        return CGAffineTransform(a: snap(t.a), b: snap(t.b), c: snap(t.c), d: snap(t.d),
                                 tx: (t.tx * 1e6).rounded() / 1e6, ty: (t.ty * 1e6).rounded() / 1e6)
    }

    private static func normalized(_ degrees: Int) -> Int {
        let quarter = ((degrees % 360) + 360) % 360
        return (quarter / 90) * 90
    }

    /// Maps page space to the upright, y-down space of `box` displayed with `rotation`.
    ///
    /// With `u = x − box.minX` and `v = box.maxY − y` (the unrotated page, top-left origin,
    /// y down; width `w`, height `h`), rotating the displayed page clockwise gives:
    /// 0°: `(u, v)`; 90°: `(h − v, u)`; 180°: `(w − u, h − v)`; 270°: `(v, w − u)`.
    private static func pageToUpright(box: CGRect, rotation: Int) -> CGAffineTransform {
        let w = box.width, h = box.height
        // Page → (u, v): u = x − minX, v = maxY − y.
        let toUV = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        let rotate: CGAffineTransform
        switch normalized(rotation) {
        case 90: rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)      // (h − v, u)
        case 180: rotate = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)    // (w − u, h − v)
        case 270: rotate = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)     // (v, w − u)
        default: rotate = .identity
        }
        return toUV.concatenating(rotate)
    }
}
