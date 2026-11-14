import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// The per-window model: query lifecycle, cancellation (proved on the engine's counters, not
/// just on what the model shows), grouping, notes and highlights with live updates, and two
/// windows on one book.
extension SearchTests {
    @Suite @MainActor struct Model {
        typealias Support = SearchTestSupport

        // MARK: Cancellation and lifecycle

        @Test func cancelStopsResultsAndTheWorkerAndContinueResumes() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session, hitCap: 5_000, pageDelay: .milliseconds(3))
            model.query = "Fixture page"
            #expect(await Support.waitUntil { model.resultCount >= 3 })
            model.cancel()
            guard case .cancelled(let next) = model.phase else {
                Issue.record("expected cancelled, got \(model.phase)")
                return
            }
            #expect(next == model.pagesSearched)
            #expect(await Support.waitUntilEngineIdle(timeout: 2), "worker still running after cancel")
            let atCancel = model.resultCount
            let scanned = SearchDiagnostics.snapshot.pagesScanned
            try await Task.sleep(for: .milliseconds(500))
            #expect(model.resultCount == atCancel)
            #expect(SearchDiagnostics.snapshot.pagesScanned == scanned)
            #expect(atCancel < 1500)

            // Continue resumes where it stopped: no page is searched twice, none skipped.
            model.continueSearch()
            #expect(model.phase == .searching)
            #expect(await Support.waitUntil { model.resultCount > atCancel + 5 })
            model.cancel()
            let pages = model.orderedResults.map(\.pageIndex)
            #expect(pages == Array(0..<pages.count))
            #expect(await Support.waitUntilEngineIdle(timeout: 2))
        }

        /// A new query cancels the old search's worker (it is not merely ignored): over the whole
        /// test the engine scans the old query's pages up to the change plus one full scan.
        @Test func newQueryCancelsTheOldOne() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session, hitCap: 5_000, pageDelay: .milliseconds(2))
            let before = SearchDiagnostics.snapshot.pagesScanned
            model.query = "Fixture page"
            #expect(await Support.waitUntil { model.resultCount >= 3 })
            let scannedForOld = SearchDiagnostics.snapshot.pagesScanned - before
            model.query = "zygomorphic lighthouse theorem"
            #expect(model.phase == .searching)
            #expect(model.resultCount == 0)               // the old results went at once
            #expect(await Support.waitUntil(timeout: 60) { model.phase == .finished })
            #expect(await Support.waitUntilEngineIdle())
            #expect(model.searchedQuery == "zygomorphic lighthouse theorem")
            #expect(model.orderedResults.map(\.pageIndex) == [1399])
            let total = SearchDiagnostics.snapshot.pagesScanned - before
            // The old worker may finish the page it was on (and a few while the change lands).
            #expect(total <= scannedForOld + 1500 + 10, "old: \(scannedForOld), total: \(total)")
        }

        @Test func closingThePanelCancelsTheSearch() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session, hitCap: 5_000, pageDelay: .milliseconds(3))
            model.panelDidAppear()
            model.query = "Fixture page"
            #expect(await Support.waitUntil { model.resultCount >= 3 })
            model.panelDidDisappear()
            #expect({ if case .cancelled = model.phase { true } else { false } }())
            #expect(await Support.waitUntilEngineIdle(timeout: 2))
        }

        /// When the window's session goes away mid-search, the model goes with it and the
        /// engine's worker stops; nothing keeps running.
        @Test func releasingTheModelStopsTheSearch() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let session = Support.makeSession(fixture)
            weak var weakModel: SearchModel?
            do {
                let model = Support.makeModel(session, hitCap: 5_000, pageDelay: .milliseconds(3))
                weakModel = model
                model.query = "Fixture page"
                #expect(await Support.waitUntil { model.resultCount >= 3 })
                #expect(SearchDiagnostics.snapshot.liveWorkers == 1)
            }
            #expect(await Support.waitUntil(timeout: 2) { weakModel == nil }, "the model was not released")
            #expect(await Support.waitUntilEngineIdle(timeout: 2), "worker still running after release")
            let scanned = SearchDiagnostics.snapshot.pagesScanned
            try await Task.sleep(for: .milliseconds(300))
            #expect(SearchDiagnostics.snapshot.pagesScanned == scanned)
        }

        @Test func clearingTheQueryResets() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session)
            model.query = "fixture"  // "Fixture page N" and the running header on every page
            #expect(await Support.waitUntil { model.phase == .finished })
            #expect(model.resultCount == 24)
            model.clear()
            #expect(model.phase == .idle)
            #expect(model.groups.isEmpty)
            model.query = "x"  // too short to search
            #expect(model.phase == .idle)
            #expect(model.isQueryTooShort)
        }

        @Test func capThenShowMoreResults() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session, hitCap: 100)
            model.query = "fixture PAGE"
            #expect(await Support.waitUntil { model.phase == .capped(nextPage: 100) })
            #expect(model.textHitCount == 100)
            #expect(model.pagesSearched == 100)
            model.continueSearch()
            #expect(await Support.waitUntil { model.phase == .capped(nextPage: 200) })
            #expect(model.textHitCount == 200)
            #expect(model.orderedResults.map(\.pageIndex) == Array(0..<200))
        }

        // MARK: Matching and grouping

        @Test func caseAndDiacriticInsensitiveOnPages() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session)
            for query in ["QUICK AMBER FOX", "quíck ámber fóx", "quick\namber   fox"] {
                model.query = query
                #expect(await Support.waitUntil { model.phase == .finished }, "\(query)")
                #expect(model.orderedResults.map(\.pageIndex) == [2], "\(query)")
                #expect(model.orderedResults.first?.snippet.match == "quick amber fox")
            }
        }

        @Test func groupsHitsByDeepestHeadingInOutlineOrder() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let model = Support.makeModel(session)
            model.query = "quick amber fox"
            #expect(await Support.waitUntil { model.phase == .finished })
            #expect(model.groups.map(\.title) == ["1.1 Foundations"])  // pages 2-3
            #expect(model.groups.first?.ancestorTitles == ["1 Linear Systems"])

            // "Fixture page" is on every page: one group per heading with pages, in outline order.
            model.query = "fixture page"
            #expect(await Support.waitUntil { model.phase == .finished && model.resultCount == 12 })
            #expect(model.groups.map(\.title) == ["1 Linear Systems", "1.1 Foundations", "1.2 Exercises",
                                                  "2 Vector Spaces", "2.1 Foundations", "2.2 Exercises",
                                                  "3 Eigenvalues", "3.1 Foundations", "3.2 Exercises"])
            #expect(model.groups.map { $0.results.count } == [1, 2, 1, 1, 2, 1, 1, 2, 1])
            let pages = model.orderedResults.map(\.pageIndex)
            #expect(pages == Array(0..<12))
        }

        /// Searching before the outline has loaded still works; the groups follow the outline
        /// once it arrives (no panel needed to trigger it).
        @Test func groupsFollowTheOutlineWhenItLoadsLater() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            let model = Support.makeModel(session)
            model.query = "quick amber fox"
            #expect(await Support.waitUntil { model.phase == .finished })
            #expect(model.groups.map(\.title) == ["pp. 1–12"])  // no outline yet: page ranges
            #expect(await Support.openAndWaitForOutline(session))
            #expect(await Support.waitUntil { model.groups.map(\.title) == ["1.1 Foundations"] })
        }

        @Test func pagesBeforeTheFirstHeadingFormAFrontMatterGroup() {
            let outline = Outline(pdfEntries: [RawOutlineEntry(title: "One", level: 1, pageIndex: 5),
                                               RawOutlineEntry(title: "Two", level: 1, pageIndex: 8)], pageCount: 12)
            func result(_ page: Int) -> SearchResult {
                SearchResult(id: "t\(page)", kind: .text, pageIndex: page,
                             snippet: SearchSnippet(before: "", match: "x", after: ""))
            }
            let groups = SearchGrouping.group([result(9), result(1), result(5), result(0)], outline: outline,
                                              pageCount: 12)
            #expect(groups.map(\.title) == [SearchGrouping.frontMatterTitle, "One", "Two"])
            #expect(groups.map(\.kind) == [.frontMatter, .heading(level: 1), .heading(level: 1)])
            #expect(groups.map { $0.results.map(\.pageIndex) } == [[0, 1], [5], [9]])
        }

        /// A book without an outline is grouped in fixed 50-page ranges ("pp. 1–50", …).
        @Test func booksWithoutAnOutlineGroupByPageRanges() async throws {
            let fixture = try Support.makeFixture("no-outline.pdf", pages: 40)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            #expect(session.outline.isEmpty)
            let model = Support.makeModel(session)
            model.query = "fixture page"
            #expect(await Support.waitUntil { model.phase == .finished })
            #expect(model.resultCount == 40)
            #expect(model.groups.map(\.title) == ["pp. 1–40"])
            #expect(model.groups.first?.kind == .pageRange)

            func result(_ page: Int) -> SearchResult {
                SearchResult(id: "t\(page)", kind: .text, pageIndex: page,
                             snippet: SearchSnippet(before: "", match: "x", after: ""))
            }
            let groups = SearchGrouping.group([result(0), result(49), result(50), result(1499)], outline: .empty,
                                              pageCount: 1500)
            #expect(groups.map(\.title) == ["pp. 1–50", "pp. 51–100", "pp. 1451–1500"])
        }

        // MARK: Notes and highlights

        @Test func notesAndHighlightsAreSearchedAndKeptCurrent() async throws {
            let fixture = try Support.makeFixture("small.pdf", pages: 12)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let bookID = fixture.book.id
            let chapter = try #require(session.outline.nodes.first { $0.title == "2 Vector Spaces" })
            let store = fixture.store

            try store.notes.save(Note(bookID: bookID, target: .page(6), text: "Remember the QUICK ámber detour here."))
            try store.notes.save(Note(bookID: bookID, target: .heading(chapter.anchor), text: "Chapter summary: amber"))
            try store.notes.save(Note(bookID: bookID, target: .page(7), text: "unrelated"))
            try store.highlights.save(Highlight(bookID: bookID, pageIndex: 8,
                                                rects: [CGRect(x: 72, y: 600, width: 200, height: 14)],
                                                color: .yellow, text: "an Amber highlight"))

            let model = Support.makeModel(session)
            model.query = "amber"
            #expect(await Support.waitUntil { model.phase == .finished })
            var results = model.orderedResults
            #expect(results.filter { $0.kind == .text }.map(\.pageIndex) == [2])
            let pageNote = try #require(results.first { $0.kind == .note && $0.noteTarget?.pageIndex == 6 })
            #expect(pageNote.snippet.match == "ámber")
            let headingNote = try #require(results.first { $0.noteTarget?.headingAnchor != nil })
            #expect(headingNote.pageIndex == chapter.startPage)
            let highlight = try #require(results.first { $0.kind == .highlight })
            #expect(highlight.pageIndex == 8)
            #expect(highlight.snippet.match == "Amber")
            #expect(results.count == 4)
            #expect(model.annotationResultCount == 3)

            // The heading note heads its heading's group; the page note sits in its subsection.
            let chapterGroup = try #require(model.groups.first { $0.title == "2 Vector Spaces" })
            #expect(chapterGroup.results.first?.id == headingNote.id)
            let section = try #require(model.groups.first { $0.title == "2.1 Foundations" })
            #expect(section.results.contains { $0.id == pageNote.id })

            // Live updates, with no call from outside: an edit in this window…
            var stored = try #require(try store.notes.note(bookID: bookID, target: .page(6)))
            stored.text = "nothing to see"
            try session.perform { _ = try $0.notes.save(stored) }
            #expect(await Support.waitUntil(timeout: 5) { !model.orderedResults.contains { $0.id == pageNote.id } })

            // …a note and a highlight from another window…
            let otherWindow = ChangeOrigin(label: "another window")
            try store.perform(as: otherWindow) {
                _ = try store.notes.save(Note(bookID: bookID, target: .page(10), text: "AMBER, again"))
            }
            #expect(await Support.waitUntil(timeout: 5) {
                model.orderedResults.contains { $0.kind == .note && $0.noteTarget?.pageIndex == 10 }
            })
            let highlightID = try #require(try store.highlights.highlights(bookID: bookID).first?.id)
            try store.perform(as: otherWindow) { try store.highlights.deleteHighlight(id: highlightID) }
            #expect(await Support.waitUntil(timeout: 5) { !model.orderedResults.contains { $0.kind == .highlight } })

            // …and the text hits are untouched by all of it.
            results = model.orderedResults
            #expect(results.filter { $0.kind == .text }.map(\.pageIndex) == [2])
            #expect(model.phase == .finished)
        }

        // MARK: Windows

        /// Two windows on one book: two sessions, two models, two workers with their own
        /// documents; cancelling one does not touch the other.
        @Test func twoWindowsSearchIndependently() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            #expect(await Support.waitUntilEngineIdle())
            let first = Support.makeSession(fixture)
            let second = Support.makeSession(fixture)
            #expect(first.searchModel !== second.searchModel)
            let slow = SearchModel(session: first, hitCap: 5_000, pageDelay: .milliseconds(3))
            slow.debounce = .zero
            let fast = Support.makeModel(second)
            slow.query = "Fixture page"
            fast.query = "zygomorphic lighthouse theorem"
            #expect(await Support.waitUntil { slow.resultCount >= 3 && SearchDiagnostics.snapshot.liveWorkers == 2 })
            #expect(SearchDiagnostics.snapshot.liveDocuments == 2)
            slow.cancel()
            #expect(await Support.waitUntil(timeout: 60) { fast.phase == .finished })
            #expect(fast.orderedResults.map(\.pageIndex) == [1399])
            #expect({ if case .cancelled = slow.phase { true } else { false } }())
            #expect(slow.orderedResults.allSatisfy { $0.snippet.match.lowercased() == "fixture page" })
            #expect(await Support.waitUntilEngineIdle())
        }

        // MARK: Main-thread cost

        /// Applying streamed results costs the main thread little: the longest single update
        /// (regrouping every result so far) is measured in thread CPU time, so it does not depend
        /// on machine load. Also reports the longest gap of a 10 ms main-actor heartbeat.
        @Test func applyingResultsIsCheapOnTheMainThread() async throws {
            let fixture = try Support.makeFixture("large.pdf", pages: 1500)
            defer { fixture.cleanUp() }
            let session = Support.makeSession(fixture)
            #expect(await Support.openAndWaitForOutline(session))
            let model = Support.makeModel(session, hitCap: 5_000)
            model.query = "Fixture page"
            var maxGap: Duration = .zero
            var last = ContinuousClock.now
            while model.phase != .finished {
                try await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                maxGap = max(maxGap, now - last)
                last = now
                if case .failed = model.phase { break }
            }
            #expect(model.resultCount == 1500)
            let cost = model.updateCost
            #expect(cost.updates > 3)
            #expect(cost.longest < .milliseconds(16), "longest update \(cost.longest)")
            print("SEARCH-MAIN updates \(cost.updates), longest \(cost.longest), total \(cost.total) (thread CPU); "
                  + "longest heartbeat gap \(maxGap), load \(Support.loadAverage())")
        }
    }
}
