import ReaderCore
import UIKit

/// The fixed geometry and typography of a note page (design: "Note page", "Note text").
///
/// Every place a note appears (the editor, read-only views, exports) uses these values, so a note
/// is laid out identically everywhere and only ever *scaled*, never re-wrapped. Changing any value
/// here moves typed text relative to stored ink for existing notes; the band layout absorbs it
/// (`NoteBands.relocate` on load), but keep changes deliberate.
nonisolated enum NotePageStyle {
    /// Logical width of the note page in points at 100% zoom.
    static let pageWidth: CGFloat = 320
    /// Insets of the text inside the page (page coordinates).
    static let textInsets = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    /// Point size of the note text. Fixed: Dynamic Type sets the default zoom instead.
    static let fontSize: CGFloat = 15
    /// Fixed line height (minimum = maximum), so line positions do not depend on font metrics.
    static let lineHeight: CGFloat = 22
    /// Space after each paragraph.
    static let paragraphSpacing: CGFloat = 6
    /// Blank drawing space always kept below the text (page points).
    static let minimumWritingRoom: CGFloat = 220
    /// Blank space kept below the lowest stroke, so the page grows as it is drawn in.
    static let inkGrowthRoom: CGFloat = 220
    /// Space below the lowest text or ink in read-only renderings.
    static let renderBottomMargin: CGFloat = 14
    /// Zoom range of the editor (1 = 100%).
    static let zoomRange: ClosedRange<CGFloat> = 1...2

    /// The appearance of the note page itself (paper, text and ink). **Always light**, like the
    /// PDF page beside it: on the installed SDK PencilKit does not adapt stroke colours to dark
    /// mode on this canvas (black ink stays black on a dark page, both on a transparent or
    /// opaque `PKCanvasView` and in `PKDrawing.image` under a dark trait collection — verified on
    /// the iOS 27.0 simulator), so a dark page would hide the reader's ink. The panel around the
    /// page follows the system appearance. Exports are light as well.
    static let pageAppearance: UIUserInterfaceStyle = .light
    /// The paper colour of the note page.
    static var paperColor: UIColor { .white }

    /// The text font (system, regular, fixed size).
    static var font: UIFont { UIFont.systemFont(ofSize: fontSize) }

    /// The paragraph style of note text.
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Attributes of all note text. The colour is dynamic (`.label`), so it follows dark mode on
    /// screen; renderers resolve it in a light trait collection for exports.
    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: UIColor.label]
    }

    /// Note text as an attributed string with the note attributes.
    static func attributedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: textAttributes)
    }

    /// The default zoom for a content size category: Dynamic Type scales the note page rather
    /// than its font. `.large` (the system default) is 100%; larger sizes zoom in, up to 200%.
    static func defaultZoom(for category: UIContentSizeCategory) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
        return clampZoom(scaled / 17)
    }

    /// Clamps a zoom factor to `zoomRange`.
    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// Configures a text view as a note-page text view (the editor and the off-screen layout
    /// engine use this, so both lay out identically).
    @MainActor
    static func configure(_ textView: UITextView) {
        textView.isScrollEnabled = false
        textView.textContainerInset = textInsets
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.font = font
        textView.typingAttributes = textAttributes
        textView.allowsEditingTextAttributes = false
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = false
        textView.smartInsertDeleteType = .default
        textView.dataDetectorTypes = []
    }
}
