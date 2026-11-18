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

    // MARK: Appearance (design: "The notes pane follows the system appearance")

    /// The paper colour of the note page **on screen**: white in Light Mode, a dark grey in Dark
    /// Mode (one step above the panel's black background, so the page still reads as paper). It
    /// is dynamic, so the editor and the read-only views follow the trait collection they are in
    /// and switch live with the system setting.
    ///
    /// Ink follows the same trait collection through PencilKit's own light/dark rendering: a
    /// `PKCanvasView` and `PKDrawing.image(from:scale:)` (inside `UITraitCollection.performAsCurrent`)
    /// draw each stroke's stored colour converted for the appearance, the same conversion as
    /// `PKInkingTool.convertColor(_:from:to:)` (dark colours lighten: black shows white, dark blue
    /// shows light blue; light colours darken; saturated yellow stays yellow). The stored strokes
    /// never change. Verified on the iOS 27 simulator (`NotePageAppearanceTests`).
    static let paperColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? darkPaperColor : exportPaperColor
    }

    /// The Dark Mode paper (`secondarySystemBackground` in Dark Mode, fixed so it does not change
    /// with the elevated or high-contrast variants).
    static let darkPaperColor = UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)

    /// The appearance of every export (Markdown images, the Notebook PDF): always light, on white
    /// paper, with the strokes' stored colours, whatever the app's appearance.
    static let exportAppearance: UIUserInterfaceStyle = .light
    /// The paper colour of exports (and of the page in Light Mode).
    static let exportPaperColor = UIColor.white
    /// The trait collection exports draw in (`exportAppearance`).
    static var exportTraits: UITraitCollection { UITraitCollection(userInterfaceStyle: exportAppearance) }

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

    /// Attributes of all note text. The colour is dynamic (`.label`), so it follows the
    /// appearance on screen (dark text on white paper, light text on dark paper); exports draw it
    /// inside `exportTraits` (`performAsCurrent`), so it is always dark there.
    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: UIColor.label]
    }

    /// Custom attribute keys used to round-trip code and semantic highlight colours losslessly.
    static let codeAttributeKey = NSAttributedString.Key("software.tactile.texts.noteCode")
    static let highlightAttributeKey = NSAttributedString.Key("software.tactile.texts.noteHighlight")

    /// Dynamic highlight background colour for a `NoteTextHighlightColor`.
    static func highlightUIColor(for color: NoteTextHighlightColor) -> UIColor {
        switch color {
        case .yellow:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.55, green: 0.45, blue: 0.08, alpha: 0.55)
                    : UIColor(red: 1.0, green: 0.92, blue: 0.35, alpha: 0.55)
            }
        case .green:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.14, green: 0.48, blue: 0.24, alpha: 0.50)
                    : UIColor(red: 0.55, green: 0.92, blue: 0.62, alpha: 0.45)
            }
        case .blue:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.14, green: 0.36, blue: 0.62, alpha: 0.55)
                    : UIColor(red: 0.58, green: 0.82, blue: 1.0, alpha: 0.45)
            }
        case .pink:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.58, green: 0.18, blue: 0.36, alpha: 0.52)
                    : UIColor(red: 1.0, green: 0.68, blue: 0.80, alpha: 0.45)
            }
        }
    }

    /// Note font for inline attributes, always at `fontSize` so `lineHeight` stays fixed.
    static func font(for attributes: NoteTextAttributes) -> UIFont {
        let weight: UIFont.Weight = attributes.isBold ? .bold : .regular
        let base: UIFont = attributes.isCode
            ? .monospacedSystemFont(ofSize: fontSize, weight: weight)
            : .systemFont(ofSize: fontSize, weight: weight)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if attributes.isBold { traits.insert(.traitBold) }
        if attributes.isItalic { traits.insert(.traitItalic) }
        if attributes.isCode { traits.insert(.traitMonoSpace) }
        guard !traits.isEmpty,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: fontSize)
    }

    /// UIKit attributes dictionary for a `NoteTextAttributes` value.
    static func uiAttributes(for attributes: NoteTextAttributes) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font(for: attributes),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label
        ]
        if attributes.isUnderline {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if attributes.isStrikethrough {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if attributes.isCode {
            result[codeAttributeKey] = true
        }
        if let highlight = attributes.highlight {
            result[highlightAttributeKey] = highlight.rawValue
            result[.backgroundColor] = highlightUIColor(for: highlight)
        }
        return result
    }

    /// Extracts `NoteTextAttributes` from a UIKit attribute dictionary.
    static func noteAttributes(from uiAttributes: [NSAttributedString.Key: Any]) -> NoteTextAttributes {
        let font = uiAttributes[.font] as? UIFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let isBold = traits.contains(.traitBold)
        let isItalic = traits.contains(.traitItalic)
        let isUnderline = (uiAttributes[.underlineStyle] as? Int ?? 0) != 0
        let isStrikethrough = (uiAttributes[.strikethroughStyle] as? Int ?? 0) != 0
        let isCode = (uiAttributes[codeAttributeKey] as? Bool == true) || traits.contains(.traitMonoSpace)
        let highlight = (uiAttributes[highlightAttributeKey] as? String).flatMap(NoteTextHighlightColor.init(rawValue:))
        return NoteTextAttributes(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline,
                                  isStrikethrough: isStrikethrough, isCode: isCode, highlight: highlight)
    }

    /// Note text as an attributed string with the note attributes and optional inline formatting.
    static func attributedText(_ text: String, richTextData: Data? = nil) -> NSAttributedString {
        let mutable = NSMutableAttributedString(string: text, attributes: textAttributes)
        guard let richText = NoteRichText.decoded(from: richTextData) else { return mutable }
        let clamped = richText.clamped(toUTF16Length: mutable.length)
        for span in clamped.spans {
            mutable.setAttributes(uiAttributes(for: span.attributes),
                                  range: NSRange(location: span.location, length: span.length))
        }
        return mutable
    }

    /// Serialises inline formatting spans from an attributed string; `nil` when all text is plain.
    static func extractRichTextData(from attributedString: NSAttributedString) -> Data? {
        let length = attributedString.length
        guard length > 0 else { return nil }
        var spans: [NoteTextSpan] = []
        attributedString.enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { attrs, range, _ in
            let noteAttrs = noteAttributes(from: attrs)
            if !noteAttrs.isDefault {
                spans.append(NoteTextSpan(location: range.location, length: range.length, attributes: noteAttrs))
            }
        }
        return NoteRichText(spans: spans).encoded()
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
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = false
        textView.smartInsertDeleteType = .default
        textView.dataDetectorTypes = []
    }
}
