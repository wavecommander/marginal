import CoreText
import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit

/// Writes a Notebook as a PDF: the faithful export format.
///
/// **Layout** (same order as the Markdown export): the book title and counts; "Front matter";
/// every heading with content, depth first (title, page range and a rule; level 1 large with a
/// heavy rule); under a heading its own note (labelled "Chapter"/"Section"), then its pages, each
/// item labelled with its page ("p. 312"): the page note, then the page's highlights (colour
/// swatch and the quoted text in a serif face), then, for a page with page ink, "Handwriting" and
/// the book page with its ink (`drawInkedPage`); finally "Unfiled notes". A running footer carries
/// the book title and the PDF page number. Page size: US Letter where the locale measures in
/// US units, A4 elsewhere; 54 pt margins.
///
/// **Notes** are drawn with `NotePageRenderer.draw` at 100% (the note page's 320 pt width, text
/// at its own 15 pt), exactly as they look in the app: text as glyphs (searchable), ink as
/// vector paths for pen, marker and monoline strokes, a per-stroke high-resolution image for
/// textured inks (the renderer decides; see `NotePageRenderer`).
///
/// **Pagination.** A note that does not fit in the rest of the page starts on the next page if
/// it fits on a page. A note taller than a page is never scaled down: it starts on the current
/// page (or the next, when less than three lines' worth of room is left) and continues on the
/// following pages, cut between two text lines
/// (the last paragraph or line boundary that fits; below the text, anywhere), each part clipped,
/// so a stroke crossing the cut is drawn in both parts. Cuts prefer paragraph boundaries, and each
/// part draws only the paragraphs it shows, so the PDF's text holds every line once (a single
/// paragraph taller than a page is cut between lines and its text is present, clipped, in both
/// parts). Headers stay with at least the start of
/// what follows them. Highlight text wraps and breaks between lines.
///
/// **Memory.** The PDF context streams pages to the file; each note's ink is loaded, laid out,
/// drawn and released before the next (`autoreleasepool`), so memory stays flat for hundreds of
/// notes. Main actor (the note renderer is), yielding after every item.
@MainActor
final class NotebookPDFWriter {
    static var defaultPageSize: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    let pageSize: CGSize
    private let context: CGContext
    private let bookTitle: String
    private let margin: CGFloat = 54
    private let labelColumn: CGFloat = 64
    private let footerHeight: CGFloat = 22
    private var y: CGFloat = 0
    private var pageNumber = 0
    private var isPageOpen = false
    private var isClosed = false
    private var bookPages: BookPages?

    private var contentTop: CGFloat { margin }
    private var contentBottom: CGFloat { pageSize.height - margin - footerHeight }
    private var contentWidth: CGFloat { pageSize.width - 2 * margin }
    private var bodyX: CGFloat { margin + labelColumn }
    private var bodyWidth: CGFloat { contentWidth - labelColumn }
    private var atPageTop: Bool { y <= contentTop + 0.5 }

    init(url: URL, bookTitle: String, pageSize: CGSize = NotebookPDFWriter.defaultPageSize) throws {
        self.pageSize = pageSize
        self.bookTitle = OutlineText.normalizedTitle(bookTitle)
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "\(self.bookTitle) Notebook",
            kCGPDFContextCreator: "Tactile Texts",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.context = context
    }

    /// The book's pages and their ink, for the pages with handwriting.
    struct BookPages {
        /// The book (a private instance; the writer draws its pages on the main actor).
        let document: PDFDocument?
        /// The page's stored ink (`nil`: none any more, the page is skipped).
        let loadInk: @MainActor (Int) async -> Data?
    }

    /// Writes the whole notebook and closes the file.
    /// - Parameters:
    ///   - loadInk: the stored ink of a note (`nil` for none); called only for notes with ink.
    ///   - bookPages: the book's pages and page ink, for pages with handwriting (`nil`: such
    ///     pages are left out).
    ///   - progress: fractions in `0..<1` as items are drawn.
    /// - Throws: `CancellationError` when the task is cancelled (the file is closed, not removed;
    ///   the caller removes it).
    func write(_ notebook: Notebook, loadInk: @escaping @MainActor (Note) async -> Data?,
               bookPages: BookPages? = nil, progress: @escaping @MainActor (Double) -> Void) async throws {
        self.bookPages = bookPages
        let total = max(1, notebook.totalCounts.items)
        var done = 0
        let step: @MainActor () async throws -> Void = {
            done += 1
            progress(min(0.99, Double(done) / Double(total)))
            try Task.checkCancellation()
            await Task.yield()
        }

        beginPage()
        drawTitleBlock(notebook)
        if NotebookFeed.itemCount(notebook) == 0 {
            drawText(NSAttributedString(string: "No notes, highlights or handwriting yet.", attributes: Self.attributes(size: 12, color: .secondaryLabel)),
                     x: margin, width: contentWidth)
        }

        if notebook.frontMatter.contains(where: Self.isExportable) {
            drawHeader(title: "Front matter", level: 1, range: nil)
            for page in notebook.frontMatter { try await drawPage(page, loadInk: loadInk, step: step) }
        }
        for section in notebook.sectionsWithContent {
            try await drawSection(section, loadInk: loadInk, step: step)
        }
        let unfiledPages = notebook.orphanPages.filter(Self.isExportable)
        if !notebook.orphanNotes.isEmpty || !unfiledPages.isEmpty {
            drawHeader(title: "Unfiled notes", level: 1, range: nil)
            for note in notebook.orphanNotes {
                drawHeader(title: NotebookFeed.unfiledTitle(note), level: 2, range: nil)
                try await drawNote(note, label: "Section", loadInk: loadInk)
                try await step()
            }
            for page in unfiledPages { try await drawPage(page, loadInk: loadInk, step: step) }
        }
        close()
    }

    /// Ends the open page and closes the file (idempotent).
    func close() {
        guard !isClosed else { return }
        if isPageOpen { endPage() }
        context.closePDF()
        isClosed = true
    }

    // MARK: Structure

    private static func isExportable(_ page: NotebookPage) -> Bool { page.hasContent }

    private func drawSection(_ section: NotebookSection, loadInk: @escaping @MainActor (Note) async -> Data?,
                             step: @MainActor () async throws -> Void) async throws {
        drawHeader(title: section.title, level: section.level, range: section.pageRange)
        if let note = section.note {
            try await drawNote(note, label: NotebookFeed.headingNoteLabel(level: section.level), loadInk: loadInk)
            try await step()
        }
        for page in section.pages { try await drawPage(page, loadInk: loadInk, step: step) }
        for child in section.children { try await drawSection(child, loadInk: loadInk, step: step) }
    }

    private func drawPage(_ page: NotebookPage, loadInk: @escaping @MainActor (Note) async -> Data?,
                          step: @MainActor () async throws -> Void) async throws {
        let label = PageNumbering.label(forPageIndex: page.pageIndex)
        if let note = page.note {
            try await drawNote(note, label: label, loadInk: loadInk)
            try await step()
        }
        for highlight in page.highlights {
            drawHighlight(highlight, label: label)
            try await step()
        }
        if page.hasInk {
            try await drawInkedPage(page.pageIndex, label: label)
            try await step()
        }
    }

    // MARK: Pages

    private func beginPage() {
        context.beginPDFPage(nil)
        context.saveGState()
        // UIKit orientation (y down), as `NotePageRenderer.draw` requires.
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        pageNumber += 1
        isPageOpen = true
        y = contentTop
    }

    private func endPage() {
        let footerAttributes = Self.attributes(size: 8.5, color: .secondaryLabel)
        let baseline = pageSize.height - margin + 4
        if let line = lines(NSAttributedString(string: "\(bookTitle) · Notebook", attributes: footerAttributes),
                            width: contentWidth - 60).first {
            draw(line.line, x: margin, baseline: baseline)
        }
        let number = lines(NSAttributedString(string: "\(pageNumber)", attributes: footerAttributes), width: 60)
        if let line = number.first {
            draw(line.line, x: pageSize.width - margin - line.width, baseline: baseline)
        }
        context.restoreGState()
        context.endPDFPage()
        isPageOpen = false
    }

    private func newPage() {
        endPage()
        beginPage()
    }

    /// Starts a new page unless `height` fits below the cursor (or the cursor is at the top).
    private func ensureRoom(_ height: CGFloat) {
        if y + height > contentBottom, !atPageTop { newPage() }
    }

    // MARK: Blocks

    private func drawTitleBlock(_ notebook: Notebook) {
        drawText(NSAttributedString(string: bookTitle, attributes: Self.attributes(size: 22, weight: .bold)),
                 x: margin, width: contentWidth)
        y += 2
        let notes = notebook.totalCounts.notes, highlights = notebook.totalCounts.highlights
        let inked = notebook.totalCounts.inkedPages
        var counts = "Notebook · \(notes) \(notes == 1 ? "note" : "notes") · \(highlights) \(highlights == 1 ? "highlight" : "highlights")"
        if inked > 0 { counts += " · \(inked) \(inked == 1 ? "page" : "pages") of handwriting" }
        drawText(NSAttributedString(string: counts, attributes: Self.attributes(size: 11, color: .secondaryLabel)),
                 x: margin, width: contentWidth)
        y += 6
        rule(weight: 1.5, color: .label)
        y += 4
    }

    private func drawHeader(title: String, level: Int, range: ClosedRange<Int>?) {
        let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 13.5 : 12)
        let spaceBefore: CGFloat = level <= 1 ? 18 : 10
        let rangeText = range.map(PageNumbering.label(forPageRange:)) ?? ""
        let rangeLines = rangeText.isEmpty ? [] :
            lines(NSAttributedString(string: rangeText, attributes: Self.attributes(size: 10, color: .secondaryLabel)), width: 140)
        let rangeWidth = rangeLines.first.map { $0.width + 12 } ?? 0
        let titleLines = lines(NSAttributedString(string: title, attributes: Self.attributes(size: size, weight: level <= 2 ? .bold : .semibold)),
                               width: contentWidth - rangeWidth)
        let titleHeight = titleLines.reduce(0) { $0 + $1.height }
        // Keep the header with the start of what follows it.
        ensureRoom(spaceBefore + titleHeight + 8 + 60)
        if !atPageTop { y += spaceBefore }
        var firstBaseline: CGFloat?
        for line in titleLines {
            draw(line.line, x: margin, baseline: y + line.ascent)
            if firstBaseline == nil { firstBaseline = y + line.ascent }
            y += line.height
        }
        if let rangeLine = rangeLines.first, let baseline = firstBaseline {
            draw(rangeLine.line, x: margin + contentWidth - rangeLine.width, baseline: baseline)
        }
        y += 3
        rule(weight: level <= 1 ? 1 : 0.5, color: level <= 1 ? .label : .separator)
        y += 8
    }

    private func drawNote(_ note: Note, label: String, loadInk: @MainActor (Note) async -> Data?) async throws {
        let ink = note.hasInk ? await loadInk(note) : nil
        try Task.checkCancellation()
        autoreleasepool {
            let snapshot = NotePageRenderer.snapshot(note: note, inkData: ink)
            drawSnapshot(snapshot, label: label)
        }
    }

    private func drawSnapshot(_ snapshot: NotePageSnapshot, label: String) {
        let width = min(bodyWidth, NotePageStyle.pageWidth)
        let scale = width / snapshot.size.width
        let height = snapshot.size.height * scale
        let minimumSlice = min(height, (NotePageStyle.lineHeight * 3 + NotePageStyle.textInsets.top) * scale)
        var sliceTop: CGFloat = 0  // in note-page points
        var labelDrawn = false
        while sliceTop < snapshot.size.height - 0.5 {
            let room = contentBottom - y
            let remaining = (snapshot.size.height - sliceTop) * scale
            let fitsOnAFreshPage = sliceTop == 0 && height <= contentBottom - contentTop
            if remaining > room, room < minimumSlice || fitsOnAFreshPage, !atPageTop {
                newPage()
                continue
            }
            let sliceBottom = remaining <= room
                ? snapshot.size.height
                : bestCut(in: snapshot, from: sliceTop, limit: sliceTop + room / scale)
            let rect = CGRect(x: bodyX, y: y, width: width, height: (sliceBottom - sliceTop) * scale)
            if !labelDrawn {
                drawLabel(label, top: y + 6)
                labelDrawn = true
            }
            if sliceTop == 0, sliceBottom >= snapshot.size.height {
                NotePageRenderer.draw(snapshot, in: context, at: CGPoint(x: bodyX, y: y), width: width)
            } else {
                drawSlice(of: snapshot, from: sliceTop, to: sliceBottom, in: rect, width: width)
            }
            context.saveGState()
            context.setStrokeColor(UIColor(white: 0.82, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.stroke(rect.insetBy(dx: 0.25, dy: 0.25))
            context.restoreGState()
            y = rect.maxY
            sliceTop = sliceBottom
            if sliceTop < snapshot.size.height - 0.5 { newPage() }
        }
        y += 12
    }

    /// Where to end a slice of a note that does not fit, in note-page points: the lowest
    /// paragraph boundary in `(top + one line) ... limit`; failing that (one paragraph taller than
    /// the room) the lowest line boundary; below the text, `limit`; `limit` when nothing fits.
    private func bestCut(in snapshot: NotePageSnapshot, from top: CGFloat, limit: CGFloat) -> CGFloat {
        let layout = snapshot.layout
        if limit >= layout.trailingTop { return limit }
        let lineHeight = NotePageStyle.lineHeight
        let usable: (CGFloat) -> Bool = { $0 > top + lineHeight && $0 <= limit }
        if let boundary = layout.paragraphs.map(\.bottom).filter(usable).max() { return boundary }
        var best: CGFloat?
        for band in layout.paragraphs {
            var position = band.top
            while position <= band.bottom + 0.5 {
                if usable(position) { best = max(best ?? position, position) }
                position += lineHeight
            }
        }
        return best ?? limit
    }

    /// Draws note-page points `top..<bottom` of a note into `rect`. The text is drawn from only
    /// the paragraphs the slice touches (laid out exactly as in the whole note: paragraphs wrap
    /// independently at the fixed page width), so text cut at a paragraph boundary is not also
    /// present, clipped away, on the other page; the ink is the whole drawing, clipped.
    private func drawSlice(of snapshot: NotePageSnapshot, from top: CGFloat, to bottom: CGFloat, in rect: CGRect,
                           width: CGFloat) {
        let scale = width / snapshot.size.width
        let origin = CGPoint(x: rect.minX, y: rect.minY - top * scale)
        context.saveGState()
        context.clip(to: rect)
        let bands = snapshot.layout.paragraphs
        let paragraphs = NoteBandLayout.paragraphs(of: snapshot.text)
        let touched = bands.indices.filter { bands[$0].top < bottom - 0.01 && bands[$0].bottom > top + 0.01 }
        if paragraphs.count == bands.count, let first = touched.first, let last = touched.last {
            let text = paragraphs[first...last].joined(separator: "\n")
            let shift = bands[first].top - NotePageStyle.textInsets.top
            let textOnly = NotePageSnapshot(text: text, layout: snapshot.layout, drawing: PKDrawing(),
                                            size: snapshot.size, inkUnreadable: false)
            NotePageRenderer.draw(textOnly, in: context, at: CGPoint(x: origin.x, y: origin.y + shift * scale), width: width)
        } else if paragraphs.count != bands.count {
            let textOnly = NotePageSnapshot(text: snapshot.text, layout: snapshot.layout, drawing: PKDrawing(),
                                            size: snapshot.size, inkUnreadable: false)
            NotePageRenderer.draw(textOnly, in: context, at: origin, width: width)
        }
        if snapshot.hasInk {
            let inkOnly = NotePageSnapshot(text: "", layout: snapshot.layout, drawing: snapshot.drawing,
                                           size: snapshot.size, inkUnreadable: false)
            NotePageRenderer.draw(inkOnly, in: context, at: origin, width: width)
        }
        context.restoreGState()
    }

    private func drawHighlight(_ highlight: Highlight, label: String) {
        let text = "\u{201C}\(OutlineText.normalizedTitle(highlight.text))\u{201D}"
        let font = UIFont(name: "Georgia", size: 11.5) ?? UIFont.systemFont(ofSize: 11.5)
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.cgColor(.label),
        ])
        let swatch: CGFloat = 9
        let textX = bodyX + swatch + 8
        let textLines = lines(string, width: bodyWidth - swatch - 8)
        ensureRoom(min(textLines.reduce(0) { $0 + $1.height }, (textLines.first?.height ?? 14) * 2))
        var first = true
        for line in textLines {
            if y + line.height > contentBottom, !atPageTop { newPage() }
            if first {
                drawLabel(label, top: y + 1)
                let color = Self.highlightColor(highlight.color)
                let box = CGRect(x: bodyX, y: y + line.ascent - swatch, width: swatch, height: swatch)
                context.saveGState()
                context.setFillColor(color.cgColor)
                context.fill(box)
                context.setStrokeColor(UIColor(white: 0, alpha: 0.35).cgColor)
                context.setLineWidth(0.5)
                context.stroke(box)
                context.restoreGState()
                first = false
            }
            draw(line.line, x: textX, baseline: y + line.ascent)
            y += line.height
        }
        y += 8
    }

    /// A page with handwriting: "Handwriting" and the book page with its ink, on white, up to
    /// 300 pt wide (scaled down to fit one page; never split). The page is drawn as the PDF draws
    /// it (vector, `BookPageDrawing`), the ink with `PageInkRenderer.draw` (vector paths where the
    /// ink allows, a high-resolution image per textured stroke), colours as stored. A page whose
    /// ink is gone by now is skipped.
    private func drawInkedPage(_ pageIndex: Int, label: String) async throws {
        guard let bookPages, let data = await bookPages.loadInk(pageIndex) else { return }
        try Task.checkCancellation()
        autoreleasepool {
            guard let drawing = try? PKDrawing(data: data) else { return }
            let page = bookPages.document?.page(at: pageIndex)
            let geometry = page.map { PageInkGeometry(page: $0) }
                ?? PageInkGeometry(cropBox: CGRect(origin: .zero, size: Self.defaultPageSize), rotation: 0)
            let size = geometry.size
            guard size.width > 0, size.height > 0 else { return }
            let caption = lines(NSAttributedString(string: "Handwriting",
                                                   attributes: Self.attributes(size: 9.5, weight: .semibold, color: .secondaryLabel)),
                                width: bodyWidth)
            let captionHeight = caption.reduce(0) { $0 + $1.height } + 3
            var width = min(bodyWidth, 300)
            var height = width * size.height / size.width
            let room = contentBottom - contentTop - captionHeight
            if height > room {
                height = room
                width = height * size.width / size.height
            }
            ensureRoom(captionHeight + height)
            drawLabel(label, top: y + 1)
            for line in caption {
                draw(line.line, x: bodyX, baseline: y + line.ascent)
                y += line.height
            }
            y += 3
            let rect = CGRect(x: bodyX, y: y, width: width, height: height)
            context.saveGState()
            context.setFillColor(UIColor.white.cgColor)
            context.fill(rect)
            context.restoreGState()
            if let page { BookPageDrawing.draw(page, geometry: geometry, in: context, target: rect) }
            PageInkRenderer.draw(drawing, geometry: geometry, in: context, target: rect)
            context.saveGState()
            context.setStrokeColor(UIColor(white: 0.82, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.stroke(rect.insetBy(dx: 0.25, dy: 0.25))
            context.restoreGState()
            y = rect.maxY + 12
        }
    }

    private func drawLabel(_ label: String, top: CGFloat) {
        let string = NSAttributedString(string: label, attributes: Self.attributes(size: 9.5, weight: .semibold, color: .secondaryLabel))
        guard let line = lines(string, width: labelColumn - 8).first else { return }
        draw(line.line, x: margin, baseline: top + line.ascent)
    }

    /// Draws wrapped text at the cursor, breaking pages between lines.
    private func drawText(_ string: NSAttributedString, x: CGFloat, width: CGFloat) {
        for line in lines(string, width: width) {
            if y + line.height > contentBottom, !atPageTop { newPage() }
            draw(line.line, x: x, baseline: y + line.ascent)
            y += line.height
        }
    }

    private func rule(weight: CGFloat, color: UIColor) {
        context.saveGState()
        context.setFillColor(Self.cgColor(color))
        context.fill(CGRect(x: margin, y: y, width: contentWidth, height: weight))
        context.restoreGState()
        y += weight
    }

    // MARK: Core Text

    private struct TextLine {
        let line: CTLine
        let ascent: CGFloat
        let height: CGFloat
        let width: CGFloat
    }

    private func lines(_ string: NSAttributedString, width: CGFloat) -> [TextLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var result: [TextLine] = []
        var start = 0
        while start < string.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(width, 10)))
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            result.append(TextLine(line: line, ascent: ascent, height: ceil((ascent + descent) * 1.25 + leading),
                                   width: lineWidth - trailing))
            start += count
        }
        return result
    }

    private func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func attributes(size: CGFloat, weight: UIFont.Weight = .regular,
                                   color: UIColor = .label) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: size, weight: weight),
         NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color)]
    }

    /// A colour resolved in the light appearance (exports are always light).
    private static func cgColor(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
    }

    private static func highlightColor(_ color: HighlightColor) -> UIColor {
        switch color {
        case .yellow: UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
        case .green: UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: UIColor(red: 0.35, green: 0.68, blue: 1.0, alpha: 1)
        case .pink: UIColor(red: 1.0, green: 0.42, blue: 0.62, alpha: 1)
        }
    }
}
