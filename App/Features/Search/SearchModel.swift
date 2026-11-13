import Foundation
import Observation
import ReaderCore

/// One reader window's search: query, streamed results, progress and the selected hit. Created
/// on first use through `ReaderSession.searchModel` and kept for the session's lifetime, so
/// closing and reopening the panel (or pressing Next/Previous Result with the panel closed)
/// finds the same results. Two windows have two models.
@Observable
@MainActor
final class SearchModel {
    /// Where the search is.
    enum Phase: Equatable {
        /// Nothing searched (empty or too-short query).
        case idle
        case searching
        /// Every page was searched.
        case finished
        /// The hit cap was reached; `nextPage` is where "Show more results…" resumes.
        case capped(nextPage: Int)
        /// Stopped by the reader (Stop) or by closing the panel; `nextPage` is where Continue resumes.
        case stopped(nextPage: Int)
        case failed
    }

    /// Shortest query that searches.
    nonisolated static let minimumQueryLength = 2

    // MARK: State

    /// The search field's text. Setting it cancels the running search and, after `debounce`,
    /// starts a new one.
    var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }

    private(set) var phase: Phase = .idle
    private(set) var pagesSearched = 0
    private(set) var totalPages = 0
    /// Results in display order, grouped by heading (see `SearchGrouping`).
    private(set) var groups: [SearchGroup] = []
    /// The result last chosen (shown selected; Next/Previous step from it).
    private(set) var selectedResultID: String?
    /// Text hits so far (the cap applies to these).
    private(set) var textHitCount = 0
    /// Notes plus highlights that match.
    private(set) var annotationResultCount = 0

    var resultCount: Int { textHitCount + annotationResultCount }
    var isSearching: Bool { phase == .searching }
    /// The query that produced the current results.
    private(set) var searchedQuery = ""

    /// Wait after the last keystroke before searching.
    var debounce: Duration = .milliseconds(300)

    // MARK: Private

    private unowned let session: ReaderSession
    private var textHits: [SearchHit] = []
    private var annotationResults: [SearchResult] = []
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var markClearTask: Task<Void, Never>?
    private var runID = 0
    private let pageDelay: Duration
    private let hitCap: Int

    init(session: ReaderSession, hitCap: Int = PDFTextSearch.defaultHitCap, pageDelay: Duration? = nil) {
        self.session = session
        self.hitCap = hitCap
        // Test hook: `-searchPageDelayMs <n>` slows the text search so a UI test can stop it midway.
        let ms = UserDefaults.standard.integer(forKey: "searchPageDelayMs")
        self.pageDelay = pageDelay ?? .milliseconds(ms)
    }

    // MARK: Query

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isQueryTooShort: Bool { !trimmedQuery.isEmpty && trimmedQuery.count < Self.minimumQueryLength }

    private func queryDidChange() {
        debounceTask?.cancel()
        cancelRun()
        guard trimmedQuery.count >= Self.minimumQueryLength else {
            reset()
            return
        }
        debounceTask = Task { [weak self, debounce] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            self?.startSearch()
        }
    }

    /// Return on the keyboard: search now instead of waiting for the debounce.
    func submit() {
        debounceTask?.cancel()
        guard trimmedQuery.count >= Self.minimumQueryLength else { return }
        startSearch()
    }

    /// Empties the field and the results (the field's clear button).
    func clear() {
        query = ""
    }

    private func reset() {
        textHits = []
        annotationResults = []
        searchedQuery = ""
        phase = .idle
        pagesSearched = 0
        selectedResultID = nil
        regroup()
        clearMarks()
    }

    // MARK: Running

    /// Cancels any running search and searches for the current query from the first page.
    func startSearch() {
        cancelRun()
        guard trimmedQuery.count >= Self.minimumQueryLength else { return }
        textHits = []
        selectedResultID = nil
        searchedQuery = trimmedQuery
        pagesSearched = 0
        totalPages = session.pageCount
        refreshAnnotations(regroup: false)
        regroup()
        clearMarks()
        run(from: 0)
    }

    /// Resumes a capped or stopped search where it left off.
    func continueSearch() {
        switch phase {
        case .capped(let next), .stopped(let next):
            cancelRun()
            run(from: next)
        default:
            break
        }
    }

    /// Stops the running search, keeping the results found so far.
    func stop() {
        guard phase == .searching else { return }
        cancelRun()
        phase = .stopped(nextPage: pagesSearched)
    }

    /// The panel closed: a running search stops (it can be continued on reopening).
    func panelDidClose() {
        debounceTask?.cancel()
        if phase == .searching { stop() }
    }

    private func run(from startPage: Int) {
        runID += 1
        let id = runID
        phase = .searching
        let stream = PDFTextSearch.stream(url: session.documentURL, query: searchedQuery, startPage: startPage,
                                          hitCap: hitCap, pageDelay: pageDelay)
        searchTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled, self.runID == id else { return }
                self.apply(event)
            }
        }
    }

    private func cancelRun() {
        runID += 1
        searchTask?.cancel()
        searchTask = nil
    }

    private func apply(_ event: SearchEvent) {
        switch event {
        case .hits(let hits):
            textHits.append(contentsOf: hits)
            textHitCount = textHits.count
            regroup()
        case .progress(let searched, let total):
            pagesSearched = searched
            totalPages = total
        case .finished(let completion):
            switch completion.reason {
            case .completed: phase = .finished
            case .capped: phase = .capped(nextPage: completion.nextPage)
            case .failed: phase = .failed
            }
        }
    }

    // MARK: Notes and highlights

    /// Re-reads matching notes and highlights from the store (call when they change, and when
    /// the outline finishes loading, which heading notes need).
    func refreshAnnotations(regroup shouldRegroup: Bool = true) {
        guard !searchedQuery.isEmpty else { return }
        annotationResults = AnnotationSearch.results(query: searchedQuery, bookID: session.book.id,
                                                     store: session.store, outline: session.outline)
        annotationResultCount = annotationResults.count
        if shouldRegroup { regroup() }
    }

    /// Re-groups after the outline changed.
    func outlineDidChange() {
        refreshAnnotations(regroup: false)
        regroup()
    }

    private func regroup() {
        let all = textHits.map(SearchResult.init(hit:)) + annotationResults
        groups = SearchGrouping.group(all, outline: session.outline, pageCount: session.pageCount)
        annotationResultCount = annotationResults.count
        textHitCount = textHits.count
    }

    // MARK: Selection

    /// Results in display order (the order of the groups).
    var orderedResults: [SearchResult] { groups.flatMap(\.results) }

    func result(withID id: String) -> SearchResult? {
        for group in groups {
            if let found = group.results.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Goes to a result through the session's jump API (so the jump is recorded in section
    /// history) and marks it. Text hits are marked on the page; a note opens the notes panel on
    /// its page or section; a highlight scrolls to its text.
    func select(_ result: SearchResult) {
        selectedResultID = result.id
        switch result.kind {
        case .text:
            session.jump(toPage: result.pageIndex, revealing: result.rects, mark: true)
            scheduleMarkClear()
        case .highlight:
            session.pdf.clearMarks()
            session.jump(toPage: result.pageIndex, revealing: result.rects, mark: false)
        case .note:
            session.pdf.clearMarks()
            switch result.noteTarget {
            case .heading(let anchor):
                session.jump(toHeading: anchor)
                session.showNotes(.section)
            default:
                session.jump(toPage: result.pageIndex)
                session.showNotes(.page)
            }
        }
    }

    var canStep: Bool { !orderedResults.isEmpty }

    /// Next result after the selected one (the first when nothing is selected), wrapping.
    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        let results = orderedResults
        guard !results.isEmpty else { return }
        let current = selectedResultID.flatMap { id in results.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = (current + delta + results.count) % results.count
        } else {
            next = delta > 0 ? 0 : results.count - 1
        }
        select(results[next])
    }

    // MARK: Marks

    /// Search marks fade after a while; they are not meant to stay on the page.
    private func scheduleMarkClear() {
        markClearTask?.cancel()
        markClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.session.pdf.clearMarks()
        }
    }

    private func clearMarks() {
        markClearTask?.cancel()
        session.pdf.clearMarks()
    }
}

extension ReaderSession {
    /// This window's search (created on first use). The menu bar's Next/Previous Result commands
    /// call `searchModel.selectNext()` / `selectPrevious()`.
    var searchModel: SearchModel {
        featureState { SearchModel(session: self) }
    }
}
