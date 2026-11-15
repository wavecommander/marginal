import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit

/// The bundled Quick Guide (docs/DESIGN.md, "First-run onboarding"): a six-page PDF that is
/// imported like any other book and arrives with a page note (with ink), a section note and a
/// highlight already in it. The PDF is written by `scripts/make-guide.swift`; the strings below
/// must match that script.
@MainActor
enum QuickGuide {
    /// The bundled file's name without its extension, which is also the book's title.
    static let title = "Tactile Texts Quick Guide"
    static let pageCount = 6

    static var bundledURL: URL? { Bundle.main.url(forResource: title, withExtension: "pdf") }

    /// Page 1's note. One paragraph per line; the first is underlined by the seeded ink.
    static let pageNoteText = """
        This is a page note
        Every page has one. Type here and it saves on its own.
        Section note, the other tab, is one note for the whole section this page is in.
        Tap Markup and the Pencil writes here too, over the words or in the space below.
        """

    /// The heading whose note is seeded, by its outline title.
    static let sectionNoteHeading = "2 Writing"
    static let sectionNoteText = "This note belongs to the whole of chapter 2, not to one page. Every heading can have a note like it."

    /// The sentence on page 2 that arrives highlighted.
    static let highlightedSentence = "A highlight keeps its words, so you can find them later."
    static let highlightPageIndex = 1

    enum Failure: Error {
        case missingFromBundle
    }

    /// Imports the guide (or finds the copy already in the Library) and returns it. Seeds its
    /// notes, ink and highlight only when the import created the book, so a copy the reader has
    /// edited is never overwritten; a deleted guide comes back as new.
    static func open(with service: ImportService, state: OnboardingState) async throws -> (book: Book, isNew: Bool) {
        guard let url = bundledURL else { throw Failure.missingFromBundle }
        switch try await service.importPDF(at: url) {
        case .imported(let book):
            state.guideBookID = book.id
            await seed(store: service.store, book: book)
            return (book, true)
        case .existing(let book):
            state.guideBookID = book.id
            return (book, false)
        case .awaitingConversion:
            // The guide is a PDF, so it never needs converting.
            throw Failure.missingFromBundle
        }
    }

    /// Writes the seeded content through the store, as the reader's own edits are written.
    /// Each part stands alone: one that fails is skipped, and the guide is still a usable book.
    static func seed(store: LibraryStore, book: Book) async {
        await seedPageNote(store: store, bookID: book.id)
        await seedSectionNote(store: store, book: book)
        seedHighlight(store: store, book: book)
    }

    // MARK: Parts

    private static func seedPageNote(store: LibraryStore, bookID: UUID) async {
        let model = NotePageModel(store: store, bookID: bookID, target: .page(0), origin: nil,
                                  autosaveDelay: .milliseconds(10))
        await model.load()
        model.userDidEditText(pageNoteText)
        let layout = NotePageLayoutEngine.shared.bandLayout(for: pageNoteText)
        let firstBaseline = (layout.paragraphs.first?.top ?? NotePageStyle.textInsets.top) + NotePageStyle.lineHeight
        let below = layout.trailingTop + 20
        let blue = UIColor(red: 0.12, green: 0.31, blue: 0.84, alpha: 1)
        let red = UIColor(red: 0.84, green: 0.15, blue: 0.24, alpha: 1)
        var drawing = model.displayInk()
        drawing.strokes += [
            // Underline "This is a page note".
            stroke([CGPoint(x: 14, y: firstBaseline - 1), CGPoint(x: 80, y: firstBaseline + 1),
                    CGPoint(x: 150, y: firstBaseline - 1)], color: red, width: 2.4),
            // In the space below the text: an arrow pointing up at the words, and a wavy line.
            stroke(curve(from: CGPoint(x: 70, y: below + 70), via: CGPoint(x: 120, y: below + 60),
                         to: CGPoint(x: 150, y: below + 6)), color: blue, width: 2.6),
            stroke([CGPoint(x: 134, y: below + 12), CGPoint(x: 150, y: below + 6), CGPoint(x: 156, y: below + 22)],
                   color: blue, width: 2.6),
            stroke(wave(from: CGPoint(x: 40, y: below + 100), length: 190), color: blue, width: 2.2),
        ]
        model.applyUserDrawing(drawing)
        await model.flush()
    }

    private static func seedSectionNote(store: LibraryStore, book: Book) async {
        let entries = await ReaderDocumentLoader.outlineEntries(at: store.documentURL(for: book))
        let outline = Outline(pdfEntries: entries, pageCount: book.pageCount)
        guard let heading = outline.nodes.first(where: { $0.title == sectionNoteHeading }) else { return }
        _ = try? store.notes.save(Note(bookID: book.id, target: .heading(heading.anchor), text: sectionNoteText))
    }

    private static func seedHighlight(store: LibraryStore, book: Book) {
        guard let document = PDFDocument(url: store.documentURL(for: book)),
              let page = document.page(at: highlightPageIndex),
              let selection = document.findString(highlightedSentence, withOptions: [])
                .first(where: { $0.pages.contains(page) }) else { return }
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        guard !rects.isEmpty else { return }
        try? store.highlights.save(Highlight(bookID: book.id, pageIndex: highlightPageIndex, rects: rects,
                                             color: .yellow, text: highlightedSentence))
    }

    // MARK: Ink

    private static func curve(from start: CGPoint, via control: CGPoint, to end: CGPoint) -> [CGPoint] {
        (0...12).map { index in
            let t = CGFloat(index) / 12
            let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
            return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
        }
    }

    private static func wave(from start: CGPoint, length: CGFloat) -> [CGPoint] {
        (0...24).map { index in
            let t = CGFloat(index) / 24
            return CGPoint(x: start.x + t * length, y: start.y + 5 * sin(t * 6 * .pi))
        }
    }

    /// A pen stroke through `points`, densified so PencilKit draws it smoothly.
    private static func stroke(_ points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        var dense: [CGPoint] = []
        for (index, point) in points.enumerated() {
            guard index > 0 else { dense.append(point); continue }
            let previous = points[index - 1]
            for step in 1...6 {
                let t = CGFloat(step) / 6
                dense.append(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t))
            }
        }
        let controlPoints = dense.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.01,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
    }
}
