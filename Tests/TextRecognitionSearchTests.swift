import Foundation
import PDFKit
import ReaderCore
import Testing
@testable import Marginal

/// Search over recognised text (S2): one search path reads each page from whichever source has
/// text; hits on recognised pages carry rects from the word boxes; a page recognised after the
/// scan passed it is searched once more; the model says page search is partial; and choosing a
/// recognised hit marks it from its rects alone. Nested in `SearchTests` (serialised) because
/// the engine's resource counters are process-wide.
extension SearchTests {
    @Suite @MainActor struct TextRecognitionSearch {
        typealias Support = SearchTestSupport

        /// A recognised page standing in for Vision's output on `pageIndex` of `scanned.pdf`: a
        /// running header, the known phrase on its own line at the findings' place, and a body
        /// line.
        static func recognisedPage(_ pageIndex: Int) -> RecognisedPage {
            func line(_ words: [String], y: CGFloat, height: CGFloat) -> [RecognisedPage.Token] {
                var x: CGFloat = 72
                return words.map { word in
                    let width = CGFloat(word.count) * 4.6
                    defer { x += width + 3 }
                    return RecognisedPage.Token(text: word, bounds: CGRect(x: x, y: y, width: width, height: height))
                }
            }
            return RecognisedPage(pageIndex: pageIndex, lines: [
                line(["Scanned", "Fixture", "Book", "|", "Chapter", "8"], y: 740, height: 9),
                line(TextRecognitionTestSupport.phrase.split(separator: " ").map(String.init), y: 692, height: 12),
                line(["Independent", "factorization", "vector", "spaces", "show", "how"], y: 669, height: 13),
            ])
        }

        private func collect(_ url: URL, _ query: String, recognised: RecognisedTextSource?) async -> [SearchHit] {
            var hits: [SearchHit] = []
            for await event in PDFTextSearch.stream(url: url, query: query, recognised: recognised) {
                if case .hits(let batch) = event { hits += batch }
            }
            return hits
        }

        @Test func recognisedPagesAreSearchedWithRectsFromTheWords() async throws {
            let fixture = try TextRecognitionTestSupport.scannedFixture()
            defer { fixture.cleanUp() }
            let page = Self.recognisedPage(16)
            try await fixture.store.saveRecognisedPage(page, bookID: fixture.book.id, origin: nil)
            let source = RecognisedTextSource(store: fixture.store.recognisedText, bookID: fixture.book.id, ledger: nil)

            // Without the recognised text (as before S2) nothing is found on a scanned page.
            #expect(await collect(fixture.url, "QUIET heron", recognised: nil).isEmpty)

            let hits = await collect(fixture.url, "QUIET heron", recognised: source)
            #expect(hits.count == 1)
            let hit = try #require(hits.first)
            #expect(hit.pageIndex == 16)
            #expect(hit.ordinal == 0 && hit.id == "text-16-0")
            let text = page.text as NSString
            let range = text.range(of: "quiet heron")
            #expect(hit.rects == page.rects(forUTF16Range: range.location..<NSMaxRange(range)))
            let rect = try #require(hit.rects.first)
            #expect(hit.rects.count == 1 && rect.minY == 692 && rect.height == 12, "\(hit.rects)")
            #expect(hit.snippet.match == "quiet heron")
            #expect(hit.snippet.before.hasSuffix("The "), "\(hit.snippet)")
            #expect(hit.snippet.after.hasPrefix(" measures tidewater."), "\(hit.snippet)")

            // A match across a line break gives one rect per line.
            let across = try #require(await collect(fixture.url, "tidewater. Independent", recognised: source).first)
            #expect(across.rects.count == 2)

            // The typed cover is read from the file (rects from PDFKit's selection), the scanned
            // page from its recognised text, in one search.
            let both = await collect(fixture.url, "scanned fixture", recognised: source)
            #expect(both.map(\.pageIndex) == [0, 16])
            #expect(both.allSatisfy { !$0.rects.isEmpty })
            let cover = try #require(PDFDocument(url: fixture.url)?.page(at: 0))
            let coverRange = (cover.string! as NSString).range(of: "Scanned Fixture", options: .caseInsensitive)
            let coverRects = cover.selection(for: coverRange)?.selectionsByLine().map { $0.bounds(for: cover) } ?? []
            #expect(both.first?.rects == coverRects.filter { !$0.isEmpty })
        }

        @Test func aPageRecognisedAfterTheScanPassedItIsSearchedOnce() async throws {
            let fixture = try TextRecognitionTestSupport.scannedFixture()
            defer { fixture.cleanUp() }
            let bookID = fixture.book.id
            try await fixture.store.saveRecognitionState(.inProgress(RecognitionProgress(pagesDone: 1, totalPages: 30)),
                                                         bookID: bookID, origin: nil)
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let model = Support.makeModel(session)
            #expect(await Support.waitUntil { model.recognitionState != nil })
            #expect(model.isPageSearchPartial)

            model.query = "heron"
            #expect(await Support.waitUntil { model.phase == .finished })
            #expect(model.textHitCount == 0)
            #expect(model.ledger.missedPages == Set(1..<30), "every scanned page was searched without text")

            // Recognised behind the scan position: searched again on its own, once.
            try await fixture.store.saveRecognisedPage(Self.recognisedPage(16), bookID: bookID, origin: nil)
            #expect(await Support.waitUntil { model.textHitCount == 1 })
            #expect(model.phase == .finished, "the search was not restarted")
            #expect(model.caughtUpPages == [16])
            let result = try #require(model.orderedResults.first)
            #expect(result.pageIndex == 16 && result.kind == .text && result.rects.first?.minY == 692)
            // Saved again (the page re-recognised): no duplicate.
            try await fixture.store.saveRecognisedPage(Self.recognisedPage(16), bookID: bookID, origin: nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.textHitCount == 1)
            #expect(model.caughtUpPages == [16])

            // Recognition completes: page search is no longer partial.
            try await fixture.store.saveRecognitionState(.complete, bookID: bookID, origin: nil)
            #expect(await Support.waitUntil { !model.isPageSearchPartial })
            #expect(await Support.waitUntilEngineIdle())
        }

        @Test func aPageRecognisedAheadOfTheScanIsFoundByTheScan() async throws {
            let fixture = try TextRecognitionTestSupport.scannedFixture()
            defer { fixture.cleanUp() }
            let bookID = fixture.book.id
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let model = Support.makeModel(session, pageDelay: .milliseconds(60))
            model.query = "heron"
            #expect(await Support.waitUntil { model.pagesSearched >= 3 })
            #expect(model.pagesSearched < 20)
            try await fixture.store.saveRecognisedPage(Self.recognisedPage(25), bookID: bookID, origin: nil)
            #expect(await Support.waitUntil { model.phase == .finished })
            #expect(model.textHitCount == 1)
            #expect(model.orderedResults.first?.pageIndex == 25)
            #expect(model.caughtUpPages.isEmpty, "found by the scan, not searched again")
            // A book with no recognition state is not partial.
            #expect(!model.isPageSearchPartial)
        }

        @Test func theLedgerHandsEachRacingPageToExactlyOneSide() {
            let ledger = RecognisedPageLedger()
            // Missed first, then recognised: the model searches it again, once.
            #expect(!ledger.searchedWithoutRecognisedText(3))
            #expect(ledger.pageRecognised(3))
            #expect(!ledger.pageRecognised(3))
            // Recognised while the worker was reading it: the worker reads it again.
            #expect(!ledger.pageRecognised(7))
            #expect(ledger.searchedWithoutRecognisedText(7))
            #expect(ledger.missedPages.isEmpty)
        }

        // MARK: The mark on the page

        @Test func choosingARecognisedHitMarksItFromItsRectsAlone() async throws {
            let fixture = try TextRecognitionTestSupport.scannedFixture()
            defer { fixture.cleanUp() }
            try await fixture.store.saveRecognisedPage(Self.recognisedPage(16), bookID: fixture.book.id, origin: nil)
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let model = Support.makeModel(session)
            model.query = "quiet heron"
            #expect(await Support.waitUntil { model.phase == .finished })
            let result = try #require(model.orderedResults.first)
            #expect(result.pageIndex == 16)

            model.select(result)
            #expect(session.currentPageIndex == 16)
            let mark = try #require(session.pdf.rectsOnlyMark, "a scanned page PDFKit has not read is marked from rects")
            #expect(mark.pageIndex == 16)
            #expect(mark.rects == result.rects)
            let page = try #require(session.pdf.page(at: 16))
            #expect((page.string ?? "").isEmpty, "the on-screen page has no text to re-find")
            let annotations = page.annotations.compactMap { $0 as? SearchMarkAnnotation }
            #expect(annotations.count == 1)
            #expect(annotations.first?.bounds == result.rects.reduce(CGRect.null) { $0.union($1) })
            #expect(session.pdf.view.highlightedSelections == nil)

            // Cleared like any search mark (a tap on the page, another result, a new search).
            session.pdf.clearMarks()
            #expect(session.pdf.rectsOnlyMark == nil)
            #expect(page.annotations.contains { $0 is SearchMarkAnnotation } == false)
        }

        @Test func typedPageHitsAreStillMarkedThroughASelection() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let model = Support.makeModel(session)
            model.query = "quick amber fox"
            #expect(await Support.waitUntil { model.phase == .finished })
            let result = try #require(model.orderedResults.first { $0.kind == .text })
            model.select(result)
            #expect(session.pdf.rectsOnlyMark == nil)
            let marked = try #require(session.pdf.view.highlightedSelections?.first)
            #expect(marked.string?.lowercased().contains("quick amber fox") == true, "\(marked.string ?? "")")
            #expect(session.pdf.page(at: result.pageIndex)?.annotations.contains { $0 is SearchMarkAnnotation } == false)
        }
    }
}
