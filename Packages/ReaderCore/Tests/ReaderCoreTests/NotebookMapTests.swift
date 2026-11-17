import Foundation
import Testing
@testable import ReaderCore

/// `NotebookMap`: the strip of the whole book above the Notebook's feed.
struct NotebookMapTests {
    typealias Fixture = NotebookFeedFixture

    private func map(_ filter: NotebookFilter = NotebookFilter()) -> (NotebookMap, [NotebookFeedRow]) {
        let notebook = Fixture.seeded()
        let rows = NotebookFeed.rows(for: notebook, filter: filter)
        return (NotebookMap(notebook: notebook, rows: rows, pageCount: 40), rows)
    }

    @Test func segmentsAreTheTopLevelHeadingsAfterTheFrontMatter() {
        let (map, _) = map()
        #expect(map.segments.map(\.title) == ["Front matter", "3 Matrices and Linear Maps", "4 Determinants",
                                              "5 Eigenvalues and Eigenvectors", "6 Orthogonality"])
        #expect(map.segments.map(\.pages) == [0...1, 2...7, 8...13, 14...29, 30...39])
        #expect(map.segments.map(\.shortLabel) == [nil, "3", "4", "5", "6"])
        // The whole book, with no gaps.
        #expect(map.span(of: map.segments.first!.pages).lowerBound == 0)
        #expect(map.span(of: map.segments.last!.pages).upperBound == 1)
    }

    @Test func marksFollowTheFeedInBookOrder() {
        let (map, rows) = map()
        #expect(map.marks.count == rows.filter { !$0.isHeader }.count)
        #expect(map.marks.count == 16)
        #expect(map.marks.map(\.pageIndex) == map.marks.map(\.pageIndex).sorted())
        let highlight = map.marks.first { $0.pageIndex == 18 }
        #expect(highlight?.kind == .highlight(.yellow))
        #expect(highlight?.sectionTitle == "5.1 Invariant Directions")
        let sectionNote = map.marks.first { $0.kind == .sectionNote && $0.pageIndex == 15 }
        #expect(sectionNote?.sectionTitle == "5.1 Invariant Directions")
        #expect(map.marks.first?.sectionTitle == "Front matter")
        #expect(map.busiestSegment?.title == "5 Eigenvalues and Eigenvectors")
    }

    @Test func searchAndTypeFilterNarrowTheMarks() {
        let (searched, _) = map(NotebookFilter(query: "eigen"))
        #expect(searched.marks.count == 7)
        #expect(searched.marks.allSatisfy { (14...29).contains($0.pageIndex) })
        // The segments stay the whole book.
        #expect(searched.segments.count == 5)

        let (highlights, _) = map(NotebookFilter(type: .highlights))
        #expect(highlights.marks.map(\.pageIndex) == [3, 9, 18, 24, 24, 28])
    }

    @Test func nearestMarkAndPositions() throws {
        let (map, _) = map()
        #expect(map.position(ofPage: 0) == 0.5 / 40)
        #expect(try #require(map.nearestMark(to: 0)).pageIndex == 0)
        #expect(try #require(map.nearestMark(to: map.position(ofPage: 17))).pageIndex == 16)
        #expect(try #require(map.nearestMark(to: 1)).pageIndex == 28)
        #expect(map.segment(containing: 20)?.title == "5 Eigenvalues and Eigenvectors")
    }

    @Test func rowsInViewGiveAPageRange() {
        let (_, rows) = map()
        let ids = Set(rows.filter { $0.targetPage.map { (16...22).contains($0) } ?? false }.map(\.id))
        #expect(NotebookMap.pageRange(ofRows: ids, in: rows) == 16...22)
        #expect(NotebookMap.pageRange(ofRows: [], in: rows) == nil)
    }

    @Test func aBookWithoutHeadingsIsOneSegment() {
        let outline = Outline(pdfEntries: [], userHeadings: [], pageCount: 12)
        let note = Note(bookID: Fixture.bookID, target: .page(5), text: "x", createdAt: Date())
        let notebook = NotebookBuilder.build(outline: outline, notes: [note], highlights: [])
        let map = NotebookMap(notebook: notebook, rows: NotebookFeed.rows(for: notebook, filter: NotebookFilter()),
                              pageCount: 12)
        #expect(map.segments.map(\.pages) == [0...11])
        #expect(map.marks.map(\.pageIndex) == [5])
    }

    @Test func shortLabels() {
        #expect(NotebookMap.shortLabel("5 Eigenvalues") == "5")
        #expect(NotebookMap.shortLabel("A.2 Proofs") == "A.2")
        #expect(NotebookMap.shortLabel("Chapter 5") == nil)
        #expect(NotebookMap.shortLabel("12. Groups") == "12")
        #expect(NotebookMap.shortLabel("") == nil)
    }
}
