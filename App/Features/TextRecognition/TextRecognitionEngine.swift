import Foundation
import Observation
import ReaderCore
import UIKit

/// The app's one text-recognition queue for scanned books (S2; design, "Scanned books" ▸
/// "Recognition"). Owned by `AppEnvironment` and shared by every window.
///
/// ## What it does
/// For every book whose `RecognitionState` is *in progress*, one page at a time: render the
/// page from a private `PDFDocument` opened on the file (never the on-screen document), read it
/// with Vision (`VisionPageRecognizer`), convert the word boxes to page space, save the
/// `RecognisedPage` through `LibraryStore` (which posts `.recognisedTextChanged`) and advance the
/// state (`finishingPage()`, then `finishing()`; posts `.recognitionStateChanged`). Pages with
/// text of their own in the file (`PageTextPolicy`) are not recognised but count as done, so a
/// typed cover on a scan is never read and the count still reaches the total.
///
/// - **Order.** Books with a reader window open come first; within a book, the page nearest a
///   reader's current page (`TextRecognitionOrder`), otherwise the first page left.
/// - **Resume.** Each page is saved as it finishes. When a book's job starts (at launch, on
///   accept, on resume), the pages already on disk and the pages with text of their own are
///   counted done and only the rest are read, so the count continues after a relaunch.
/// - **Pauses.** Low Power Mode and serious or critical thermal pressure pause every book
///   (`RecognitionPauseReason.lowPowerMode`, `.thermal`) and resume it when they clear; the
///   reader's own Pause (`pause(bookID:)`) is `.reader`. A page in flight when a pause comes is
///   still saved (S1's transitions allow it).
/// - **Suspension.** Nothing new starts while the app is in the background; it picks up again
///   when the app returns. The state is not changed (it is not a pause).
/// - **Deletion.** Deleting a book cancels its job: a page in flight is dropped, and anything it
///   wrote after the book's files were removed is removed again.
/// - **Not stuttering.** The worker runs at `.utility` QoS on its own thread, never on the main
///   thread or the cooperative pool, and the queue waits `pauseBetweenPages` after each page.
///
/// ## For the status UI (S3)
/// Entry points: `accept(bookID:)` (Make Searchable), `decline(bookID:)` (Not Now),
/// `pause(bookID:)` and `resume(bookID:)` (the reader's Pause and Resume). The state itself is
/// read from the store (`LibraryStore.recognitionState(bookID:)`), re-read on
/// `.recognitionStateChanged(bookID)`; every window sees the same file. The engine builds no UI.
@MainActor
final class TextRecognitionEngine {
    /// The store recognised pages and states are written through.
    let store: LibraryStore
    /// Every write the engine makes is attributed to this origin.
    let origin = ChangeOrigin(label: "text recognition")

    /// Pages recognised (and saved) by this engine, in the order it read them (tests and
    /// diagnostics).
    private(set) var recognisedPages: [(bookID: UUID, pageIndex: Int)] = []
    /// `true` while a page or a survey is being worked on.
    private(set) var isWorking = false
    /// `true` while the app is in the background (`setSuspended(_:)`).
    private(set) var isSuspended = false

    // MARK: Collaborators

    private let worker: TextRecognitionWorker
    private let conditions: any RecognitionConditionsMonitoring
    private let readerPages: @MainActor (UUID) -> [Int]
    private let pauseBetweenPages: Duration

    // MARK: Jobs

    /// A book whose state is in progress or paused.
    private struct Job {
        let bookID: UUID
        let url: URL
        var state: RecognitionState
        /// `false` until the pages done and left have been worked out (`survey`).
        var isSurveyed = false
        /// Pages left to read, ascending.
        var remaining: [Int] = []
        /// Pages that could not be read in this run (retried after a relaunch).
        var failed: Set<Int> = []
        /// The file could not be opened in this run.
        var isUnreadable = false
        /// Queue order between books (lower first).
        var order: Int
    }

    private var jobs: [UUID: Job] = [:]
    /// Bumped when a book's job is cancelled (deletion), so work in flight for it is dropped.
    private var generations: [UUID: Int] = [:]
    private var nextOrder = 0
    private var isStarted = false
    private var loop: Task<Void, Never>?
    private var wakeUp: CheckedContinuation<Void, Never>?
    private var stateWrites: Task<Void, Never>?
    private var hubToken: StoreChangeObservation?
    private let lifecycleObservers = NotificationObservers()

    /// - Parameters:
    ///   - recognizer: reads page images (Vision; tests may pass a fake).
    ///   - conditions: Low Power Mode and thermal state (tests pass a fake).
    ///   - readerPages: the current pages of the reader windows open on a book; by default the
    ///     live reader sessions on `store` (`OpenEditorRegistry`).
    ///   - pauseBetweenPages: the queue's yield after each page.
    ///   - observesApplicationState: stop while the app is in the background (tests turn it off
    ///     and call `setSuspended(_:)`).
    init(store: LibraryStore,
         recognizer: any PageRecognizing = VisionPageRecognizer(),
         conditions: (any RecognitionConditionsMonitoring)? = nil,
         readerPages: (@MainActor (UUID) -> [Int])? = nil,
         pauseBetweenPages: Duration = .milliseconds(100),
         observesApplicationState: Bool = true) {
        self.store = store
        self.worker = TextRecognitionWorker(recognizer: recognizer)
        self.conditions = conditions ?? SystemRecognitionConditions()
        self.readerPages = readerPages ?? { [weak store] bookID in
            guard let store else { return [] }
            return OpenEditorRegistry.shared.sessions(of: store)
                .filter { $0.book.id == bookID && $0.closeReason == nil }
                .map(\.currentPageIndex)
        }
        self.pauseBetweenPages = pauseBetweenPages
        self.conditions.onChange = { [weak self] in
            guard let self else { return }
            Task { await self.applyConditions() }
        }
        hubToken = store.hub.observe { [weak self] event in self?.handle(event) }
        if observesApplicationState {
            lifecycleObservers.add(UIApplication.didEnterBackgroundNotification) { [weak self] in
                Task { @MainActor in self?.setSuspended(true) }
            }
            lifecycleObservers.add(UIApplication.willEnterForegroundNotification) { [weak self] in
                Task { @MainActor in self?.setSuspended(false) }
            }
        }
    }

    // MARK: Starting and stopping

    /// Loads every book's state and starts working on the books in progress (resuming after a
    /// relaunch). Idempotent. `AppEnvironment` calls it after its launch work.
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        let books = ((try? store.books.allBooks()) ?? []).sorted { $0.addedAt < $1.addedAt }
        for book in books {
            guard let state = try? await store.recognitionState(bookID: book.id), state.progress != nil else { continue }
            if jobs[book.id] == nil { addJob(bookID: book.id, url: store.documentURL(for: book), state: state) }
        }
        await applyConditions()
        loop = Task { [weak self] in await self?.runLoop() }
        #if DEBUG
        // `-recognizeBook <title>` (UI tests, measurements): accept that book at launch.
        if let title = UserDefaults.standard.string(forKey: "recognizeBook"),
           let book = books.last(where: { $0.title.compare(title, options: .caseInsensitive) == .orderedSame }) {
            await accept(bookID: book.id)
        }
        #endif
    }

    /// Stops the queue after the page in flight (which is still saved) and waits for it, as the
    /// process ending would. For tests; the app's engine lives as long as the process.
    func shutDown() async {
        let running = loop
        loop = nil
        running?.cancel()
        wake()
        await running?.value
        await worker.releaseDocument()
        isStarted = false
    }

    /// The app went to the background (`true`) or returned (`false`). In the background nothing
    /// new starts; the private document is released.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            let worker = worker
            Task { await worker.releaseDocument() }
        } else {
            wake()
        }
    }

    // MARK: Entry points (S3)

    /// Make Searchable: from not decided or declined (or no state yet), the book goes in
    /// progress and joins the queue. Returns `false` when the book is missing or already
    /// accepted.
    @discardableResult
    func accept(bookID: UUID) async -> Bool {
        guard let book = try? store.books.book(id: bookID) else { return false }
        let current: RecognitionState
        if let job = jobs[bookID] {
            current = job.state
        } else {
            current = ((try? await store.recognitionState(bookID: bookID)) ?? nil) ?? .notDecided
        }
        let done = ((try? await store.recognisedPageIndices(bookID: bookID)) ?? []).count
        guard let next = current.accepting(totalPages: book.pageCount, pagesDone: done) else { return false }
        if jobs[bookID] == nil, next.progress != nil {
            addJob(bookID: bookID, url: store.documentURL(for: book), state: current)
        }
        await write(next, bookID: bookID)
        await applyConditions()
        wake()
        return true
    }

    /// Not Now: from not decided or declined (or no state yet). Returns `false` otherwise.
    @discardableResult
    func decline(bookID: UUID) async -> Bool {
        guard jobs[bookID] == nil else { return false }
        let current = ((try? await store.recognitionState(bookID: bookID)) ?? nil) ?? .notDecided
        guard let next = current.declining() else { return false }
        await write(next, bookID: bookID)
        return true
    }

    /// The reader's Pause. Returns `false` when nothing changed (the book is not in progress or
    /// paused, or the reader has already paused it).
    @discardableResult
    func pause(bookID: UUID) async -> Bool {
        await transition(bookID) { $0.pausing(.reader) }
    }

    /// The reader's Resume (other pause reasons, such as Low Power Mode, still hold). Returns
    /// `false` when nothing changed (the book is not paused by the reader).
    @discardableResult
    func resume(bookID: UUID) async -> Bool {
        let changed = await transition(bookID) { $0.resuming(.reader) }
        wake()
        return changed
    }

    /// The engine's view of a book's state: its job's state while in progress or paused,
    /// otherwise the stored one.
    func state(bookID: UUID) async -> RecognitionState? {
        if let job = jobs[bookID] { return job.state }
        return (try? await store.recognitionState(bookID: bookID)) ?? nil
    }

    // MARK: Conditions

    /// Pauses or resumes every book for Low Power Mode and thermal pressure as they hold now.
    func applyConditions() async {
        let lowPower = conditions.isLowPowerModeEnabled
        let thermal = conditions.isUnderThermalPressure
        for bookID in jobs.keys.sorted(by: { (jobs[$0]?.order ?? 0) < (jobs[$1]?.order ?? 0) }) {
            await apply(.lowPowerMode, holds: lowPower, to: bookID)
            await apply(.thermal, holds: thermal, to: bookID)
        }
        wake()
    }

    private func apply(_ reason: RecognitionPauseReason, holds: Bool, to bookID: UUID) async {
        guard let state = jobs[bookID]?.state else { return }
        let has = state.pauseReasons.contains(reason)
        if holds, !has {
            await transition(bookID) { $0.pausing(reason) }
        } else if !holds, has {
            await transition(bookID) { $0.resuming(reason) }
        }
    }

    // MARK: The queue

    private enum Work {
        case survey(UUID)
        case page(UUID, Int)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let work = nextWork() else {
                await worker.releaseDocument()
                if Task.isCancelled { return }
                if nextWork() == nil {
                    await withCheckedContinuation { wakeUp = $0 }
                }
                continue
            }
            isWorking = true
            switch work {
            case .survey(let bookID):
                await survey(bookID)
            case .page(let bookID, let pageIndex):
                await recognise(bookID, pageIndex: pageIndex)
                isWorking = false
                if pauseBetweenPages > .zero { try? await Task.sleep(for: pauseBetweenPages) }
            }
            isWorking = false
        }
    }

    private func wake() {
        let continuation = wakeUp
        wakeUp = nil
        continuation?.resume()
    }

    /// The next thing to do: a book with an open reader first, then queue order; a book's
    /// survey before its pages.
    private func nextWork() -> Work? {
        guard isStarted, !isSuspended, loop != nil else { return nil }
        let runnable = jobs.values.filter {
            if case .inProgress = $0.state { return !$0.isUnreadable }
            return false
        }
        let ranked = runnable.map { job in (job, readerPages(job.bookID)) }
            .sorted { a, b in
                if a.1.isEmpty != b.1.isEmpty { return !a.1.isEmpty }
                return a.0.order < b.0.order
            }
        for (job, readers) in ranked {
            guard job.isSurveyed else { return .survey(job.bookID) }
            let left = job.failed.isEmpty ? job.remaining : job.remaining.filter { !job.failed.contains($0) }
            if let page = TextRecognitionOrder.nextPage(remaining: left, readerPages: readers) {
                return .page(job.bookID, page)
            }
        }
        return nil
    }

    /// Works out which pages are done (on disk, or with text of their own) and which are left,
    /// and corrects the stored count to match.
    private func survey(_ bookID: UUID) async {
        guard let job = jobs[bookID] else { return }
        let generation = generations[bookID, default: 0]
        let recognised = Set((try? await store.recognisedPageIndices(bookID: bookID)) ?? [])
        let survey = await worker.survey(url: job.url, skipping: recognised)
        guard isCurrent(bookID, generation) else { return }
        guard let survey else {
            jobs[bookID]?.isUnreadable = true
            textRecognitionLog.error("recognition: the PDF of \(bookID, privacy: .public) could not be opened")
            return
        }
        let all = 0..<survey.pageCount
        let done = recognised.union(survey.pagesWithOwnText).filter { all.contains($0) }
        jobs[bookID]?.remaining = all.filter { !done.contains($0) }
        jobs[bookID]?.isSurveyed = true
        let progress = RecognitionProgress(pagesDone: done.count, totalPages: survey.pageCount)
        if progress.isFinished {
            await transition(bookID) { $0.finishing() }
        } else {
            await transition(bookID) { Self.state($0, withProgress: progress) }
        }
    }

    /// Reads one page and records it.
    private func recognise(_ bookID: UUID, pageIndex: Int) async {
        guard let job = jobs[bookID] else { return }
        let generation = generations[bookID, default: 0]
        let outcome = await worker.recognise(url: job.url, pageIndex: pageIndex)
        guard isCurrent(bookID, generation) else { return }
        switch outcome {
        case .recognised(let page):
            do {
                try await store.saveRecognisedPage(page, bookID: bookID, origin: origin)
            } catch {
                jobs[bookID]?.failed.insert(pageIndex)
                textRecognitionLog.error("recognition: page \(pageIndex) not saved: \(String(describing: error), privacy: .public)")
                return
            }
            guard isCurrent(bookID, generation) else {
                await removeLeftoversIfDeleted(bookID)
                return
            }
            recognisedPages.append((bookID, pageIndex))
            // `-perfProbe` measurements: when recognition ran, relative to the scroll.
            if [1, 5, 10, 15, 20, 25, 29].contains(recognisedPages.count) {
                PerfMarks.mark("recognised\(recognisedPages.count)")
            }
            jobs[bookID]?.remaining.removeAll { $0 == pageIndex }
            await transition(bookID) { $0.finishingPage() }
        case .hasOwnText:
            jobs[bookID]?.remaining.removeAll { $0 == pageIndex }
            await transition(bookID) { $0.finishingPage() }
        case .failed(let reason):
            jobs[bookID]?.failed.insert(pageIndex)
            textRecognitionLog.error("recognition: \(reason, privacy: .public)")
        }
        if let left = jobs[bookID], left.isSurveyed, left.remaining.isEmpty {
            await transition(bookID) { $0.finishing() }
        }
        if !isCurrent(bookID, generation) { await removeLeftoversIfDeleted(bookID) }
    }

    // MARK: State

    private func addJob(bookID: UUID, url: URL, state: RecognitionState) {
        jobs[bookID] = Job(bookID: bookID, url: url, state: state, order: nextOrder)
        nextOrder += 1
    }

    private func isCurrent(_ bookID: UUID, _ generation: Int) -> Bool {
        jobs[bookID] != nil && generations[bookID, default: 0] == generation
    }

    /// Applies a transition to a book with a job, saving the new state. Returns whether the
    /// state changed. A book that leaves in progress and paused leaves the queue.
    @discardableResult
    private func transition(_ bookID: UUID, _ change: (RecognitionState) -> RecognitionState?) async -> Bool {
        guard let current = jobs[bookID]?.state, let next = change(current), next != current else { return false }
        jobs[bookID]?.state = next
        if next.progress == nil { jobs[bookID] = nil }
        await write(next, bookID: bookID)
        return true
    }

    /// Writes a state through the store, one write after another (so the file always ends with
    /// the latest), posting `.recognitionStateChanged`.
    private func write(_ state: RecognitionState, bookID: UUID) async {
        if jobs[bookID] != nil { jobs[bookID]?.state = state }
        let previous = stateWrites
        let store = store
        let origin = origin
        let write = Task { @MainActor in
            await previous?.value
            do {
                try await store.saveRecognitionState(state, bookID: bookID, origin: origin)
            } catch {
                textRecognitionLog.error("recognition: state of \(bookID, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
            }
        }
        stateWrites = write
        await write.value
    }

    /// `state` (in progress or paused) with its progress replaced.
    private static func state(_ state: RecognitionState, withProgress progress: RecognitionProgress) -> RecognitionState? {
        switch state {
        case .inProgress: .inProgress(progress)
        case .paused(_, let reasons): .paused(progress, reasons: reasons)
        default: nil
        }
    }

    // MARK: Changes from elsewhere

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .bookDeleted(let bookID):
            // Cancel: work in flight for the book is dropped. A restore that replaced the book
            // under the same ID leaves a book behind; its state is read again.
            generations[bookID, default: 0] += 1
            jobs[bookID] = nil
            Task { await self.reloadIfPresent(bookID) }
        case .recognitionStateChanged(let bookID) where !event.isFrom(origin):
            Task { await self.reloadIfPresent(bookID) }
        case .recognisedTextChanged(let bookID, nil) where !event.isFrom(origin):
            // All of the book's recognised text was removed elsewhere: work it out again.
            if jobs[bookID] != nil { jobs[bookID]?.isSurveyed = false; wake() }
        default:
            break
        }
    }

    /// Re-reads a book's state after a change made elsewhere.
    private func reloadIfPresent(_ bookID: UUID) async {
        guard isStarted, let book = try? store.books.book(id: bookID) else { return }
        let state = (try? await store.recognitionState(bookID: bookID)) ?? nil
        guard let state, state.progress != nil else {
            jobs[bookID] = nil
            return
        }
        if jobs[bookID] == nil {
            addJob(bookID: bookID, url: store.documentURL(for: book), state: state)
        } else {
            jobs[bookID]?.state = state
        }
        await applyConditions()
        wake()
    }

    /// A page saved for a book deleted meanwhile may have re-created its files: remove them
    /// again when the book has no record.
    private func removeLeftoversIfDeleted(_ bookID: UUID) async {
        guard (try? store.books.book(id: bookID)) == nil else { return }
        await stateWrites?.value
        try? await store.removeBookFiles(bookID: bookID)
    }
}
