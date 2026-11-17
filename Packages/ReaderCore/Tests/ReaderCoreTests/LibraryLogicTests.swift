import Foundation
import Testing
@testable import ReaderCore

struct LibraryLogicTests {
    private func book(_ title: String, added: TimeInterval, opened: TimeInterval? = nil, page: Int = 0,
                      pages: Int = 100) -> Book {
        Book(title: title, fingerprint: "fp-\(title)", fileName: "\(title).pdf", pageCount: pages, fileSize: 1_000_000,
             addedAt: Date(timeIntervalSince1970: added), lastOpenedAt: opened.map { Date(timeIntervalSince1970: $0) },
             lastReadPageIndex: page)
    }

    @Test func sortOrders() {
        let a = book("Chapter 10", added: 1)
        let b = book("chapter 2", added: 2, opened: 50)
        let c = book("Algebra", added: 3, opened: 100)
        let d = book("Zoology", added: 4)
        let all = [a, b, c, d]
        #expect(LibraryLogic.sorted(all, by: .title).map(\.title) == ["Algebra", "chapter 2", "Chapter 10", "Zoology"])
        #expect(LibraryLogic.sorted(all, by: .dateAdded).map(\.title) == ["Zoology", "Algebra", "chapter 2", "Chapter 10"])
        // Opened books first (latest first), then never-opened by newest import.
        #expect(LibraryLogic.sorted(all, by: .recentlyOpened).map(\.title) == ["Algebra", "chapter 2", "Zoology", "Chapter 10"])
    }

    @Test func searchMatchesTitlesAndNotes() {
        let a = book("Linear Algebra", added: 1)
        let b = book("Organic Chemistry", added: 2)
        let c = book("Thermodynamics", added: 3)
        let all = [a, b, c]
        #expect(LibraryLogic.filtered(all, query: "").count == 3)
        #expect(LibraryLogic.filtered(all, query: "  ").count == 3)
        #expect(LibraryLogic.filtered(all, query: "ALGEBRA").map(\.title) == ["Linear Algebra"])
        #expect(LibraryLogic.filtered(all, query: "organ").map(\.title) == ["Organic Chemistry"])
        #expect(LibraryLogic.filtered(all, query: "eigen", noteMatches: [c.id]).map(\.title) == ["Thermodynamics"])
        #expect(LibraryLogic.filtered(all, query: "zzz").isEmpty)
        #expect(LibraryLogic.anyText(["Eigenvalue notes", "x"], contains: "eigenv"))
        #expect(!LibraryLogic.anyText(["x"], contains: " "))
    }

    @Test func searchCountsAndOrdersBooksByMatches() {
        #expect(LibraryLogic.matchCount(["Eigenvalue", "eigenvector", "trace", "ÉIGEN"], query: " eigen ") == 3)
        #expect(LibraryLogic.matchCount(["eigen"], query: "  ") == 0)

        let a = book("Algebra", added: 1, opened: 30)
        let b = book("Biology", added: 2, opened: 20)
        let c = book("Chemistry", added: 3, opened: 10)
        let d = book("Drawing", added: 4)
        let counts: [UUID: Int] = [a.id: 2, b.id: 5, c.id: 2, d.id: 0]
        // Most matches first; ties keep the Library's order; no matches, no row.
        #expect(LibraryLogic.searchResultOrder([a, b, c, d], counts: counts, sort: .recentlyOpened).map(\.title)
                == ["Biology", "Algebra", "Chemistry"])
        #expect(LibraryLogic.searchResultOrder([a, b, c, d], counts: counts, sort: .dateAdded).map(\.title)
                == ["Biology", "Chemistry", "Algebra"])
        #expect(LibraryLogic.searchResultOrder([a], counts: [:], sort: .title).isEmpty)

        #expect(LibraryLogic.titleMatches([c, a, b], query: "i", sort: .title).map(\.title) == ["Biology", "Chemistry"])
        #expect(LibraryLogic.titleMatches([a], query: " ", sort: .title).isEmpty)
        #expect(LibraryLogic.matchesText(1) == "1 match")
        #expect(LibraryLogic.matchesText(12) == "12 matches")
        #expect(LibraryLogic.booksText(1) == "1 book")
        #expect(LibraryLogic.booksText(5) == "5 books")
    }

    @Test func continueReadingIsTheMostRecentlyOpened() {
        #expect(LibraryLogic.continueReading([book("A", added: 1)]) == nil)
        let a = book("A", added: 1, opened: 10)
        let b = book("B", added: 2, opened: 20)
        #expect(LibraryLogic.continueReading([a, b, book("C", added: 3)])?.title == "B")
    }

    @Test func stringsAndProgress() {
        let b = book("Linear Algebra", added: 1, opened: 1, page: 311, pages: 742)
        #expect(LibraryLogic.percentRead(b) == 42)
        #expect(LibraryLogic.accessibilityLabel(b) == "Linear Algebra, 742 pages, 42 percent read")
        #expect(LibraryLogic.pageLine(b) == "Page 312 of 742")
        #expect(LibraryLogic.pagesText(1) == "1 page")
        #expect(LibraryLogic.pagesText(1312) == "1,312 pages")
        let fresh = book("Fresh", added: 1)
        #expect(LibraryLogic.percentRead(fresh) == nil)
        #expect(LibraryLogic.progressFraction(fresh) == 0)
        #expect(LibraryLogic.accessibilityLabel(fresh).hasSuffix("not started"))
        #expect(LibraryLogic.annotationLine(count: 0) == nil)
        #expect(LibraryLogic.annotationLine(count: 20) == "20 notes and highlights")
        #expect(LibraryLogic.detailLine(book("X", added: 1, pages: 742)).hasPrefix("742 pages · "))
    }

    @Test func deletionMessageStatesTheCounts() {
        let full = BookDeletionSummary(records: BookRecordCounts(notes: 12, highlights: 30, bookmarks: 1), inkedPages: 8)
        let message = LibraryLogic.deletionMessage(title: "Algebra", summary: full)
        #expect(message.contains("12 notes"))
        #expect(message.contains("30 highlights"))
        #expect(message.contains("8 pages of ink"))
        #expect(message.contains("1 bookmark"))
        #expect(message.contains("can't be undone"))
        let bare = LibraryLogic.deletionMessage(title: "Algebra", summary: BookDeletionSummary(records: BookRecordCounts(), inkedPages: 0))
        #expect(bare.contains("the PDF file") && !bare.contains(" and "))
        #expect(!bare.contains("exported"))
    }

    @Test func deletionMessageNamesExportedPDFs() {
        let none = BookDeletionSummary(records: BookRecordCounts(), inkedPages: 0)
        #expect(LibraryLogic.deletionMessage(title: "Algebra", summary: none, exportedPDFs: 1)
            .contains("the PDF file and 1 exported PDF."))
        #expect(LibraryLogic.deletionMessage(title: "Algebra", summary: none, exportedPDFs: 3).contains("3 exported PDFs"))
    }

    @Test func paletteIndexIsStable() {
        #expect(LibraryLogic.paletteIndex(for: "abc", count: 8) == LibraryLogic.paletteIndex(for: "abc", count: 8))
        #expect((0..<8).contains(LibraryLogic.paletteIndex(for: "anything", count: 8)))
    }
}
