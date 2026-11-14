import Foundation
import PDFKit
import ReaderCore
import Testing
@testable import Marginal

/// The text engine on its own: matching, snippets, streaming, cancellation, the cap, and the
/// resources a run holds (`SearchDiagnostics`).
extension SearchTests {
    @Suite @MainActor struct Engine {
        typealias Support = SearchTestSupport

        /// Runs the engine to completion and collects what it reports.
        private func collect(_ url: URL, _ query: String, startPage: Int = 0,
                             hitCap: Int = PDFTextSearch.defaultHitCap)
            async -> (hits: [SearchHit], completion: SearchCompletion?, events: Int) {
            var hits: [SearchHit] = []
            var completion: SearchCompletion?
            var events = 0
            for await event in PDFTextSearch.stream(url: url, query: query, startPage: startPage, hitCap: hitCap) {
                events += 1
                switch event {
                case .hits(let batch): hits += batch
                case .progress: break
                case .finished(let c): completion = c
                }
            }
            return (hits, completion, events)
        }

        // MARK: Matching

        @Test func matcherFoldsCaseDiacriticsWidthAndWhitespace() {
            var matcher = SearchTextMatcher()
            let text = "The Café   was near\nthe NAÏVE lighthouse\ntheorem, and the ﬁnal CAFE, then Ｆｕｌｌ e\u{301}tude."
            let folded = matcher.fold(text)
            let ns = text as NSString
            func found(_ query: String) -> [String] {
                SearchTextMatcher.matches(of: matcher.foldQuery(query), in: folded).map { ns.substring(with: $0) }
            }
            #expect(found("cafe") == ["Café", "CAFE"])
            #expect(found("CAFÉ") == ["Café", "CAFE"])               // diacritics in the query too
            #expect(found("naive LIGHTHOUSE") == ["NAÏVE lighthouse"])
            #expect(found("lighthouse theorem") == ["lighthouse\ntheorem"])  // a line wrap is a space
            #expect(found("  lighthouse   theorem ") == ["lighthouse\ntheorem"])
            #expect(found("final") == ["ﬁnal"])                       // ligature expanded
            #expect(found("full") == ["Ｆｕｌｌ"])                      // full-width folded
            #expect(found("etude") == ["e\u{301}tude"])                // decomposed accent dropped
            #expect(found("zebra").isEmpty)
            #expect(matcher.foldQuery("   ").isEmpty)
        }

        @Test func snippetKeepsMatchAndTrimsContext() {
            let text = String(repeating: "alpha beta gamma delta ", count: 10) + "TARGET word " +
                String(repeating: "epsilon zeta eta theta ", count: 10)
            var matcher = SearchTextMatcher()
            let range = SearchTextMatcher.matches(of: matcher.foldQuery("target"), in: matcher.fold(text))[0]
            let snippet = SearchTextMatcher.snippet(in: text as NSString, around: range)
            #expect(snippet.match == "TARGET")
            #expect(snippet.before.hasPrefix("…"))
            #expect(snippet.after.hasSuffix("…"))
            #expect(snippet.before.count < 60 && snippet.after.count < 90)
            #expect(!snippet.text.contains("  "))
        }

        /// The UTF-16 ranges the matcher reports select exactly the matched text on real pages,
        /// and the rects the engine reports cover it (so the jump marks the right words).
        @Test func matchRangesAndRectsSelectTheMatchedText() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let document = try #require(PDFDocument(url: fixture.url))
            var matcher = SearchTextMatcher()
            var checked = 0
            for query in ["the", "Fixture page", "quick amber fox"] {
                let needle = matcher.foldQuery(query)
                for index in 0..<document.pageCount {
                    let page = try #require(document.page(at: index))
                    let text = page.string ?? ""
                    for range in SearchTextMatcher.matches(of: needle, in: matcher.fold(text)) {
                        let selected = page.selection(for: range)?.string ?? ""
                        #expect(matcher.foldQuery(selected) == needle, "page \(index): '\(selected)'")
                        checked += 1
                    }
                }
            }
            #expect(checked > 100)

            let hit = try #require(await collect(fixture.url, "QUICK AMBER FOX").hits.first)
            let page = try #require(document.page(at: hit.pageIndex))
            #expect(hit.pageIndex == 2)
            #expect(!hit.rects.isEmpty)
            let underRects = hit.rects.compactMap { page.selection(for: $0.insetBy(dx: 1, dy: 1))?.string }
                .joined(separator: " ")
            #expect(matcher.foldQuery(underRects).count >= needleCount("quick amber fox"))
            #expect(underRects.lowercased().contains("amber"), "text under the rects: \(underRects)")
        }

        private func needleCount(_ query: String) -> Int {
            var matcher = SearchTextMatcher()
            return matcher.foldQuery(query).count
        }

        // MARK: Streaming

        @Test func findsThePhraseOnPage1400UnderItsHeading() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            let result = await collect(fixture.url, "Zygomorphic LIGHTHOUSE theorem")
            #expect(result.completion == SearchCompletion(reason: .completed, nextPage: 1500))
            #expect(result.hits.count == 1)
            let hit = try #require(result.hits.first)
            #expect(hit.pageIndex == 1399)
            #expect(PageNumbering.label(forPageIndex: hit.pageIndex) == "p. 1400")
            #expect(!hit.rects.isEmpty && hit.rects.allSatisfy { $0.width > 0 && $0.height > 0 })
            #expect(hit.snippet.match == "zygomorphic lighthouse theorem")

            // Grouped under the deepest heading containing page 1,400, with its path.
            let entries = await ReaderDocumentLoader.outlineEntries(at: fixture.url)
            let outline = Outline(pdfEntries: entries, pageCount: 1500)
            let groups = SearchGrouping.group([SearchResult(hit: hit)], outline: outline, pageCount: 1500)
            #expect(groups.count == 1)
            #expect(groups.first?.title == "Set 3")
            #expect(groups.first?.ancestorTitles == ["14 Numerical Methods", "Exercises"])
            #expect(groups.first?.results.first?.pageIndex == 1399)
        }

        /// Results stream: the first hit arrives long before the scan ends, then in batches.
        @Test func firstResultArrivesBeforeTheSearchCompletes() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            let start = ContinuousClock.now
            var firstHitAt: Duration?
            var pagesAtFirstHit: Int?
            var pagesSearched = 0
            var hitBatches = 0
            var hitCount = 0
            var finishedAt: Duration?
            for await event in PDFTextSearch.stream(url: fixture.url, query: "Fixture page", hitCap: 5_000) {
                switch event {
                case .hits(let batch):
                    if firstHitAt == nil {
                        firstHitAt = ContinuousClock.now - start
                        pagesAtFirstHit = pagesSearched
                    }
                    hitBatches += 1
                    hitCount += batch.count
                case .progress(let pages, _):
                    pagesSearched = pages
                case .finished:
                    finishedAt = ContinuousClock.now - start
                }
            }
            let first = try #require(firstHitAt)
            let total = try #require(finishedAt)
            #expect(hitCount == 1500)                  // every page, across document reopenings
            #expect(pagesAtFirstHit == 0)              // delivered before any progress report
            #expect(hitBatches > 1)                    // streamed, not delivered at the end
            #expect(first < total / 4, "first \(first) of \(total)")
            print("SEARCH-TIMING common 'Fixture page' uncapped: first \(first), total \(total), "
                  + "batches \(hitBatches), load \(Support.loadAverage())")
        }

        @Test func capStopsAtAPageBoundaryAndContinuationResumes() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            let first = await collect(fixture.url, "Fixture page", hitCap: 100)
            #expect(first.hits.count == 100)
            #expect(first.completion == SearchCompletion(reason: .capped, nextPage: 100))
            let more = await collect(fixture.url, "Fixture page", startPage: 100, hitCap: 100)
            #expect(more.hits.first?.pageIndex == 100)
            #expect(more.hits.count == 100)
            #expect(more.completion == SearchCompletion(reason: .capped, nextPage: 200))
            // A page with several hits is never split: the cap is checked at page boundaries.
            let many = await collect(fixture.url, "the", hitCap: 5)
            let lastPage = try #require(many.hits.last?.pageIndex)
            #expect(many.hits.count >= 5)
            #expect(many.completion == SearchCompletion(reason: .capped, nextPage: lastPage + 1))
        }

        @Test func unopenableFileOrEmptyQueryFails() async throws {
            let missing = URL(fileURLWithPath: "/nonexistent/book.pdf")
            #expect(await collect(missing, "anything").completion?.reason == .failed)
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            #expect(await collect(fixture.url, "   ").completion?.reason == .failed)
            #expect(await Support.waitUntilEngineIdle())
        }

        // MARK: Resources and cancellation

        /// A completed run leaves no worker and no document behind, and scans nothing more.
        @Test func completedSearchLeavesNothingRunning() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let before = SearchDiagnostics.snapshot
            let result = await collect(fixture.url, "zygomorphic lighthouse theorem")
            #expect(result.completion?.reason == .completed)
            // Counted down before the stream ends, so this holds the moment iteration finishes.
            let after = SearchDiagnostics.snapshot
            #expect(after.liveWorkers == 0)
            #expect(after.liveDocuments == 0)
            #expect(after.pagesScanned - before.pagesScanned == 1500)
            try await Task.sleep(for: .milliseconds(300))
            #expect(SearchDiagnostics.snapshot.pagesScanned == after.pagesScanned)
        }

        /// Cancelling the consuming task stops the worker before its next page (so CPU use
        /// stops) and releases its document; no `.finished` is delivered.
        @Test func cancellingStopsTheWorkerPromptly() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let stream = PDFTextSearch.stream(url: fixture.url, query: "Fixture page", hitCap: 5_000,
                                              pageDelay: .milliseconds(3))
            let consumer = Task { @MainActor () -> (hits: Int, finished: Bool) in
                var hits = 0
                var finished = false
                for await event in stream {
                    if case .hits(let batch) = event { hits += batch.count }
                    if case .finished = event { finished = true }
                }
                return (hits, finished)
            }
            #expect(await Support.waitUntil { SearchDiagnostics.snapshot.pagesScanned > 0 && SearchDiagnostics.snapshot.liveWorkers == 1 })
            try await Task.sleep(for: .milliseconds(200))
            consumer.cancel()
            let cancelledAt = ContinuousClock.now
            #expect(await Support.waitUntilEngineIdle(timeout: 2))
            let stopDelay = ContinuousClock.now - cancelledAt
            let outcome = await consumer.value
            #expect(!outcome.finished)
            #expect(outcome.hits < 1500)
            let scanned = SearchDiagnostics.snapshot.pagesScanned
            try await Task.sleep(for: .milliseconds(400))
            #expect(SearchDiagnostics.snapshot.pagesScanned == scanned, "pages scanned after cancel")
            print("SEARCH-TIMING worker stopped \(stopDelay) after cancel, load \(Support.loadAverage())")
        }

        /// Dropping the stream (leaving the loop early) cancels the worker as well.
        @Test func leavingTheLoopCancelsTheWorker() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            var batches = 0
            for await event in PDFTextSearch.stream(url: fixture.url, query: "Fixture page", hitCap: 5_000,
                                                    pageDelay: .milliseconds(3)) {
                if case .hits = event { batches += 1 }
                if batches == 2 { break }
            }
            #expect(await Support.waitUntilEngineIdle(timeout: 2))
            let scanned = SearchDiagnostics.snapshot.pagesScanned
            try await Task.sleep(for: .milliseconds(300))
            #expect(SearchDiagnostics.snapshot.pagesScanned == scanned)
        }

        /// The engine never holds more than one private document, so memory stays bounded
        /// however many pages it scans (one `PDFDocument` for all 1,500 pages peaked near 485 MB).
        @Test func memoryStaysBoundedOverAFullScan() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let baseline = Support.footprintMB()
            var peak = baseline
            var maxDocuments = 0
            for await _ in PDFTextSearch.stream(url: fixture.url, query: "the", hitCap: 1_000_000) {
                peak = max(peak, Support.footprintMB())
                maxDocuments = max(maxDocuments, SearchDiagnostics.snapshot.liveDocuments)
            }
            #expect(maxDocuments == 1)
            #expect(peak - baseline < 150, "footprint grew \(peak - baseline) MB")
            print("SEARCH-MEMORY full scan of 'the' (23k hits): baseline \(Int(baseline)) MB, "
                  + "peak +\(Int(peak - baseline)) MB")
        }
    }
}
