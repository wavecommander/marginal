import ReaderCore
import UIKit

/// Builds `NoteBandLayout`s from real TextKit 2 layout, and draws note text.
///
/// **Band rule.** One band per element of `NoteBandLayout.paragraphs(of: text)`. A band's top is
/// the top of its paragraph's first line fragment; bands tile (a band runs to the next band's
/// top, so it includes its paragraph spacing); the last band ends at the bottom of its last
/// line. `trailingTop` is the last band's bottom. All values are note-page coordinates (text
/// container coordinates plus `textContainerInset.top`). A paragraph TextKit gives no line
/// fragment for (the empty document, or the empty paragraph after a final newline on systems
/// that do not report an extra line fragment) gets a synthesised line of
/// `NotePageStyle.lineHeight` directly below the previous paragraph.
@MainActor
enum NotePageTextLayout {
    /// The band layout of the text currently in `textView` (a note-page text view, see
    /// `NotePageStyle.configure`). Forces layout of the whole document. Never touches
    /// `layoutManager` (that would drop the text view to TextKit 1).
    static func bandLayout(of textView: UITextView) -> NoteBandLayout {
        let text = textView.text ?? ""
        let paragraphs = NoteBandLayout.paragraphs(of: text)
        let starts = paragraphStartOffsets(of: text)
        let insetTop = textView.textContainerInset.top

        // Line fragments in document order: (UTF-16 start offset, top, bottom) in page space.
        var lines: [(start: Int, top: CGFloat, bottom: CGFloat)] = []
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            let documentStart = content.documentRange.location
            layoutManager.ensureLayout(for: content.documentRange)
            layoutManager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
                let fragmentStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
                let frame = fragment.layoutFragmentFrame
                for line in fragment.textLineFragments {
                    let bounds = line.typographicBounds
                    lines.append((fragmentStart + line.characterRange.location,
                                  frame.minY + bounds.minY + insetTop,
                                  frame.minY + bounds.maxY + insetTop))
                }
                return true
            }
        }

        // First line top and last line bottom per paragraph.
        var tops = [CGFloat?](repeating: nil, count: paragraphs.count)
        var bottoms = [CGFloat?](repeating: nil, count: paragraphs.count)
        var paragraph = 0
        for line in lines {
            while paragraph + 1 < starts.count && line.start >= starts[paragraph + 1] { paragraph += 1 }
            if tops[paragraph] == nil { tops[paragraph] = line.top }
            bottoms[paragraph] = max(bottoms[paragraph] ?? line.bottom, line.bottom)
        }
        var previousBottom = insetTop
        for index in paragraphs.indices {
            if tops[index] == nil {
                let top = index == 0 ? insetTop : previousBottom + NotePageStyle.paragraphSpacing
                tops[index] = top
                bottoms[index] = top + NotePageStyle.lineHeight
            }
            previousBottom = bottoms[index] ?? previousBottom
        }

        var bands: [NoteParagraphBand] = []
        bands.reserveCapacity(paragraphs.count)
        for index in paragraphs.indices {
            let top = tops[index]!
            let bottom: CGFloat
            if index + 1 < paragraphs.count {
                bottom = max(tops[index + 1]!, top)
            } else {
                bottom = max(bottoms[index]!, top)
            }
            bands.append(NoteParagraphBand(text: paragraphs[index], top: top, height: bottom - top))
        }
        return NoteBandLayout(pageWidth: NotePageStyle.pageWidth, paragraphs: bands,
                              trailingTop: bands.last?.bottom ?? insetTop)
    }

    /// UTF-16 offsets at which each element of `NoteBandLayout.paragraphs(of:)` starts.
    static func paragraphStartOffsets(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for character in text {
            offset += character.utf16.count
            if character == "\n" || character == "\r\n" || character == "\r" || character == "\u{2029}" {
                starts.append(offset)
            }
        }
        return starts
    }

    /// Draws the text view's text into `context` (UIKit orientation, y down) at note-page
    /// coordinates, as vector glyphs (TextKit 2 layout fragments). Colours resolve against the
    /// current trait collection: wrap in `performAsCurrent` to choose an appearance.
    static func drawText(of textView: UITextView, in context: CGContext) {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager else { return }
        let inset = textView.textContainerInset
        layoutManager.ensureLayout(for: content.documentRange)
        layoutManager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            fragment.draw(at: CGPoint(x: origin.x + inset.left, y: origin.y + inset.top), in: context)
            return true
        }
    }
}

/// An off-screen note-page text view for laying out and drawing notes that are not open in an
/// editor (read-only views, exports, and a model whose editor has gone). It is configured exactly
/// like the editor's text view, so its band layouts match the editor's.
@MainActor
final class NotePageLayoutEngine {
    static let shared = NotePageLayoutEngine()

    private let textView: UITextView

    init() {
        textView = UITextView(usingTextLayoutManager: true)
        NotePageStyle.configure(textView)
        textView.frame = CGRect(x: 0, y: 0, width: NotePageStyle.pageWidth, height: 10_000)
    }

    /// Loads `text` into the engine's text view (no-op if already loaded).
    private func load(_ text: String) {
        if textView.text != text {
            textView.attributedText = NotePageStyle.attributedText(text)
        }
    }

    /// The band layout of `text` on a note page.
    func bandLayout(for text: String) -> NoteBandLayout {
        load(text)
        return NotePageTextLayout.bandLayout(of: textView)
    }

    /// Draws `text` at note-page coordinates (see `NotePageTextLayout.drawText`).
    func drawText(_ text: String, in context: CGContext) {
        load(text)
        NotePageTextLayout.drawText(of: textView, in: context)
    }
}
