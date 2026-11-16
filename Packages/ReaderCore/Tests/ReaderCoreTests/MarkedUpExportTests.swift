import Foundation
import Testing
@testable import ReaderCore

@Suite("Marked-up PDF export: file names, outline and appendix")
struct MarkedUpExportTests {
    let pdf = [e("Ch1", 1, 0), e("1.1", 2, 2), e("Group", 2, nil), e("1.2.1", 3, 5), e("Ch2", 1, 10)]

    @Test func fileNamesSayWhetherNotesAreIncluded() {
        #expect(MarkedUpExport.fileName(forBookTitle: "Linear Algebra", includesNotes: false) == "Linear Algebra (Marked Up).pdf")
        #expect(MarkedUpExport.fileName(forBookTitle: "Linear Algebra", includesNotes: true)
            == "Linear Algebra (Marked Up with Notes).pdf")
        #expect(MarkedUpExport.fileName(forBookTitle: "  A/B: C?\n", includesNotes: false) == "A B C (Marked Up).pdf")
        #expect(MarkedUpExport.fileName(forBookTitle: " / ", includesNotes: false) == "Book (Marked Up).pdf")
        #expect(ExportFileName.cleanedTitle(".hidden") == "hidden")
        #expect(ExportFileName.cleanedTitle(String(repeating: "x", count: 200))?.count == 80)
    }

    @Test func pagesMapOneToOneAndTheAppendixFollowsTheBook() {
        #expect(MarkedUpExport.exportPageNumber(forBookPageIndex: 0) == 1)
        #expect(MarkedUpExport.exportPageNumber(forBookPageIndex: 311) == 312)
        #expect(MarkedUpExport.appendixFirstPageNumber(bookPageCount: 742) == 743)
    }

    @Test func bookOutlineKeepsEveryHeadingWithItsNestingAndPage() {
        let outline = Outline(pdfEntries: pdf, pageCount: 20)
        let items = MarkedUpExport.bookOutline(outline)
        #expect(items.map(\.title) == ["Ch1", "Ch2"])
        #expect(items.map(\.pageNumber) == [1, 11])
        let ch1 = items[0]
        #expect(ch1.children.map(\.title) == ["1.1", "Group"])
        #expect(ch1.children.map(\.pageNumber) == [3, 6], "a heading with no page opens its first descendant's page")
        #expect(ch1.children[1].children.map(\.title) == ["1.2.1"])
        #expect(ch1.children[1].children[0].pageNumber == 6)
        #expect(items.flatMap(\.flattened).count == pdf.count)
    }

    @Test func aHeadingWithNoPageAnywhereOpensItsParentsPage() {
        let outline = Outline(pdfEntries: [e("Part", 1, 4), e("Empty", 2, nil), e("Orphan", 1, nil)], pageCount: 10)
        let items = MarkedUpExport.bookOutline(outline)
        let part = try! #require(items.first { $0.title == "Part" })
        #expect(part.pageNumber == 5)
        #expect(part.children.map(\.pageNumber) == [5])
        #expect(items.first { $0.title == "Orphan" }?.pageNumber == 1)
    }

    @Test func readersOwnHeadingsAreInTheOutlineWhereContentsShowsThem() {
        let plain = Outline(pdfEntries: pdf, pageCount: 20)
        let ch1 = plain.titled("Ch1").anchor
        let outline = Outline(pdfEntries: pdf, userHeadings: [
            UserHeading(id: uuid(1), bookID: bookA, title: "Interlude", pageIndex: 8, parent: nil, createdAt: fixedDate),
            UserHeading(id: uuid(2), bookID: bookA, title: "1.1b", pageIndex: 3, parent: ch1, createdAt: fixedDate),
        ], pageCount: 20)
        let items = MarkedUpExport.bookOutline(outline)
        #expect(items.map(\.title) == ["Ch1", "Interlude", "Ch2"])
        #expect(items[1].pageNumber == 9)
        #expect(items[0].children.map(\.title) == ["1.1", "1.1b", "Group"])
        #expect(items[0].children[1].pageNumber == 4)
    }

    @Test func aBookWithoutAnOutlineHasNoBookEntries() {
        #expect(MarkedUpExport.bookOutline(Outline(pdfEntries: [], pageCount: 40)).isEmpty)
    }

    @Test func appendixOutlineNestsTheHeadingsWithNotesUnderNotes() {
        let outline = Outline(pdfEntries: pdf, pageCount: 20)
        let notes = [
            Note(bookID: bookA, target: .page(0), text: "On the first page", createdAt: fixedDate, modifiedAt: fixedDate),
            Note(bookID: bookA, target: .page(5), text: "Deep", createdAt: fixedDate, modifiedAt: fixedDate),
            Note(bookID: bookA, target: .heading(outline.titled("Ch2").anchor), text: "Chapter 2",
                 createdAt: fixedDate, modifiedAt: fixedDate),
            Note(bookID: bookA, target: .page(30), text: "Off the end", createdAt: fixedDate, modifiedAt: fixedDate),
        ]
        let notebook = NotebookBuilder.build(outline: outline, notes: notes, highlights: [])
        let ch1 = outline.titled("Ch1").anchor, group = outline.titled("Group").anchor
        let leaf = outline.titled("1.2.1").anchor, ch2 = outline.titled("Ch2").anchor
        let starts: [NotebookExportPart: Int] = [.title: 21, .section(ch1): 21, .section(group): 22, .section(leaf): 22,
                                                 .section(ch2): 23, .unfiled: 24]
        let appendix = try! #require(MarkedUpExport.appendixOutline(notebook, starts: starts))
        #expect(appendix.title == "Notes")
        #expect(appendix.pageNumber == 21)
        #expect(appendix.children.map(\.title) == ["Ch1", "Ch2", "Unfiled notes"])
        #expect(appendix.children.map(\.pageNumber) == [21, 23, 24])
        #expect(appendix.children[0].children.map(\.title) == ["Group"], "only headings with notes")
        #expect(appendix.children[0].children[0].children.map(\.title) == ["1.2.1"])
        #expect(appendix.children[0].children[0].children[0].pageNumber == 22)

        let whole = MarkedUpExport.outline(book: MarkedUpExport.bookOutline(outline), appendix: appendix)
        #expect(whole.map(\.title) == ["Ch1", "Ch2", "Notes"])
        #expect(MarkedUpExport.outline(book: [], appendix: nil).isEmpty)
    }

    @Test func appendixOutlineListsFrontMatterAndFallsBackToItsParentsPage() {
        let outline = Outline(pdfEntries: [e("Ch1", 1, 4)], pageCount: 10)
        let notes = [
            Note(bookID: bookA, target: .page(1), text: "Preface note", createdAt: fixedDate, modifiedAt: fixedDate),
            Note(bookID: bookA, target: .page(6), text: "In Ch1", createdAt: fixedDate, modifiedAt: fixedDate),
        ]
        let notebook = NotebookBuilder.build(outline: outline, notes: notes, highlights: [])
        let appendix = try! #require(MarkedUpExport.appendixOutline(notebook, starts: [.title: 11, .frontMatter: 11]))
        #expect(appendix.children.map(\.title) == ["Front matter", "Ch1"])
        #expect(appendix.children.map(\.pageNumber) == [11, 11])
        #expect(MarkedUpExport.appendixOutline(notebook, starts: [:]) == nil)
    }
}
