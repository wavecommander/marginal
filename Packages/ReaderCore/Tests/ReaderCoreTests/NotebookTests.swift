import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

/// A small seeded book shared by the Notebook and Markdown tests.
struct SeededBook {
    let outline = Outline(pdfEntries: [
        e("Ch1 Vectors", 1, 10), e("1.1 Addition", 2, 10), e("1.2 Scaling", 2, 20),
        e("Ch2 Matrices", 1, 40), e("2.1 Products", 2, 50),
    ], pageCount: 100)

    var ch1: OutlineNode { outline.titled("Ch1 Vectors") }
    var s11: OutlineNode { outline.titled("1.1 Addition") }
    var s12: OutlineNode { outline.titled("1.2 Scaling") }
    var ch2: OutlineNode { outline.titled("Ch2 Matrices") }
    var s21: OutlineNode { outline.titled("2.1 Products") }

    /// 2.1's anchor as an older edition recorded it (title changed since).
    let staleS21 = HeadingAnchor(pdfPath: [1, 0], pageIndex: 50, title: "2.1 Multiplication")
    let goneAnchor = HeadingAnchor(pdfPath: [5], pageIndex: 80, title: "Old heading")

    func note(_ n: Int, _ target: NoteTarget, _ text: String, ink: Bool = false) -> Note {
        Note(id: uuid(n), bookID: bookA, target: target, text: text, hasInk: ink, createdAt: fixedDate)
    }

    func highlight(_ n: Int, page: Int, y: CGFloat, _ text: String) -> Highlight {
        Highlight(id: uuid(n), bookID: bookA, pageIndex: page, rects: [CGRect(x: 72, y: y, width: 200, height: 12)],
                  color: .yellow, text: text, createdAt: fixedDate)
    }

    var notes: [Note] {
        [
            note(3, .page(3), "Front note"),
            note(12, .page(12), "Remember: v + w  \r\n\r\n- commutative  \n", ink: true),
            note(45, .page(45), "Matrix note"),
            note(101, .heading(ch1.anchor), "\nChapter summary\n"),
            note(121, .heading(staleS21), "", ink: true),
            note(199, .heading(goneAnchor), "Lost thought"),
            note(150, .page(150), "Out of range"),
        ]
    }

    var highlights: [Highlight] {
        [
            highlight(503, page: 3, y: 500, "Preface quote"),
            highlight(512, page: 12, y: 100, "Lower line"),
            highlight(513, page: 12, y: 600, "Top line"),
            highlight(555, page: 55, y: 300, "Product   rule\n text"),
        ]
    }

    var bookmarks: [Bookmark] {
        [Bookmark(id: uuid(900), bookID: bookA, pageIndex: 12, createdAt: fixedDate),
         Bookmark(id: uuid(901), bookID: bookA, pageIndex: 30, createdAt: fixedDate)]
    }

    func notebook() -> Notebook {
        NotebookBuilder.build(outline: outline, notes: notes, highlights: highlights, bookmarks: bookmarks)
    }
}

@Suite("NotebookBuilder")
struct NotebookTests {
    let book = SeededBook()

    @Test func groupsPageItemsUnderTheDeepestHeadingOnce() throws {
        let notebook = book.notebook()
        #expect(notebook.sections.map(\.title) == ["Ch1 Vectors", "Ch2 Matrices"])
        let ch1 = try #require(notebook.section(for: book.ch1.anchor))
        #expect(ch1.pages.isEmpty)                       // page 12 is listed under 1.1 only
        let s11 = try #require(notebook.section(for: book.s11.anchor))
        #expect(s11.pages.map(\.pageIndex) == [12])
        #expect(s11.pages[0].note?.id == uuid(12))
        #expect(s11.pages[0].highlights.map(\.text) == ["Top line", "Lower line"])   // reading order
        #expect(s11.pages[0].isBookmarked)
        #expect(notebook.section(for: book.ch2.anchor)?.pages.map(\.pageIndex) == [45])
        #expect(notebook.section(for: book.s21.anchor)?.pages.map(\.pageIndex) == [55])
        #expect(notebook.section(for: book.s12.anchor)?.pages.map(\.pageIndex) == [30])
    }

    @Test func headingNotesResolveAndReportRepairs() throws {
        let notebook = book.notebook()
        let ch1 = try #require(notebook.section(for: book.ch1.anchor))
        #expect(ch1.note?.id == uuid(101))
        #expect(ch1.noteMatch == .exact)
        let s21 = try #require(notebook.section(for: book.s21.anchor))
        #expect(s21.note?.id == uuid(121))
        #expect(s21.noteMatch == .pathAndPage)
        #expect(notebook.anchorRepairs.count == 1)
        #expect(notebook.anchorRepairs.first?.noteID == uuid(121))
        #expect(notebook.anchorRepairs.first?.target == .heading(book.s21.anchor))
    }

    @Test func rollsUpCounts() throws {
        let notebook = book.notebook()
        let s11 = try #require(notebook.section(for: book.s11.anchor))
        #expect(s11.ownCounts == NotebookCounts(headingNotes: 0, pageNotes: 1, highlights: 2, bookmarks: 1))
        let ch1 = try #require(notebook.section(for: book.ch1.anchor))
        #expect(ch1.ownCounts == NotebookCounts(headingNotes: 1))
        #expect(ch1.totalCounts == NotebookCounts(headingNotes: 1, pageNotes: 1, highlights: 2, bookmarks: 2))
        #expect(notebook.counts(for: book.ch2.anchor) == NotebookCounts(headingNotes: 1, pageNotes: 1, highlights: 1))
        #expect(notebook.totalCounts == NotebookCounts(headingNotes: 3, pageNotes: 4, highlights: 4, bookmarks: 2))
        #expect(notebook.frontMatterCounts == NotebookCounts(pageNotes: 1, highlights: 1))
    }

    @Test func frontMatterAndOrphanBuckets() {
        let notebook = book.notebook()
        #expect(notebook.frontMatter.map(\.pageIndex) == [3])
        #expect(notebook.frontMatter[0].note?.text == "Front note")
        #expect(notebook.orphanNotes.map(\.id) == [uuid(199)])
        #expect(notebook.orphanPages.map(\.pageIndex) == [150])
    }

    @Test func badgesForEveryHeadingAtOnce() {
        let notebook = book.notebook()
        #expect(notebook.badgedAnchors == [book.ch1.anchor, book.s11.anchor, book.ch2.anchor, book.s21.anchor])
        #expect(!notebook.hasBadge(book.s12.anchor))                     // a bookmark alone does not badge
        #expect(notebook.counts(for: book.s12.anchor).bookmarks == 1)
        #expect(notebook.countsByAnchor.count == book.outline.nodes.count)
    }

    @Test func prunedSectionsKeepOnlyContent() {
        let pruned = book.notebook().sectionsWithContent
        #expect(pruned.map(\.title) == ["Ch1 Vectors", "Ch2 Matrices"])
        #expect(pruned[0].children.map(\.title) == ["1.1 Addition"])
        #expect(pruned[1].children.map(\.title) == ["2.1 Products"])
    }

    @Test func emptyOutlinePutsEverythingInFrontMatter() {
        let notebook = NotebookBuilder.build(outline: Outline(pdfEntries: [], pageCount: 100),
                                             notes: book.notes, highlights: book.highlights)
        #expect(notebook.sections.isEmpty)
        #expect(notebook.frontMatter.map(\.pageIndex) == [3, 12, 45, 55])
        #expect(notebook.orphanNotes.count == 3)          // every heading note
        #expect(notebook.badgedAnchors.isEmpty)
    }

    @Test func twoHeadingNotesForOneHeadingKeepTheExactOne() {
        let exact = book.note(1, .heading(book.s12.anchor), "exact")
        let weaker = book.note(2, .heading(HeadingAnchor(pdfPath: [0, 7], pageIndex: 20, title: "1.2 Scaling")), "weaker")
        let notebook = NotebookBuilder.build(outline: book.outline, notes: [weaker, exact], highlights: [])
        #expect(notebook.section(for: book.s12.anchor)?.note?.id == uuid(1))
        #expect(notebook.orphanNotes.map(\.id) == [uuid(2)])
    }

    @Test func duplicatePageNotesKeepTheNewest() {
        var older = book.note(1, .page(12), "older")
        older.modifiedAt = fixedDate
        var newer = book.note(2, .page(12), "newer")
        newer.modifiedAt = fixedDate.addingTimeInterval(10)
        let notebook = NotebookBuilder.build(outline: book.outline, notes: [newer, older], highlights: [])
        #expect(notebook.section(for: book.s11.anchor)?.pages.first?.note?.id == uuid(2))
        #expect(notebook.orphanPages.map { $0.note?.id } == [uuid(1)])
    }
}
