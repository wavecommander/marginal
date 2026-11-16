import Foundation

/// How lists and exports show a highlight: "Highlights on this page", the Notebook, the
/// Markdown export and the Notebook PDF all follow it.
public enum HighlightPresentation: Hashable, Sendable {
    /// A highlight on a page with a text layer: its text, whitespace collapsed (as the Markdown
    /// export quotes it).
    case text(String)
    /// A scanned-page highlight: a crop of the page under the highlight's rects (rendered by the
    /// app from the PDF page), with the stored text, whitespace collapsed, as a caption when
    /// there is any. The crop is what is trusted, so a formula or a misread word still shows
    /// correctly.
    case crop(caption: String?)

    /// The words that stand for a scanned-page highlight with no caption.
    public static let uncaptionedCropLabel = "Highlight on a scanned page"

    /// The caption of a crop, or the text of a text highlight; `nil` for a crop with no caption.
    public var caption: String? {
        switch self {
        case .text(let text): text
        case .crop(let caption): caption
        }
    }
}

extension Highlight {
    /// How lists and exports show this highlight: a crop with an optional caption for a
    /// scanned-page highlight (`isOnScannedPage`), otherwise its text.
    public var presentation: HighlightPresentation {
        let collapsed = OutlineText.normalizedTitle(text)
        guard isOnScannedPage else { return .text(collapsed) }
        return .crop(caption: collapsed.isEmpty ? nil : collapsed)
    }
}
