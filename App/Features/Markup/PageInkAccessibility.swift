import UIKit

/// Tells VoiceOver (and UI tests) which displayed pages have handwriting.
///
/// PDFKit gives each page view its own accessibility elements (the page's text) and does not
/// expose subviews of a page view, so the ink overlays themselves are invisible to
/// accessibility (verified on iOS 27.2). This view sits on top of the PDF view, takes no touches
/// (`isUserInteractionEnabled = false`, so hit-testing skips it) and draws nothing; its
/// elements, one per displayed page with ink, are computed when asked: label "Handwriting on
/// page N", value "k strokes", trait image, framed on the strokes wherever the page is now
/// (scroll and zoom included). VoiceOver reaches them after the visible pages' text.
final class PageInkAccessibilityView: UIView {
    /// The surfaces of the displayed pages, by page.
    var surfaces: () -> [Int: PageInkSurface] = { [:] }
    private var elements: [Int: PageInkAccessibilityElement] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityIdentifier = "pageInk.accessibility"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityElements: [Any]? {
        get {
            var result: [PageInkAccessibilityElement] = []
            var kept: [Int: PageInkAccessibilityElement] = [:]
            for (pageIndex, surface) in surfaces().sorted(by: { $0.key < $1.key }) where surface.strokeCount > 0 {
                let element = elements[pageIndex].flatMap { $0.surface === surface ? $0 : nil }
                    ?? PageInkAccessibilityElement(container: self, surface: surface)
                kept[pageIndex] = element
                result.append(element)
            }
            elements = kept
            return result
        }
        set {}
    }

    /// The ink of some page changed: let VoiceOver re-read the elements.
    func inkDidChange() {
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}

/// The handwriting on one displayed page.
final class PageInkAccessibilityElement: UIAccessibilityElement {
    weak var surface: PageInkSurface?

    init(container: Any, surface: PageInkSurface) {
        self.surface = surface
        super.init(accessibilityContainer: container)
        accessibilityTraits = .image
        accessibilityIdentifier = PageInkAccessibilityID.ink(surface.pageIndex + 1)
        accessibilityLabel = "Handwriting on page \(surface.pageIndex + 1)"
    }

    override var accessibilityValue: String? {
        get {
            let count = surface?.strokeCount ?? 0
            return count == 1 ? "1 stroke" : "\(count) strokes"
        }
        set {}
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let canvas = surface?.canvas, canvas.window != nil else { return .zero }
            let bounds = canvas.drawing.bounds
            guard !bounds.isNull, !bounds.isEmpty else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(bounds, in: canvas)
        }
        set {}
    }
}
