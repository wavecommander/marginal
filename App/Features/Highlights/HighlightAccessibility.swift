import PDFKit
import ReaderCore
import UIKit

/// Accessibility identifiers of highlights (UI tests mirror these strings).
nonisolated enum HighlightAccessibilityID {
    /// The container laid over the PDF view.
    static let container = "reader.highlights"
    /// Highlight `index` (zero-based, reading order) on 1-based page `page`:
    /// `reader.highlight.<page>.<index>`.
    static func highlight(page: Int, index: Int) -> String { "reader.highlight.\(page).\(index)" }
    /// Prefix of every highlight element on 1-based page `page`.
    static func pagePrefix(_ page: Int) -> String { "reader.highlight.\(page)." }
}

/// Tells VoiceOver (and UI tests) which displayed pages have highlights, and what they say.
///
/// PDFKit does not expose subviews or annotations of its page views to accessibility, and the
/// shell limits the PDF view's accessibility children to the visible page views, so anything
/// added inside the PDF view is invisible. This view is therefore a **sibling** laid over the
/// PDF view in its host (re-installed if the shell re-hosts the PDF view). It takes no touches
/// (`isUserInteractionEnabled = false`, so hit-testing passes through) and draws nothing.
///
/// One element per highlight on the displayed pages, in reading order, after the page text:
/// label "Yellow highlight, page 3" ("Yellow highlight on a scanned page, page 17" for a
/// scanned-page highlight), value the highlighted text (a scanned-page highlight with none:
/// "Highlight on a scanned page, page 17"), trait button, framed on the
/// highlight wherever the page is now. Activating it opens the same menu a tap does; its custom
/// actions recolour, copy and delete without the menu. In markup mode (display-only) the
/// elements are read but offer no actions.
final class HighlightAccessibilityView: UIView {
    /// The highlights shown, by page, and how to frame and act on them (set by the controller).
    weak var controller: HighlightController?
    private var elements: [UUID: HighlightAccessibilityElement] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityIdentifier = HighlightAccessibilityID.container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityElements: [Any]? {
        get {
            guard let controller else { return [] }
            var result: [HighlightAccessibilityElement] = []
            var kept: [UUID: HighlightAccessibilityElement] = [:]
            for (pageIndex, highlights) in controller.displayedHighlights.sorted(by: { $0.key < $1.key }) {
                for (index, highlight) in highlights.enumerated() {
                    let element = elements[highlight.id] ?? HighlightAccessibilityElement(container: self)
                    element.update(highlight: highlight, index: index, pageIndex: pageIndex, controller: controller)
                    kept[highlight.id] = element
                    result.append(element)
                }
            }
            elements = kept
            return result
        }
        set {}
    }

    /// The displayed highlights changed: let VoiceOver re-read the elements.
    func highlightsDidChange() {
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}

/// One highlight on a displayed page.
final class HighlightAccessibilityElement: UIAccessibilityElement {
    private(set) var highlight: Highlight?
    private weak var controller: HighlightController?

    init(container: Any) {
        super.init(accessibilityContainer: container)
        accessibilityTraits = .button
    }

    func update(highlight: Highlight, index: Int, pageIndex: Int, controller: HighlightController) {
        self.highlight = highlight
        self.controller = controller
        let page = pageIndex + 1
        accessibilityIdentifier = HighlightAccessibilityID.highlight(page: page, index: index)
        // A scanned-page highlight says so: its text is what Live Text read, and may be empty.
        let kind = highlight.isOnScannedPage ? " highlight on a scanned page" : " highlight"
        accessibilityLabel = "\(HighlightPalette.name(highlight.color))\(kind), page \(page)"
        accessibilityValue = highlight.isOnScannedPage ? HighlightCropLabels.spokenText(highlight) : highlight.text
        guard controller.isInteractive else {
            // Markup mode: display-only.
            accessibilityHint = nil
            accessibilityCustomActions = nil
            return
        }
        accessibilityHint = "Shows options to recolour, copy or delete."
        accessibilityCustomActions = HighlightColor.allCases.filter { $0 != highlight.color }.map { color in
            UIAccessibilityCustomAction(name: "Make \(HighlightPalette.name(color))") { [weak controller] _ in
                controller?.recolor(highlightID: highlight.id, to: color)
                return true
            }
        } + [
            UIAccessibilityCustomAction(name: "Copy Text") { [weak controller] _ in
                controller?.copyText(highlightID: highlight.id)
                return true
            },
            UIAccessibilityCustomAction(name: "Delete Highlight") { [weak controller] _ in
                controller?.delete(highlightID: highlight.id)
                return true
            },
        ]
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let highlight, let frame = controller?.viewFrame(of: highlight),
                  let view = controller?.pdfViewIfLoaded else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(frame, in: view)
        }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard let highlight, let controller, controller.isInteractive else { return false }
        return controller.presentMenu(for: highlight)
    }
}
