import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// Search engine, grouping, annotations and the per-window model, on the generated fixtures
/// (`scripts/test.sh` generates them first).
@MainActor
struct SearchEngineTests {
    // MARK: Fixtures

    struct Fixture {
        let store: LibraryStore
        let book: Book
        let url: URL
    }

    private static let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/out")

    private func makeFixture(_ name: String, pages: Int) throws -> Fixture {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: name, fingerprint: "test-\(UUID().uuidString)", fileName: name, pageCount: pages,
                        fileSize: 1)
        try store.books.save(book)
        let url = store.documentURL(for: book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixturesDir.appendingPathComponent(name), to: url)
        return Fixture(store: store, book: book, url: url)
    }

    private func makeSession(_ fixture: Fixture) -> ReaderSession {
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        configuration.notebookRebuildDelay = .milliseconds(10)
        return ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.store.rootDirectory)
    }

    private func waitUntil(timeout: Double = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Runs the engine to completion and collects everything it reports.
    private func collect(_ url: URL, _ query: String, hitCap: Int = PDFTextSearch.defaultHitCap)
        async -> (hits: [SearchHit], completion: SearchCompletion?) {
        var hits: [SearchHit] = []
        var completion: SearchCompletion?
        for await event in PDFTextSearch.stream(url: url, query: query, hitCap: hitCap) {
            switch event {
            case .hits(let batch): hits += batch
            case .progress: break
            case .finished(let c): completion = c
            }
        }
        return (hits, completion)
    }

    // MARK: Matcher

    @Test func matcherFoldsCaseDiacriticsAndWhitespace() {
        var matcher = SearchTextMatcher()
        let text = "The Café   was near\nthe NAÏVE lighthouse\ntheorem, and the ﬁnal CAFE."
        let folded = matcher.fold(text)
        let ns = text as NSString

        let cafe = SearchTextMatcher.matches(of: matcher.foldQuery("cafe"), in: folded)
        #expect(cafe.map { ns.substring(with: $0) } == ["Café", "CAFE"])

        let naive = SearchTextMatcher.matches(of: matcher.foldQuery("naive LIGHTHOUSE"), in: folded)
        #expect(naive.map { ns.substring(with: $0) } == ["NAÏVE lighthouse"])

        // A line wrap between two words matches a single space in the query.
        let wrapped = SearchTextMatcher.matches(of: matcher.foldQuery("lighthouse theorem"), in: folded)
        #expect(wrapped.count == 1)
        #expect(ns.substring(with: wrapped[0]) == "lighthouse\ntheorem")

        // Ligature expansion.
        #expect(SearchTextMatcher.matches(of: matcher.foldQuery("final"), in: folded).count == 1)
        #expect(SearchTextMatcher.matches(of: matcher.foldQuery("zebra"), in: folded).isEmpty)
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

    // MARK: Engine

    @Test func findsPhraseOnPage1400OfLargeFixture() async throws {
        let fixture = try makeFixture("large.pdf", pages: 1500)
        defer { cleanUp(fixture) }
        let result = await collect(fixture.url, "Zygomorphic Lighthouse Theorem")
        #expect(result.hits.count == 1)
        let hit = try #require(result.hits.first)
        #expect(hit.pageIndex == 1399)
        #expect(!hit.rects.isEmpty)
        #expect(hit.rects.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(hit.snippet.match.lowercased() == "zygomorphic lighthouse theorem")
        #expect(result.completion == SearchCompletion(reason: .completed, nextPage: 1500))
    }

    @Test func resultsStreamBeforeTheSearchCompletes() async throws {
        let fixture = try makeFixture("large.pdf", pages: 1500)
        defer { cleanUp(fixture) }
        var firstHitAtPagesSearched: Int?
        var searched = 0
        var finished = false
        var hitCount = 0
        for await event in PDFTextSearch.stream(url: fixture.url, query: "Fixture page", hitCap: 5_000) {
            switch event {
            case .hits(let batch):
                hitCount += batch.count
                if firstHitAtPagesSearched == nil { firstHitAtPagesSearched = searched }
            case .progress(let pages, _): searched = pages
            case .finished: finished = true
            }
        }
        #expect(finished)
        #expect(hitCount == 1500)
        // The first hit was delivered long before the 1,500th page was scanned.
        #expect((firstHitAtPagesSearched ?? .max) < 100)
    }

    @Test func hitCapStopsAndContinuationResumes() async throws {
        let fixture = try makeFixture("large.pdf", pages: 1500)
        defer { cleanUp(fixture) }
        let first = await collect(fixture.url, "Fixture page", hitCap: 100)
        #expect(first.hits.count == 100)
        #expect(first.completion == SearchCompletion(reason: .capped, nextPage: 100))
        var more: [SearchHit] = []
        for await event in PDFTextSearch.stream(url: fixture.url, query: "Fixture page", startPage: 100, hitCap: 100) {
            if case .hits(let batch) = event { more += batch }
        }
        #expect(more.first?.pageIndex == 100)
        #expect(more.count == 100)
    }

    @Test func measureTimings() async throws {
        let fixture = try makeFixture("large.pdf", pages: 1500)
        defer { cleanUp(fixture) }
        var lines: [String] = []
        for (label, query, cap) in [("rare", "zygomorphic lighthouse theorem", 500), ("common", "the", 500),
                                    ("common-uncapped", "the", 1_000_000), ("every-page", "Fixture page", 500)] {
            let start = ContinuousClock.now
            var first: Duration?
            var count = 0
            for await event in PDFTextSearch.stream(url: fixture.url, query: query, hitCap: cap) {
                if case .hits(let batch) = event {
                    if first == nil { first = ContinuousClock.now - start }
                    count += batch.count
                }
            }
            let total = ContinuousClock.now - start
            lines.append("\(label) '\(query)': first=\(first.map { "\($0)" } ?? "none") total=\(total) hits=\(count)")
        }
        let out = Self.fixturesDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/search-timings.txt")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Model: cancel, replace, grouping

    @Test func stopCancelsFurtherResults() async throws {
        let fixture = try makeFixture("large.pdf", pages: 1500)
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        let model = SearchModel(session: session, hitCap: 5_000, pageDelay: .milliseconds(5))
        model.debounce = .zero
        model.query = "Fixture page"
        #expect(await waitUntil { model.resultCount >= 3 })
        model.stop()
        let atStop = model.resultCount
        let searchedAtStop = model.pagesSearched
        guard case .stopped(let next) = model.phase else {
            Issue.record("expected stopped, got \(model.phase)")
            return
        }
        #expect(next == searchedAtStop)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.resultCount == atStop)
        #expect(model.pagesSearched == searchedAtStop)
        #expect(atStop < 1500)

        // Continue resumes from where it stopped.
        model.continueSearch()
        #expect(await waitUntil { model.resultCount > atStop })
        model.stop()
    }

    @Test func newQueryCancelsTheOldOne() async throws {
        let fixture = try makeFixture("large.pdf", pages: 1500)
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        let model = SearchModel(session: session, hitCap: 5_000, pageDelay: .milliseconds(1))
        model.debounce = .zero
        model.query = "Fixture page"
        #expect(await waitUntil { model.resultCount >= 3 })
        model.query = "zygomorphic lighthouse theorem"
        #expect(await waitUntil(timeout: 30) { model.phase == .finished })
        #expect(model.searchedQuery == "zygomorphic lighthouse theorem")
        #expect(model.resultCount == 1)
        #expect(model.orderedResults.first?.pageIndex == 1399)
        // Nothing from the first query arrives afterwards.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.resultCount == 1)
    }

    @Test func clearingTheQueryResetsAndCancels() async throws {
        let fixture = try makeFixture("small.pdf", pages: 12)
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        let model = SearchModel(session: session)
        model.debounce = .zero
        model.query = "fixture"
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.resultCount > 0)
        model.clear()
        #expect(model.phase == .idle)
        #expect(model.groups.isEmpty)
        model.query = "x"  // too short to search
        #expect(model.phase == .idle)
        #expect(model.isQueryTooShort)
    }

    @Test func groupsHitsByDeepestHeadingInOutlineOrder() async throws {
        let fixture = try makeFixture("small.pdf", pages: 12)
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        let model = SearchModel(session: session)
        model.debounce = .zero
        model.query = "QUICK AMBER FOX"  // case-insensitive; page 3 (index 2)
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.resultCount == 1)
        let group = try #require(model.groups.first)
        #expect(model.groups.count == 1)
        #expect(group.title == "1.1 Foundations")  // pages 2-3
        #expect(group.results.first?.pageIndex == 2)

        // "Fixture page" is on every page: one group per heading with pages, in outline order.
        model.query = "fixture page"
        #expect(await waitUntil { model.phase == .finished && model.resultCount == 12 })
        let titles = model.groups.map(\.title)
        #expect(titles == ["1 Linear Systems", "1.1 Foundations", "1.2 Exercises", "2 Vector Spaces",
                           "2.1 Foundations", "2.2 Exercises", "3 Eigenvalues", "3.1 Foundations", "3.2 Exercises"])
        #expect(model.groups.map(\.results.count).reduce(0, +) == 12)
        // Results inside each group are in page order, and groups ascend by page.
        let pages = model.orderedResults.map(\.pageIndex)
        #expect(pages == pages.sorted())
    }

    @Test func pagesBeforeTheFirstHeadingFormAFrontMatterGroup() {
        let outline = Outline(pdfEntries: [RawOutlineEntry(title: "One", level: 1, pageIndex: 5),
                                           RawOutlineEntry(title: "Two", level: 1, pageIndex: 8)], pageCount: 12)
        func result(_ page: Int) -> SearchResult {
            SearchResult(id: "t\(page)", kind: .text, pageIndex: page,
                         snippet: SearchSnippet(before: "", match: "x", after: ""))
        }
        let groups = SearchGrouping.group([result(9), result(1), result(5), result(0)], outline: outline, pageCount: 12)
        #expect(groups.map(\.title) == [SearchGrouping.frontMatterTitle, "One", "Two"])
        #expect(groups.map(\.results.count) == [2, 1, 1])
    }

    @Test func booksWithoutAnOutlineGroupByPageRanges() async throws {
        let fixture = try makeFixture("no-outline.pdf", pages: 40)
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        #expect(session.outline.isEmpty)
        let model = SearchModel(session: session)
        model.debounce = .zero
        model.query = "fixture page"
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.resultCount == 40)
        #expect(model.groups.map(\.title) == ["pp. 1–40"])

        // The range size splits larger books.
        func result(_ page: Int) -> SearchResult {
            SearchResult(id: "t\(page)", kind: .text, pageIndex: page,
                         snippet: SearchSnippet(before: "", match: "x", after: ""))
        }
        let groups = SearchGrouping.group([result(0), result(49), result(50), result(1499)], outline: .empty,
                                          pageCount: 1500)
        #expect(groups.map(\.title) == ["pp. 1–50", "pp. 51–100", "pp. 1451–1500"])
    }

    // MARK: Notes and highlights

    @Test func notesAndHighlightsAreSearchedAlongside() async throws {
        let fixture = try makeFixture("small.pdf", pages: 12)
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        let bookID = fixture.book.id
        let sectionNode = try #require(session.outline.nodes.first { $0.title == "2 Vector Spaces" })

        try fixture.store.notes.save(Note(bookID: bookID, target: .page(6),
                                          text: "Remember the QUICK amber detour here."))
        try fixture.store.notes.save(Note(bookID: bookID, target: .heading(sectionNode.anchor),
                                          text: "Chapter summary: amber fox"))
        try fixture.store.notes.save(Note(bookID: bookID, target: .page(7), text: "unrelated"))
        try fixture.store.highlights.save(Highlight(bookID: bookID, pageIndex: 8,
                                                    rects: [CGRect(x: 72, y: 600, width: 200, height: 14)],
                                                    color: .yellow, text: "an Amber highlight"))

        let model = SearchModel(session: session)
        model.debounce = .zero
        model.query = "amber"
        #expect(await waitUntil { model.phase == .finished })
        let results = model.orderedResults
        #expect(results.filter { $0.kind == .text }.count == 1)  // the page 3 phrase
        let note = try #require(results.first { $0.kind == .note && $0.noteTarget?.pageIndex == 6 })
        #expect(note.snippet.match == "amber")
        let headingNote = try #require(results.first { $0.noteTarget?.headingAnchor != nil })
        #expect(headingNote.pageIndex == sectionNode.startPage)
        let highlight = try #require(results.first { $0.kind == .highlight })
        #expect(highlight.pageIndex == 8)
        #expect(highlight.snippet.match == "Amber")
        #expect(results.count == 4)

        // The heading note sits first in its heading's group; the page note in the subsection.
        let chapterGroup = try #require(model.groups.first { $0.title == "2 Vector Spaces" })
        #expect(chapterGroup.results.first?.noteTarget?.headingAnchor == sectionNode.anchor)
        let subGroup = try #require(model.groups.first { $0.title == "2.1 Foundations" })
        #expect(subGroup.results.contains { $0.id == note.id })

        // Changing a note updates the results.
        var stored = try #require(try fixture.store.notes.note(bookID: bookID, target: .page(6)))
        stored.text = "nothing"
        try fixture.store.notes.save(stored)
        model.refreshAnnotations()
        #expect(model.orderedResults.filter { $0.kind == .note }.count == 1)
    }
}
