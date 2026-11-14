import Foundation
import Observation
import ReaderCore

/// One reader window's search: query, streamed results, progress and the chosen result.
///
/// Created on first use through `ReaderSession.searchModel` and kept for the session's lifetime,
/// so closing and reopening the panel shows the same results. Two windows have two sessions and
/// so two models, each with its own engine runs and private documents: they never share or
/// cancel each other's work.
///
/// ## Lifecycle (nothing outlives the window)
/// - Editing the query cancels the running search at once and, after `debounce`, starts a new
///   one (Return starts it immediately). A query shorter than `minimumQueryLength` clears.
/// - Closing the panel cancels a running search (the results so far stay; "Continue" resumes).
/// - When the window's session goes away the model goes with it, and its `deinit` cancels every
///   task it started, which ends the engine's stream and stops its worker before the next page.
///
/// ## Search marks on the page
/// Choosing a text result jumps to it and marks the match (`session.jump(toPage:revealing:mark:)`).
/// The mark stays while the reader looks at it, and is cleared when: another result is chosen;
/// a new search starts or the query is cleared; the panel is dismissed without choosing a result
/// (Done, or tapping outside it); or the reader taps the page.
///
/// ## Notes and highlights
/// Matched alongside the text (`AnnotationSearch`), re-read whenever this book's notes or
/// highlights change in any window (store change hub), and regrouped whenever the outline
/// changes (user headings added in any window).
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
        /// The hit cap was reached; `nextPage` is where "Show More Results" resumes.
        case capped(nextPage: Int)
        /// Cancelled by the reader (Cancel) or by closing the panel; `nextPage` is where
        /// Continue resumes.
        case cancelled(nextPage: Int)
        /// The book's file could not be opened.
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
    /// Pages scanned so far (absolute: a continued search counts from the start of the book).
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
    /// The query that produced the current results.
    private(set) var searchedQuery = ""

    var resultCount: Int { textHitCount + annotationResultCount }
    var isSearching: Bool { phase == .searching }

    /// Main-thread cost of applying streamed hits (regrouping), in thread CPU time, since the
    /// current search started. For diagnostics and the responsiveness test.
    struct UpdateCost: Equatable {
        var updates = 0
        var longest: Duration = .zero
        var total: Duration = .zero
    }

    @ObservationIgnored private(set) var updateCost = UpdateCost()

    /// Wait after the last keystroke before searching.
    @ObservationIgnored var debounce: Duration = .milliseconds(300)

    // MARK: Private

    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private var textHits: [SearchHit] = []
    @ObservationIgnored private var annotationResults: [SearchResult] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var annotationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var changeObservation: StoreChangeObservation?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var hasMark = false
    /// A result chosen in the panel whose navigation waits until the panel has gone (opening the
    /// notes sheet while the popover is still dismissing would fail).
    @ObservationIgnored private var pendingSelection: SearchResult?
    @ObservationIgnored private var closingAfterChoice = false
    @ObservationIgnored private let pageDelay: Duration
    @ObservationIgnored private let hitCap: Int

    init(session: ReaderSession, hitCap: Int = PDFTextSearch.defaultHitCap, pageDelay: Duration? = nil) {
        self.session = session
        self.hitCap = hitCap
        // Test hook: the UI tests' `-searchPageDelayMs <n>` launch argument (read through the
        // arguments domain of `UserDefaults`) slows the scan so a test can act mid-search.
        let ms = UserDefaults.standard.integer(forKey: "searchPageDelayMs")
        self.pageDelay = pageDelay ?? .milliseconds(max(0, ms))
        totalPages = session.pageCount

        changeObservation = session.observeBookChanges(includeOwn: true) { [weak self] event in
            switch event.change {
            case .noteSaved, .noteRemoved, .highlightsChanged:
                self?.scheduleAnnotationRefresh()
            default:
                break
            }
        }
        session.pdf.addTapHandler(self)
        observeOutline()
    }

    deinit {
        // Nonisolated (an isolated deinit needs a newer runtime than iPadOS 17); `Task` handles
        // are Sendable and cancelling is thread-safe. Ending `searchTask` ends the engine's stream,
        // which stops its worker.
        debounceTask?.cancel()
        searchTask?.cancel()
        annotationRefreshTask?.cancel()
    }

    // MARK: Query

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isQueryTooShort: Bool { !trimmedQuery.isEmpty && trimmedQuery.count < Self.minimumQueryLength }

    /// A keystroke: the old search stops and its results go at once (the list shows the search
    /// as pending rather than stale matches); the new one starts after the debounce.
    private func queryDidChange() {
        debounceTask?.cancel()
        cancelRun()
        guard trimmedQuery.count >= Self.minimumQueryLength else {
            reset()
            return
        }
        prepareNewSearch()
        debounceTask = Task { [weak self, debounce] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.refreshAnnotations(regroup: false)
            self.regroup()
            self.run(from: 0)
        }
    }

    /// Return on the keyboard: search now instead of waiting for the debounce.
    func submit() {
        guard trimmedQuery.count >= Self.minimumQueryLength else { return }
        startSearch()
    }

    /// Clears the previous query's results and shows the new query as searching.
    private func prepareNewSearch() {
        textHits = []
        annotationResults = []
        selectedResultID = nil
        searchedQuery = trimmedQuery
        pagesSearched = 0
        updateCost = UpdateCost()
        if let session { totalPages = session.pageCount }
        clearMarks()
        regroup()
        phase = .searching
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
        debounceTask?.cancel()
        debounceTask = nil
        cancelRun()
        guard trimmedQuery.count >= Self.minimumQueryLength else { return }
        prepareNewSearch()
        refreshAnnotations(regroup: false)
        regroup()
        run(from: 0)
    }

    /// Resumes a capped or cancelled search where it left off.
    func continueSearch() {
        switch phase {
        case .capped(let next), .cancelled(let next):
            guard !searchedQuery.isEmpty else { return }
            if next == 0 {
                startSearch()
            } else {
                cancelRun()
                run(from: next)
            }
        default:
            break
        }
    }

    /// Cancels the running (or about-to-start) search, keeping the results found so far.
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        guard phase == .searching else { return }
        cancelRun()
        phase = .cancelled(nextPage: pagesSearched)
    }

    private func run(from startPage: Int) {
        guard let session else { return }
        runID += 1
        let id = runID
        phase = .searching
        let stream = PDFTextSearch.stream(url: session.documentURL, query: searchedQuery, startPage: startPage,
                                          hitCap: hitCap, pageDelay: pageDelay)
        searchTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.runID == id else { return }
                self.apply(event)
            }
        }
    }

    /// Ends the current run: the stream's consumer task is cancelled, which terminates the
    /// stream and so cancels the engine's worker.
    private func cancelRun() {
        runID += 1
        searchTask?.cancel()
        searchTask = nil
    }

    private func apply(_ event: SearchEvent) {
        switch event {
        case .hits(let hits):
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            textHits.append(contentsOf: hits)
            regroup()
            let spent = Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start))
            updateCost.updates += 1
            updateCost.total += spent
            updateCost.longest = max(updateCost.longest, spent)
        case .progress(let searched, let total):
            pagesSearched = searched
            totalPages = total
        case .finished(let completion):
            switch completion.reason {
            case .completed: phase = .finished
            case .capped: phase = .capped(nextPage: completion.nextPage)
            case .failed: phase = .failed
            }
            searchTask = nil
        }
    }

    // MARK: Notes, highlights and outline

    /// Re-reads matching notes and highlights from the store.
    func refreshAnnotations(regroup shouldRegroup: Bool = true) {
        annotationRefreshTask?.cancel()
        annotationRefreshTask = nil
        guard let session, !searchedQuery.isEmpty else { return }
        annotationResults = AnnotationSearch.results(query: searchedQuery, bookID: session.book.id,
                                                     store: session.store, outline: session.outline)
        if shouldRegroup { regroup() }
    }

    /// Coalesces bursts of store changes (typing in a note saves repeatedly).
    private func scheduleAnnotationRefresh() {
        guard !searchedQuery.isEmpty else { return }
        annotationRefreshTask?.cancel()
        annotationRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refreshAnnotations()
        }
    }

    /// Regroups (and re-resolves heading notes) whenever the session's outline is replaced: when
    /// it first loads, and when user headings change in any window.
    private func observeOutline() {
        withObservationTracking {
            _ = session?.outline
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAnnotations(regroup: false)
                self.regroup()
                self.observeOutline()
            }
        }
    }

    private func regroup() {
        guard let session else { return }
        let all = textHits.map(SearchResult.init(hit:)) + annotationResults
        groups = SearchGrouping.group(all, outline: session.outline, pageCount: session.pageCount)
        textHitCount = textHits.count
        annotationResultCount = annotationResults.count
    }

    // MARK: Choosing a result

    /// Results in display order (the order of the groups).
    var orderedResults: [SearchResult] { groups.flatMap(\.results) }

    func result(withID id: String) -> SearchResult? {
        for group in groups {
            if let found = group.results.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Goes to a result through the session's jump API, so section history records it.
    /// A text hit is marked on the page; a highlight goes to its page and text (it is already
    /// drawn there); a note opens the notes panel on its target (a page note on the Page note
    /// tab, a heading note on the Section note tab at the heading's first page).
    func select(_ result: SearchResult) {
        guard let session else { return }
        selectedResultID = result.id
        switch result.kind {
        case .text:
            session.pdf.clearMarks()
            hasMark = session.jump(toPage: result.pageIndex, revealing: result.rects, mark: true)
        case .highlight:
            clearMarks()
            session.jump(toPage: result.pageIndex, revealing: result.rects, mark: false)
        case .note:
            clearMarks()
            switch result.noteTarget {
            case .heading(let anchor):
                if !session.jump(toHeading: anchor) { session.jump(toPage: result.pageIndex) }
                session.showNotes(.section)
            default:
                session.jump(toPage: result.pageIndex)
                session.showNotes(.page)
            }
        }
    }

    /// The panel's row action: navigate and close the panel. A note's navigation (which opens
    /// the notes panel, a sheet at narrow widths) waits until the search panel has gone.
    func choose(_ result: SearchResult) {
        guard let session else { return }
        closingAfterChoice = true
        if result.kind == .note {
            selectedResultID = result.id
            pendingSelection = result
        } else {
            select(result)
        }
        session.isSearchVisible = false
    }

    var canStep: Bool { !orderedResults.isEmpty }

    /// Next result after the selected one (the first when nothing is selected), wrapping. The
    /// panel stays open.
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

    // MARK: Panel

    /// The panel appeared.
    func panelDidAppear() {
        pendingSelection = nil
        closingAfterChoice = false
    }

    /// The panel has gone. A running search is cancelled (it can be continued on reopening). If
    /// the panel closed because a result was chosen, a waiting note navigation runs now;
    /// otherwise (Done, tapping outside) the search marks are cleared.
    func panelDidDisappear() {
        cancel()
        if closingAfterChoice {
            closingAfterChoice = false
            if let pending = pendingSelection {
                pendingSelection = nil
                select(pending)
            }
        } else {
            clearMarks()
        }
    }

    // MARK: Marks

    private func clearMarks() {
        guard hasMark else { return }
        hasMark = false
        session?.pdf.clearMarks()
    }
}

// Tapping the page clears the search mark (and is never consumed: other handlers still get it).
extension SearchModel: ReaderPageTapHandling {
    func handleTap(_ tap: ReaderPageTap) -> Bool {
        clearMarks()
        return false
    }
}

extension ReaderSession {
    /// This window's search (created on first use, kept for the session's lifetime).
    var searchModel: SearchModel {
        featureState { SearchModel(session: self) }
    }
}
