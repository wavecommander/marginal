import Foundation
import Testing
@testable import ReaderCore

/// WP14: pages with page ink in the Notebook tree, its counts and the Markdown export.
@Suite("Notebook page ink")
struct NotebookInkTests {
    let book = SeededBook()
    /// Front matter (5), a page with a note, highlights and a bookmark (12), a bookmark-only page
    /// (30), a heading's own page before a noted page (41), out of range (150); unsorted, with a
    /// duplicate.
    let inked = [41, 12, 150, 5, 30, 41]

    func notebook(inkedPages: [Int]? = nil) -> Notebook {
        NotebookBuilder.build(outline: book.outline, notes: book.notes, highlights: book.highlights,
                              bookmarks: book.bookmarks, inkedPages: inkedPages ?? inked)
    }

    @Test func inkedPagesAreFiledUnderTheDeepestHeadingLikeOtherPageItems() throws {
        let notebook = notebook()
        #expect(notebook.frontMatter.map(\.pageIndex) == [3, 5])
        #expect(notebook.frontMatter.map(\.hasInk) == [false, true])
        #expect(notebook.frontMatter[1].note == nil && notebook.frontMatter[1].highlights.isEmpty)

        // One page entry carries the note, the highlights, the bookmark and the ink.
        let s11 = try #require(notebook.section(for: book.s11.anchor))
        #expect(s11.pages.map(\.pageIndex) == [12])
        #expect(s11.pages[0].hasInk && s11.pages[0].note != nil && s11.pages[0].highlights.count == 2)
        #expect(s11.pages[0].isBookmarked)

        // Bookmark plus ink under 1.2; ascending pages under Ch2 (its own page 41, then 45).
        #expect(notebook.section(for: book.s12.anchor)?.pages.map(\.pageIndex) == [30])
        #expect(notebook.section(for: book.s12.anchor)?.pages.first?.hasInk == true)
        #expect(notebook.section(for: book.ch2.anchor)?.pages.map(\.pageIndex) == [41, 45])
        #expect(notebook.section(for: book.ch2.anchor)?.pages.map(\.hasInk) == [true, false])
        #expect(notebook.section(for: book.ch1.anchor)?.pages.isEmpty == true)   // 12 is filed once, under 1.1

        // Out of range: with the page note that is already there.
        #expect(notebook.orphanPages.map(\.pageIndex) == [150])
        #expect(notebook.orphanPages[0].hasInk && notebook.orphanPages[0].note != nil)

        #expect(notebook.inkedPageIndices == [5, 12, 30, 41, 150])
    }

    @Test func countsRollUpOncePerInkedPage() throws {
        let notebook = notebook()
        let s11 = try #require(notebook.section(for: book.s11.anchor))
        #expect(s11.ownCounts == NotebookCounts(pageNotes: 1, highlights: 2, bookmarks: 1, inkedPages: 1))
        #expect(notebook.counts(for: book.s12.anchor) == NotebookCounts(bookmarks: 1, inkedPages: 1))
        #expect(notebook.counts(for: book.ch1.anchor)
            == NotebookCounts(headingNotes: 1, pageNotes: 1, highlights: 2, bookmarks: 2, inkedPages: 2))
        #expect(notebook.counts(for: book.ch2.anchor) == NotebookCounts(headingNotes: 1, pageNotes: 1, highlights: 1, inkedPages: 1))
        #expect(notebook.frontMatterCounts == NotebookCounts(pageNotes: 1, highlights: 1, inkedPages: 1))
        #expect(notebook.totalCounts == NotebookCounts(headingNotes: 3, pageNotes: 4, highlights: 4, bookmarks: 2, inkedPages: 5))
        #expect(notebook.totalCounts.items == 3 + 4 + 4 + 5)
        // Notes and highlights are unchanged by ink.
        let without = self.notebook(inkedPages: [])
        #expect(without.totalCounts.notes == notebook.totalCounts.notes)
        #expect(without.totalCounts.highlights == notebook.totalCounts.highlights)
    }

    @Test func inkMakesAHeadingShowInTheNotebookButNeverBadgesContents() {
        let notebook = notebook()
        // 1.2 has only a bookmark and ink: listed in the Notebook, no Contents badge.
        #expect(!notebook.hasBadge(book.s12.anchor))
        #expect(notebook.counts(for: book.s12.anchor).hasContent)
        #expect(notebook.badgedAnchors == [book.ch1.anchor, book.s11.anchor, book.ch2.anchor, book.s21.anchor])
        let pruned = notebook.sectionsWithContent
        #expect(pruned.map(\.title) == ["Ch1 Vectors", "Ch2 Matrices"])
        #expect(pruned[0].children.map(\.title) == ["1.1 Addition", "1.2 Scaling"])

        // A heading whose only content is ink.
        let inkOnly = NotebookBuilder.build(outline: book.outline, notes: [], highlights: [], inkedPages: [55])
        #expect(inkOnly.badgedAnchors.isEmpty)
        #expect(inkOnly.sectionsWithContent.map(\.title) == ["Ch2 Matrices"])
        #expect(inkOnly.sectionsWithContent[0].children.map(\.title) == ["2.1 Products"])
        #expect(inkOnly.sectionsWithContent[0].children[0].pages.map(\.pageIndex) == [55])
        #expect(inkOnly.counts(for: book.ch2.anchor) == NotebookCounts(inkedPages: 1))
    }

    @Test func emptyCases() {
        // No ink: nothing is marked and the counts are as before.
        let noInk = notebook(inkedPages: [])
        #expect(noInk.inkedPageIndices.isEmpty)
        #expect(noInk.totalCounts.inkedPages == 0)
        #expect(noInk.section(for: book.s12.anchor)?.pages.first?.hasInk == false)
        #expect(noInk.sectionsWithContent[0].children.map(\.title) == ["1.1 Addition"])

        // Ink only, no outline: every inked page is front matter.
        let flat = NotebookBuilder.build(outline: Outline(pdfEntries: [], pageCount: 100), notes: [], highlights: [],
                                         inkedPages: [9, 2])
        #expect(flat.frontMatter.map(\.pageIndex) == [2, 9])
        #expect(flat.frontMatter.allSatisfy { $0.hasInk && $0.hasContent })
        #expect(flat.sectionsWithContent.isEmpty)
        #expect(flat.totalCounts == NotebookCounts(inkedPages: 2))

        // Nothing at all.
        let empty = NotebookBuilder.build(outline: book.outline, notes: [], highlights: [], inkedPages: [])
        #expect(empty.totalCounts.isEmpty && !empty.totalCounts.hasContent)
        #expect(empty.sectionsWithContent.isEmpty)

        // A bookmark alone is still not content.
        #expect(!NotebookCounts(bookmarks: 1).hasContent)
        #expect(!NotebookCounts(bookmarks: 1).isEmpty)
    }

    @Test func orderOfInputsDoesNotMatter() {
        let a = notebook(inkedPages: [5, 12, 30, 41, 150])
        let b = NotebookBuilder.build(outline: book.outline, notes: book.notes.reversed(), highlights: book.highlights.reversed(),
                                      bookmarks: book.bookmarks.reversed(), inkedPages: [150, 41, 41, 30, 12, 5, 5])
        #expect(a.sections == b.sections)
        #expect(a.frontMatter == b.frontMatter)
        #expect(a.orphanPages == b.orphanPages)
        #expect(a.totalCounts == b.totalCounts)
    }

    // MARK: Markdown

    @Test func markdownMentionsEachInkedPageUnderItsSection() {
        let outline = Outline(pdfEntries: [e("1 Start", 1, 2), e("1.1 Sub", 2, 4)], pageCount: 10)
        let note = Note(id: uuid(1), bookID: bookA, target: .page(4), text: "Note on five", createdAt: fixedDate)
        let highlight = Highlight(id: uuid(2), bookID: bookA, pageIndex: 4, rects: [CGRect(x: 0, y: 0, width: 10, height: 10)],
                                  color: .blue, text: "Quote", createdAt: fixedDate)
        let bookmarks = [Bookmark(id: uuid(3), bookID: bookA, pageIndex: 8, createdAt: fixedDate),
                         Bookmark(id: uuid(4), bookID: bookA, pageIndex: 5, createdAt: fixedDate)]
        let notebook = NotebookBuilder.build(outline: outline, notes: [note], highlights: [highlight], bookmarks: bookmarks,
                                             inkedPages: [5, 0, 4, 3, 12])
        let markdown = MarkdownExporter.export(notebook, bookTitle: "Ink")
        #expect(markdown == """
        # Ink

        ## Front matter

        **Page 1**

        _Handwriting on page 1_

        ## 1 Start

        **Page 4**

        _Handwriting on page 4_

        ### 1.1 Sub

        **Page 5**

        Note on five

        > Quote (p. 5)

        _Handwriting on page 5_

        **Page 6**

        _Handwriting on page 6_

        ## Unfiled notes

        **Page 13**

        _Handwriting on page 13_

        """)
    }

    @Test func markdownWithoutInkIsUnchanged() {
        let plain = MarkdownExporter.export(book.notebook(), bookTitle: "Linear Algebra")
        let explicit = MarkdownExporter.export(notebook(inkedPages: []), bookTitle: "Linear Algebra")
        #expect(plain == explicit)
        #expect(!plain.contains("Handwriting on page"))
    }
}

/// `InkedPagesCache`: one listing per book until a page-ink change, shared by concurrent callers.
@MainActor
@Suite("InkedPagesCache")
struct InkedPagesCacheTests {
    let bookB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    @Test func listsOnceThenServesTheCache() async throws {
        let store = LibraryStore.inMemory()
        try await store.inkStore.savePageInk(Data([1]), bookID: bookA, pageIndex: 7)
        try await store.inkStore.savePageInk(Data([1]), bookID: bookA, pageIndex: 2)
        #expect(store.inkedPages.cachedPages(bookID: bookA) == nil)
        #expect(try await store.inkedPages.pages(bookID: bookA) == [2, 7])
        #expect(try await store.inkedPages.pages(bookID: bookA) == [2, 7])
        #expect(store.inkedPages.cachedPages(bookID: bookA) == [2, 7])
        #expect(store.inkedPages.listingCount == 1)
    }

    @Test func aPageInkChangeFromAnyWindowRefreshesWithOneListing() async throws {
        let store = LibraryStore.inMemory()
        let cache = store.inkedPages
        #expect(try await cache.pages(bookID: bookA) == [])
        try await store.savePageInk(Data([1]), bookID: bookA, pageIndex: 4, origin: ChangeOrigin(label: "window 1"))
        try await store.savePageInk(Data([1]), bookID: bookA, pageIndex: 9, origin: ChangeOrigin(label: "window 2"))
        #expect(cache.cachedPages(bookID: bookA) == nil)
        #expect(try await cache.pages(bookID: bookA) == [4, 9])
        #expect(cache.listingCount == 2)   // the two changes cost one listing

        // Erasing all ink on a page removes it.
        try await store.deletePageInk(bookID: bookA, pageIndex: 4, origin: nil)
        #expect(try await cache.pages(bookID: bookA) == [9])
        #expect(cache.listingCount == 3)
    }

    @Test func anotherBooksChangeKeepsTheCache() async throws {
        let store = LibraryStore.inMemory()
        try await store.inkStore.savePageInk(Data([1]), bookID: bookA, pageIndex: 1)
        #expect(try await store.inkedPages.pages(bookID: bookA) == [1])
        try await store.savePageInk(Data([1]), bookID: bookB, pageIndex: 3, origin: nil)
        #expect(store.inkedPages.cachedPages(bookID: bookA) == [1])
        #expect(try await store.inkedPages.pages(bookID: bookB) == [3])
        #expect(store.inkedPages.listingCount == 2)
    }

    @Test func concurrentCallersShareOneListing() async throws {
        let store = LibraryStore.inMemory()
        try await store.inkStore.savePageInk(Data([1]), bookID: bookA, pageIndex: 5)
        async let first = store.inkedPages.pages(bookID: bookA)
        async let second = store.inkedPages.pages(bookID: bookA)
        let (a, b) = try await (first, second)
        #expect(a == [5] && b == [5])
        #expect(store.inkedPages.listingCount == 1)
    }

    @Test func aDeletedBookIsForgotten() async throws {
        let store = LibraryStore.inMemory()
        try store.books.save(Book(id: bookA, title: "A", fingerprint: "a", fileName: "a.pdf", pageCount: 10, fileSize: 1))
        try await store.inkStore.savePageInk(Data([1]), bookID: bookA, pageIndex: 5)
        #expect(try await store.inkedPages.pages(bookID: bookA) == [5])
        try store.books.deleteBook(id: bookA)
        #expect(store.inkedPages.cachedPages(bookID: bookA) == nil)
    }
}
