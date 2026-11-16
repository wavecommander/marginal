import Foundation
import PDFKit
import Testing
@testable import TactileTexts

/// `ReaderPDFDocument`'s batched document-span selection gives exactly PDFKit's selection.
@MainActor
struct ReaderPDFDocumentTests {
    /// The text ranges of a selection, page by page (page index, ranges).
    private func ranges(of selection: PDFSelection?, in document: PDFDocument) -> [[Int]] {
        guard let selection else { return [] }
        return selection.pages.map { page in
            [document.index(for: page)] + (0..<selection.numberOfTextRanges(on: page)).flatMap { index -> [Int] in
                let range = selection.range(at: index, on: page)
                return [range.location, range.length]
            }
        }
    }

    @Test(arguments: [(0, 0, 1199, 4), (5, 100, 17, 30), (10, -1, 13, -2), (40, 0, 43, 0), (1490, 7, 1499, -1)])
    func batchedSpanMatchesPDFKit(_ span: (Int, Int, Int, Int)) throws {
        let plain = try #require(PDFDocument(url: LibraryImportTests.large))
        let reader = try #require(ReaderPDFDocument(url: LibraryImportTests.large))
        func character(_ value: Int, on page: PDFPage) -> Int {
            value >= 0 ? value : page.numberOfCharacters + value
        }
        let plainStart = try #require(plain.page(at: span.0))
        let plainEnd = try #require(plain.page(at: span.2))
        let readerStart = try #require(reader.page(at: span.0))
        let readerEnd = try #require(reader.page(at: span.2))
        let expected = plain.selection(from: plainStart, atCharacterIndex: character(span.1, on: plainStart),
                                       to: plainEnd, atCharacterIndex: character(span.3, on: plainEnd))
        let batched = try #require(reader.batchedSelection(from: readerStart, atCharacterIndex: character(span.1, on: readerStart),
                                                           to: readerEnd, atCharacterIndex: character(span.3, on: readerEnd)))
        #expect(batched.string == expected?.string)
        #expect(ranges(of: batched, in: reader) == ranges(of: expected, in: plain))
        // The public entry point answers with the batched selection too.
        let viaOverride = reader.selection(from: readerStart, atCharacterIndex: character(span.1, on: readerStart),
                                           to: readerEnd, atCharacterIndex: character(span.3, on: readerEnd))
        #expect(viaOverride?.string == expected?.string)
    }

    @Test func shortOrInvalidSpansGoToPDFKit() throws {
        let reader = try #require(ReaderPDFDocument(url: LibraryImportTests.large))
        let page2 = try #require(reader.page(at: 2))
        let page4 = try #require(reader.page(at: 4))
        let page9 = try #require(reader.page(at: 9))
        // Fewer than `batchThreshold` pages apart.
        #expect(reader.batchedSelection(from: page2, atCharacterIndex: 0, to: page4, atCharacterIndex: 0) == nil)
        // Reversed, negative or past the end of the page.
        #expect(reader.batchedSelection(from: page9, atCharacterIndex: 0, to: page2, atCharacterIndex: 0) == nil)
        #expect(reader.batchedSelection(from: page2, atCharacterIndex: -1, to: page9, atCharacterIndex: 0) == nil)
        #expect(reader.batchedSelection(from: page2, atCharacterIndex: 0, to: page9,
                                        atCharacterIndex: page9.numberOfCharacters) == nil)
        // Still answered (by PDFKit).
        #expect(reader.selection(from: page2, atCharacterIndex: 0, to: page4, atCharacterIndex: 0)?.string?.isEmpty == false)
    }
}
