import Foundation
import Testing
@testable import ReaderCore

@Suite("Notebook selection")
struct NotebookSelectionTests {
    let book = SeededBook()

    @Test func selectingEverythingChangesNothing() {
        let notebook = book.notebook()
        let all = notebook.selecting(notebook.itemIDs)
        #expect(notebook.itemIDs.count == notebook.totalCounts.items)
        // Bookmark-only pages are not items, so they go; everything listed stays.
        #expect(all.totalCounts.items == notebook.totalCounts.items)
        #expect(all.itemIDs == notebook.itemIDs)
        #expect(MarkdownExporter.export(all, bookTitle: "Linear Algebra")
            == MarkdownExporter.export(notebook, bookTitle: "Linear Algebra"))
    }

    @Test func selectingNothingLeavesAnEmptyNotebook() {
        let none = book.notebook().selecting([])
        #expect(none.totalCounts.items == 0)
        #expect(none.sectionsWithContent.isEmpty)
        #expect(MarkdownExporter.export(none, bookTitle: "Linear Algebra") == "# Linear Algebra\n")
    }

    @Test func selectingOnePageNoteKeepsOnlyItAndItsHeading() {
        let one = book.notebook().selecting([.note(uuid(45))])
        #expect(one.totalCounts == NotebookCounts(pageNotes: 1))
        #expect(one.sectionsWithContent.map(\.title) == ["Ch2 Matrices"])
        #expect(one.sectionsWithContent.first?.children.isEmpty == true)
        #expect(MarkdownExporter.export(one, bookTitle: "Linear Algebra") == """
        # Linear Algebra

        ## Ch2 Matrices

        **Page 46**

        Matrix note

        """)
    }

    @Test func selectingAHeadingNoteAHighlightAndAnUnfiledNote() throws {
        let notebook = book.notebook()
        let highlight = try #require(book.highlights.first { $0.text.contains("Lower line") })
        let some = notebook.selecting([.note(uuid(121)), .highlight(highlight.id), .note(uuid(199))])
        // The highlight's page is bookmarked; the bookmark stays with the page.
        #expect(some.totalCounts == NotebookCounts(headingNotes: 2, highlights: 1, bookmarks: 1))
        #expect(some.orphanNotes.map(\.id) == [uuid(199)])
        #expect(some.orphanPages.isEmpty)
        #expect(some.itemIDs == [.note(uuid(121)), .highlight(highlight.id), .note(uuid(199))])
        let markdown = MarkdownExporter.export(some, bookTitle: "Linear Algebra")
        #expect(markdown.contains("> Lower line (p. 13)"))
        #expect(!markdown.contains("Top line"))
        #expect(!markdown.contains("Remember: v + w"))
        #expect(markdown.contains("### Old heading\n\nLost thought"))
    }

    @Test func handwritingPagesAreLinkedWhenTheCallerHasAnImage() {
        let notebook = NotebookBuilder.build(outline: book.outline, notes: [], highlights: [], inkedPages: [12, 45])
        var asked: [Int] = []
        let markdown = MarkdownExporter.export(notebook, bookTitle: "Linear Algebra", handwritingPath: { page in
            asked.append(page)
            return page == 12 ? "handwriting/page-013.png" : nil
        })
        #expect(asked == [12, 45])
        #expect(markdown.contains("**Page 13**\n\n![Handwriting on page 13](handwriting/page-013.png)\n"))
        #expect(markdown.contains("**Page 46**\n\n_Handwriting on page 46_\n"))
    }

    @Test func pageInkIsSelectedByPage() {
        let notebook = NotebookBuilder.build(outline: book.outline, notes: book.notes, highlights: book.highlights,
                                             inkedPages: [12, 45])
        #expect(notebook.itemIDs.contains(.pageInk(12)))
        let one = notebook.selecting([.pageInk(45)])
        #expect(one.inkedPageIndices == [45])
        #expect(one.totalCounts == NotebookCounts(inkedPages: 1))
    }
}
