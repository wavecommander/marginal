#if DEBUG
import Foundation
import PencilKit
import ReaderCore
import UIKit

/// DEBUG-only seeding for UI tests and screenshots (read from the process arguments here, not
/// through `LaunchOptions`, so the shell is untouched; fold into `LaunchOptions` later).
///
/// - `-seedNotebook`: when a Notebook first appears, after the launch's fixture import, seeds its
///   book (once per process; skipped if the book already has notes) with a deterministic set
///   modelled on the mockup. Designed for `no-outline.pdf` (40 pages), so the outline is made of
///   user headings and pages 1–2 are front matter:
///   - user headings "3 Matrices and Linear Maps" (p. 3), "4 Determinants" (p. 9),
///     "5 Eigenvalues and Eigenvectors" (p. 15) with "5.1 Invariant Directions" (p. 16) and
///     "5.2 The Characteristic Equation" (p. 23), and an empty "6 Orthogonality" (p. 31);
///   - page notes on pp. 1 (front matter), 5, 12, 17, 23, 28; heading notes on 5, 5.1 and 5.2;
///   - a page note on p. 25 with **ink** (pen and marker strokes made programmatically and saved
///     through `NotePageModel`, i.e. exactly the note page's persisted format);
///   - highlights: p. 4 yellow, p. 10 green, p. 19 yellow, p. 25 yellow and green, p. 29 blue;
///   - a bookmark on p. 20 (not shown in the Notebook).
/// - `-notebookDebugWidth <points>`: the Notebook lays itself out at most this wide (narrow-width
///   screenshots on a simulator, which cannot resize windows).
/// - `-seedNotebookLateNote`: also adds a page note on p. 33 ("Added while the Notebook was
///   open.", under the until-then empty "6 Orthogonality") about four seconds after seeding,
///   through the store, to exercise live updates.
@MainActor
enum NotebookDebugSeed {
    static let argument = "-seedNotebook"
    static let lateNoteArgument = "-seedNotebookLateNote"
    static let lateNoteText = "Added while the Notebook was open."

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-notebookDebugWidth <points>`: the Notebook lays itself out at most this wide.
    static let debugWidth: CGFloat? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-notebookDebugWidth"), index + 1 < arguments.count,
              let value = Double(arguments[index + 1]), value > 0 else { return nil }
        return CGFloat(value)
    }()
    static var isLateNoteRequested: Bool { ProcessInfo.processInfo.arguments.contains(lateNoteArgument) }

    private static var seeded = Set<UUID>()

    static func seedIfNeeded(store: LibraryStore, bookID: UUID) async {
        guard !seeded.contains(bookID) else { return }
        seeded.insert(bookID)
        guard let book = try? store.books.book(id: bookID),
              ((try? store.notes.noteCount(bookID: bookID)) ?? 0) == 0 else { return }
        do {
            try await seed(store: store, book: book)
        } catch {
            print("NotebookDebugSeed: \(error)")
        }
        if isLateNoteRequested {
            Task {
                try? await Task.sleep(for: .seconds(4))
                _ = try? store.notes.save(Note(bookID: bookID, target: .page(32), text: lateNoteText,
                                               createdAt: date(100)))
            }
        }
    }

    /// Fixed timestamps keep the seed deterministic.
    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
    }

    static func seed(store: LibraryStore, book: Book) async throws {
        let id = book.id
        let ch3 = UserHeading(bookID: id, title: "3 Matrices and Linear Maps", pageIndex: 2, parent: nil, createdAt: date(1))
        let ch4 = UserHeading(bookID: id, title: "4 Determinants", pageIndex: 8, parent: nil, createdAt: date(2))
        let ch5 = UserHeading(bookID: id, title: "5 Eigenvalues and Eigenvectors", pageIndex: 14, parent: nil, createdAt: date(3))
        let s51 = UserHeading(bookID: id, title: "5.1 Invariant Directions", pageIndex: 15, parent: ch5.anchor, createdAt: date(4))
        let s52 = UserHeading(bookID: id, title: "5.2 The Characteristic Equation", pageIndex: 22, parent: ch5.anchor, createdAt: date(5))
        let ch6 = UserHeading(bookID: id, title: "6 Orthogonality", pageIndex: 30, parent: nil, createdAt: date(6))
        for heading in [ch3, ch4, ch5, s51, s52, ch6] { try store.headings.save(heading) }

        func note(_ target: NoteTarget, _ text: String, _ offset: TimeInterval) throws {
            _ = try store.notes.save(Note(bookID: id, target: target, text: text, createdAt: date(offset)))
        }
        try note(.page(0), "Course plan: chapters 3 to 5 before the midterm, one section a day.", 10)
        try note(.page(4), "Composition of maps is matrix multiplication, read right to left.", 11)
        try note(.page(11), "Row operations: a swap flips the sign, scaling a row scales the determinant.", 12)
        try note(.heading(ch5.anchor), "Everything in this chapter leans on Chapter 4: an eigenvalue is a number that makes A − λI singular. Reread 4.3 if 5.2 feels shaky.", 13)
        try note(.heading(s51.anchor), "An eigenvector is a direction the map only stretches. A shear has just one such direction; a projection has eigenvalues 0 and 1.", 14)
        try note(.page(16), "Figure 5.2 is the picture to remember: most arrows turn, two lines do not.", 15)
        try note(.heading(s52.anchor), "Big idea. Eigenvalues are the roots of det(A − λI). A geometric question becomes an algebra problem.", 16)
        try note(.page(22), "Motivation: guessing eigenvectors doesn't scale past 2 × 2.", 17)
        try note(.page(27), "Triangular case: det is the product of the diagonal, so the roots are the diagonal entries.", 18)

        func highlight(_ page: Int, _ color: HighlightColor, _ text: String, top: CGFloat, _ offset: TimeInterval) throws {
            try store.highlights.save(Highlight(bookID: id, pageIndex: page,
                                                rects: [CGRect(x: 72, y: top, width: 300, height: 14)],
                                                color: color, text: text, createdAt: date(offset)))
        }
        try highlight(3, .yellow, "A linear map is determined by what it does to a basis.", top: 600, 20)
        try highlight(9, .green, "The determinant of a product is the product of the determinants.", top: 500, 21)
        try highlight(18, .yellow, "An eigenvector is never the zero vector, but an eigenvalue may be zero.", top: 640, 22)
        try highlight(24, .yellow, "A nonzero solution v exists exactly when the matrix A − λI is singular", top: 620, 23)
        try highlight(24, .green, "an n × n matrix has at most n distinct eigenvalues", top: 400, 24)
        try highlight(28, .blue, "The eigenvalues of a triangular matrix are the entries on its main diagonal.", top: 560, 25)
        try store.bookmarks.setBookmarked(true, bookID: id, pageIndex: 19)

        try await inkedNote(store: store, bookID: id, pageIndex: 24)
    }

    /// The inked note on p. 25: typed text, a pen underline and circle over the text, and a small
    /// sketch (axes and two lines) in the writing space below, saved through `NotePageModel`.
    static let inkedNoteText = "Why the determinant shows up. (A − λI)v = 0 needs a nonzero v, so A − λI has to flatten some direction to zero. That means singular, and singular means det = 0."

    static func inkedNote(store: LibraryStore, bookID: UUID, pageIndex: Int) async throws {
        let model = NotePageModel(store: store, bookID: bookID, target: .page(pageIndex), origin: nil,
                                  autosaveDelay: .milliseconds(10))
        await model.load()
        model.userDidEditText(inkedNoteText)
        let layout = NotePageLayoutEngine.shared.bandLayout(for: inkedNoteText)
        let firstLine = (layout.paragraphs.first?.top ?? NotePageStyle.textInsets.top) + NotePageStyle.lineHeight
        let base = layout.trailingTop + 24
        let blue = UIColor(red: 0.12, green: 0.31, blue: 0.84, alpha: 1)
        let red = UIColor(red: 0.84, green: 0.15, blue: 0.24, alpha: 1)
        let ink = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        var drawing = model.displayInk()
        drawing.strokes += [
            // Underline "Why the determinant shows up."
            stroke([CGPoint(x: 14, y: firstLine - 2), CGPoint(x: 208, y: firstLine)], color: blue, width: 2.5, seconds: 1),
            // Axes.
            stroke([CGPoint(x: 40, y: base + 100), CGPoint(x: 262, y: base + 98)], color: ink, width: 2, seconds: 2),
            stroke([CGPoint(x: 150, y: base + 112), CGPoint(x: 151, y: base)], color: ink, width: 2, seconds: 3),
            // The two invariant lines.
            stroke(curve(from: CGPoint(x: 92, y: base + 110), via: CGPoint(x: 150, y: base + 60),
                         to: CGPoint(x: 214, y: base + 4)), color: blue, width: 3.5, seconds: 4),
            stroke(curve(from: CGPoint(x: 96, y: base + 6), via: CGPoint(x: 150, y: base + 58),
                         to: CGPoint(x: 204, y: base + 110)), color: red, width: 3.5, seconds: 5),
            // A marker swipe over the third line.
            stroke([CGPoint(x: 150, y: firstLine + 2 * NotePageStyle.lineHeight - 8),
                    CGPoint(x: 230, y: firstLine + 2 * NotePageStyle.lineHeight - 8)],
                   inkType: .marker, color: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 0.5), width: 14, seconds: 6),
        ]
        model.applyUserDrawing(drawing)
        await model.flush()
    }

    private static func curve(from start: CGPoint, via control: CGPoint, to end: CGPoint) -> [CGPoint] {
        (0...12).map { index in
            let t = CGFloat(index) / 12
            let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
            return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
        }
    }

    /// A stroke through `points` (densified), with a fixed creation date.
    private static func stroke(_ points: [CGPoint], inkType: PKInk.InkType = .pen, color: UIColor, width: CGFloat,
                               seconds: TimeInterval) -> PKStroke {
        var dense: [CGPoint] = []
        for (index, point) in points.enumerated() {
            guard index > 0 else { dense.append(point); continue }
            let previous = points[index - 1]
            for step in 1...8 {
                let t = CGFloat(step) / 8
                dense.append(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t))
            }
        }
        let controlPoints = dense.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.01,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: date(1000 + seconds))
        return PKStroke(ink: PKInk(inkType, color: color), path: path)
    }
}
#endif
