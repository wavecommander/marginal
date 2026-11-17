import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

/// The records the app's Notebook debug seed writes (`NotebookDebugSeed.seed`), built without a
/// store: a 40-page book with no PDF outline, the reader's own headings, pages 1 and 2 as front
/// matter. Keep the two in step.
enum NotebookFeedFixture {
    static let bookID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
    static let inkedNoteText = "Why the determinant shows up. (A − λI)v = 0 needs a nonzero v, so A − λI has to flatten some direction to zero. That means singular, and singular means det = 0."

    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
    }

    static func seeded() -> Notebook {
        let id = bookID
        let ch3 = UserHeading(bookID: id, title: "3 Matrices and Linear Maps", pageIndex: 2, parent: nil, createdAt: date(1))
        let ch4 = UserHeading(bookID: id, title: "4 Determinants", pageIndex: 8, parent: nil, createdAt: date(2))
        let ch5 = UserHeading(bookID: id, title: "5 Eigenvalues and Eigenvectors", pageIndex: 14, parent: nil, createdAt: date(3))
        let s51 = UserHeading(bookID: id, title: "5.1 Invariant Directions", pageIndex: 15, parent: ch5.anchor, createdAt: date(4))
        let s52 = UserHeading(bookID: id, title: "5.2 The Characteristic Equation", pageIndex: 22, parent: ch5.anchor, createdAt: date(5))
        let ch6 = UserHeading(bookID: id, title: "6 Orthogonality", pageIndex: 30, parent: nil, createdAt: date(6))

        func note(_ target: NoteTarget, _ text: String, _ offset: TimeInterval, hasInk: Bool = false) -> Note {
            Note(bookID: id, target: target, text: text, hasInk: hasInk, createdAt: date(offset))
        }
        let notes = [
            note(.page(0), "Course plan: chapters 3 to 5 before the midterm, one section a day.", 10),
            note(.page(4), "Composition of maps is matrix multiplication, read right to left.", 11),
            note(.page(11), "Row operations: a swap flips the sign, scaling a row scales the determinant.", 12),
            note(.heading(ch5.anchor), "Everything in this chapter leans on Chapter 4: an eigenvalue is a number that makes A − λI singular. Reread 4.3 if 5.2 feels shaky.", 13),
            note(.heading(s51.anchor), "An eigenvector is a direction the map only stretches. A shear has just one such direction; a projection has eigenvalues 0 and 1.", 14),
            note(.page(16), "Figure 5.2 is the picture to remember: most arrows turn, two lines do not.", 15),
            note(.heading(s52.anchor), "Big idea. Eigenvalues are the roots of det(A − λI). A geometric question becomes an algebra problem.", 16),
            note(.page(22), "Motivation: guessing eigenvectors doesn't scale past 2 × 2.", 17),
            note(.page(27), "Triangular case: det is the product of the diagonal, so the roots are the diagonal entries.", 18),
            note(.page(24), inkedNoteText, 19, hasInk: true),
        ]

        func highlight(_ page: Int, _ color: HighlightColor, _ text: String, top: CGFloat, _ offset: TimeInterval) -> Highlight {
            Highlight(bookID: id, pageIndex: page, rects: [CGRect(x: 72, y: top, width: 300, height: 14)],
                      color: color, text: text, createdAt: date(offset))
        }
        let highlights = [
            highlight(3, .yellow, "A linear map is determined by what it does to a basis.", top: 600, 20),
            highlight(9, .green, "The determinant of a product is the product of the determinants.", top: 500, 21),
            highlight(18, .yellow, "An eigenvector is never the zero vector, but an eigenvalue may be zero.", top: 640, 22),
            highlight(24, .yellow, "A nonzero solution v exists exactly when the matrix A − λI is singular", top: 620, 23),
            highlight(24, .green, "an n × n matrix has at most n distinct eigenvalues", top: 400, 24),
            highlight(28, .blue, "The eigenvalues of a triangular matrix are the entries on its main diagonal.", top: 560, 25),
        ]
        let outline = Outline(pdfEntries: [], userHeadings: [ch3, ch4, ch5, s51, s52, ch6], pageCount: 40)
        return NotebookBuilder.build(outline: outline, notes: notes, highlights: highlights,
                                     bookmarks: [Bookmark(bookID: id, pageIndex: 19, createdAt: date(30))])
    }

    static func titles(_ rows: [NotebookFeedRow]) -> [String] {
        rows.compactMap { if case .header(let header) = $0.kind { header.title } else { nil } }
    }
}

/// `NotebookFeed`: grouping, type filter, search, scopes and filter-column entries.
struct NotebookFeedTests {
    typealias Support = NotebookFeedFixture

    @Test func sectionsSplitTheFeedAtEveryHeading() {
        let rows = NotebookFeed.rows(for: Support.seeded(), filter: NotebookFilter())
        let sections = NotebookFeed.sections(rows)
        // Every row once, in order.
        #expect(sections.flatMap { [$0.header].compactMap { $0 } + $0.rows } == rows)
        #expect(sections.allSatisfy { $0.header?.isHeader ?? false })
        #expect(sections.allSatisfy { !$0.rows.contains(where: \.isHeader) })
        #expect(sections.map { $0.header.map { Support.titles([$0]) } ?? [] }.flatMap { $0 } == Support.titles(rows))
        // "5 Eigenvalues and Eigenvectors" holds only its own note; 5.1 follows as its own section.
        let chapter = sections.first { Support.titles([$0.header!]) == ["5 Eigenvalues and Eigenvectors"] }
        #expect(chapter?.rows.count == 1)
        #expect(Set(sections.map(\.id)).count == sections.count)

        #expect(NotebookFeed.sections([]).isEmpty)
    }

    @Test func groupsUnderTheRightHeadings() throws {
        let notebook = Support.seeded()
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        #expect(Support.titles(rows) == ["Front matter", "3 Matrices and Linear Maps", "4 Determinants",
                                        "5 Eigenvalues and Eigenvectors", "5.1 Invariant Directions",
                                        "5.2 The Characteristic Equation"])
        // Under 5.2: its own note, then pages in order, each page's note before its highlights.
        let start = try #require(rows.firstIndex { Support.titles([$0]) == ["5.2 The Characteristic Equation"] })
        let kinds = rows[(start + 1)...].map { row -> String in
            switch row.kind {
            case .headingNote: "section"
            case .pageNote(_, let page): "note p\(page + 1)"
            case .highlight(let highlight, _): "\(highlight.color.rawValue) p\(highlight.pageIndex + 1)"
            default: "other"
            }
        }
        #expect(kinds == ["section", "note p23", "note p25", "yellow p25", "green p25", "note p28", "blue p29"])
        #expect(rows.first(where: { $0.note?.hasInk == true })?.targetPage == 24)
        // Bookmarks are not shown.
        #expect(!rows.contains { $0.targetPage == 19 })
    }

    /// The Notebook screen's rows, top to bottom, for the whole book and for one chapter's scope:
    /// what the screen lists is exactly this array. (This order used to be read off the screen
    /// by a UI test, `NotebookUITests.testSectionsGroupItemsUnderTheRightHeadings`.)
    @Test func rowsComeInTheOrderTheScreenListsThem() throws {
        let notebook = Support.seeded()
        func describe(_ row: NotebookFeedRow) -> String {
            switch row.kind {
            case .header(let header): "header \(header.title)"
            case .headingNote(_, let heading): "heading note \(heading.title)"
            case .unfiledHeadingNote(_, let title): "unfiled note \(title)"
            case .pageNote(_, let page): "note p\(page + 1)"
            case .highlight(let highlight, let index): "highlight p\(highlight.pageIndex + 1) #\(index)"
            case .handwriting(let page): "ink p\(page + 1)"
            }
        }
        // Front matter first, then chapter 3 with its highlight and note.
        let whole = NotebookFeed.rows(for: notebook, filter: NotebookFilter()).map(describe)
        #expect(Array(whole.prefix(5)) == ["header Front matter", "note p1", "header 3 Matrices and Linear Maps",
                                           "highlight p4 #0", "note p5"])

        // A chapter's scope: the chapter, its note, then each subsection with its note and pages.
        // Other chapters are not listed.
        let entries = NotebookFeed.scopeEntries(for: notebook)
        let chapter = try #require(entries.first { $0.title == "5 Eigenvalues and Eigenvectors" })
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: chapter.scope))
        #expect(rows.map(describe) == [
            "header 5 Eigenvalues and Eigenvectors", "heading note 5 Eigenvalues and Eigenvectors",
            "header 5.1 Invariant Directions", "heading note 5.1 Invariant Directions", "note p17", "highlight p19 #0",
            "header 5.2 The Characteristic Equation", "heading note 5.2 The Characteristic Equation", "note p23",
            "note p25", "highlight p25 #0", "highlight p25 #1", "note p28", "highlight p29 #0",
        ])
        // The chapter's header carries its pages, 15 to 30.
        guard case .header(let header) = try #require(rows.first).kind else {
            Issue.record("the scope's first row is its header")
            return
        }
        #expect(header.pageRange == 14...29)
        #expect(header.pageRangeLabel == "pp. 15\u{2013}30")
        #expect(header.startPage == 14)
    }

    @Test func headerCheckboxesStandForEverythingShownUnderThem() throws {
        let notebook = Support.seeded()
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        let byHeader = NotebookFeed.itemsByHeader(rows)
        #expect(Set(byHeader.keys) == Set(rows.filter(\.isHeader).map(\.id)))
        #expect(Set(NotebookFeed.items(in: rows)) == notebook.itemIDs)

        func header(_ title: String) throws -> String {
            try #require(rows.first { $0.isHeader && Support.titles([$0]) == [title] }).id
        }
        // A chapter's checkbox covers its subsections; a subsection's only its own rows.
        let chapter = try #require(byHeader[try header("5 Eigenvalues and Eigenvectors")])
        let first = try #require(byHeader[try header("5.1 Invariant Directions")])
        let second = try #require(byHeader[try header("5.2 The Characteristic Equation")])
        #expect(second.count == 7)
        #expect(!first.isEmpty)
        #expect(Set(chapter).isSuperset(of: first + second))
        #expect(Set(first).isDisjoint(with: second))
        #expect(Set(try #require(byHeader[try header("4 Determinants")])).isDisjoint(with: chapter))

        #expect(NotebookFeed.selectionState(of: second, in: []) == .none)
        #expect(NotebookFeed.selectionState(of: second, in: [second[0]]) == .some)
        #expect(NotebookFeed.selectionState(of: second, in: Set(second)) == .all)
        #expect(NotebookFeed.selectionState(of: chapter, in: Set(second)) == (chapter.count == second.count ? .all : .some))
    }

    @Test func typeFilterAndSearchNarrowTheFeed() throws {
        let notebook = Support.seeded()
        let highlights = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .highlights))
        #expect(highlights.filter { !$0.isHeader }.count == 6)
        #expect(highlights.allSatisfy { if case .highlight = $0.kind { true } else { $0.isHeader } })
        #expect(!Support.titles(highlights).contains("Front matter"))

        let sectionNotes = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .sectionNotes))
        #expect(sectionNotes.filter { !$0.isHeader }.count == 3)
        let pageNotes = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .pageNotes))
        #expect(pageNotes.filter { !$0.isHeader }.count == 7)

        // Case- and diacritic-insensitive search over notes and highlights.
        let search = NotebookFeed.rows(for: notebook, filter: NotebookFilter(query: "  DETERMINANT "))
        let matches = search.filter { !$0.isHeader }
        #expect(matches.count == 3)
        #expect(Support.titles(search) == ["4 Determinants", "5 Eigenvalues and Eigenvectors",
                                          "5.2 The Characteristic Equation"])
        #expect(NotebookFeed.rows(for: notebook, filter: NotebookFilter(query: "zzz-nothing")).isEmpty)
        let combined = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .highlights, query: "eigenvalue"))
        #expect(combined.filter { !$0.isHeader }.count == 3)
    }

    @Test func scopesAndFilterEntries() throws {
        let notebook = Support.seeded()
        let entries = NotebookFeed.scopeEntries(for: notebook)
        #expect(entries.map(\.title) == ["Whole book", "Front matter", "3 Matrices and Linear Maps", "4 Determinants",
                                         "5 Eigenvalues and Eigenvectors", "5.1 Invariant Directions",
                                         "5.2 The Characteristic Equation"])
        #expect(entries.map(\.count) == [16, 1, 2, 2, 11, 3, 7])
        #expect(entries.map(\.level) == [1, 1, 1, 1, 1, 2, 2])

        let s51 = try #require(entries.first { $0.title == "5.1 Invariant Directions" })
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: s51.scope))
        #expect(Support.titles(rows) == ["5.1 Invariant Directions"])
        #expect(rows.count == 4)
        let chapter = try #require(entries.first { $0.title == "5 Eigenvalues and Eigenvectors" })
        #expect(Support.titles(NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: chapter.scope)))
            == ["5 Eigenvalues and Eigenvectors", "5.1 Invariant Directions", "5.2 The Characteristic Equation"])
        let front = NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: .frontMatter))
        #expect(front.count == 2)
        #expect(front.last?.targetPage == 0)

        for entry in entries {
            #expect(NotebookScope(storageKey: entry.scope.storageKey) == entry.scope)
        }
    }

    @Test func unfiledNotesAreKept() throws {
        let bookID = UUID()
        let gone = HeadingAnchor(pdfPath: [3], pageIndex: 9, title: "Removed Heading")
        let notes = [Note(bookID: bookID, target: .heading(gone), text: "Orphan"),
                     Note(bookID: bookID, target: .page(99), text: "Off the end")]
        let notebook = NotebookBuilder.build(outline: Outline(pdfEntries: [], pageCount: 10), notes: notes, highlights: [])
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter())
        #expect(Support.titles(rows) == ["Unfiled notes"])
        #expect(rows.count == 3)
        #expect(NotebookFeed.scopeEntries(for: notebook).last?.count == 2)
        if case .unfiledHeadingNote(_, let title) = rows[1].kind {
            #expect(title == "Removed Heading")
        } else {
            Issue.record("expected an unfiled heading note")
        }
    }
}
