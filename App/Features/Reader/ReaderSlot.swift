import Foundation
import Observation
import ReaderCore

/// One reader screen in a window's navigation stack (design: "Sleeping readers"). Owns the
/// screen's `ReaderSession` while it is awake. Asleep, it holds no session, so no document, PDF
/// view, ink canvases, outline or Notebook, only what the reader left: its exact place and zoom,
/// panels and section history. Waking makes a new session that resumes exactly there, whatever
/// other readers on the book have done since. The first session opens like any new reader: at
/// the book's latest position (`ReaderPositionStore`) with the window's state for the book
/// (`WindowContext.readerState(for:)`).
///
/// `WindowContext` decides when: the top screen and the one directly under it are awake; a reader
/// further down falls asleep after `WindowContext.readerSleepDelay`, and wakes as soon as it is
/// the top screen or the one under it again. A popped reader falls asleep once its screen has
/// animated away. Falling asleep saves, then closes the session (`ReaderSession.close()`):
/// SwiftUI can keep a finished screen's state, and with it the session object, for a while.
/// `ReaderHost` shows the session.
@Observable
@MainActor
final class ReaderSlot {
    let bookID: UUID
    /// The session while awake.
    private(set) var session: ReaderSession?
    /// The book was not found when the slot tried to wake.
    private(set) var isMissing = false
    /// The book's title, for the navigation bar while the slot is asleep or loading (the back
    /// button's menu lists it).
    private(set) var title = ""

    /// This screen's index in the window's path, learned when it is shown (`nil`: not known, e.g.
    /// after the path was rearranged by a deletion; such a slot stays as it is until shown again).
    var pathIndex: Int?

    /// The screen is on screen now (between its appearing and disappearing, so also while the
    /// back swipe reveals it). `ReaderHost` keeps it.
    @ObservationIgnored var isShown = false

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private weak var window: WindowContext?
    /// What the reader left when it last fell asleep (`nil` before then).
    @ObservationIgnored private(set) var leftState: ReaderSession.RestorableState?
    @ObservationIgnored private(set) var leftPosition: ReaderPosition?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Increases whenever a pending sleep is called off, so one already saving does not finish.
    @ObservationIgnored private var sleepGeneration = 0

    init(bookID: UUID, environment: AppEnvironment, window: WindowContext) {
        self.bookID = bookID
        self.environment = environment
        self.window = window
    }

    /// Makes the session if there is none: the first time the screen is shown (taking the
    /// window's one-shot overrides for the book, `takingOverrides`), or on waking.
    func wake(takingOverrides: Bool = false) {
        cancelSleep()
        guard session == nil, !isMissing, let window else { return }
        guard let book = try? environment.store.books.book(id: bookID) else {
            isMissing = true
            // Never leave a dead reader on screen: drop this route (an empty reader window
            // closes, a Library window shows the Library).
            DispatchQueue.main.async { [weak window, bookID] in window?.bookWasDeleted(bookID) }
            return
        }
        title = book.title
        let options = environment.launchOptions
        var configuration = ReaderSession.Configuration()
        #if DEBUG
        // Test switches from the launch arguments; a release build has none (`LaunchOptions`).
        configuration.inkAnyInput = options.inkAnyInput
        configuration.selectionMenuProbe = options.selectionMenuProbe
        configuration.markupProbeSurface = options.markupProbeSurface
        configuration.exposesViewportAnchor = options.exposeViewportAnchor
        configuration.exposesSelection = options.exposeSelection
        configuration.exposesMarkupState = options.exposeMarkupState
        configuration.hardwareKeyboard = options.hardwareKeyboard
        configuration.scrollDirection = options.scrollDirection
        #endif
        configuration.restoredState = leftState ?? window.readerState(for: bookID)
        configuration.resumePosition = leftPosition
        let overrides = takingOverrides ? window.takeReaderOverrides(for: bookID) : nil
        if let overrides {
            configuration.initialPageIndex = overrides.pageIndex
            configuration.startInMarkup = overrides.startInMarkup
            configuration.openNotesTab = overrides.notesTab
        }
        PerfMarks.mark("readerHost")
        let session = ReaderSession(book: book, store: environment.store, configuration: configuration)
        // A Notebook heading-note row: the notes panel waits for the outline, then shows it.
        if let heading = overrides?.notesHeading { session.showNotes(.section, heading: heading) }
        self.session = session
        session.open()
    }

    /// Falls asleep after `delay` unless woken first. Does nothing while asleep or already counting.
    func scheduleSleep(after delay: Duration) {
        guard session != nil, sleepTask == nil else { return }
        let generation = sleepGeneration
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fallAsleep(generation: generation)
        }
    }

    /// Falls asleep now, without the countdown (a memory warning while off screen). Does nothing
    /// while asleep; being woken or shown while it saves keeps it awake.
    func sleepNow() {
        guard session != nil else { return }
        cancelSleep()
        let generation = sleepGeneration
        sleepTask = Task { [weak self] in
            await self?.fallAsleep(generation: generation)
        }
    }

    func cancelSleep() {
        sleepGeneration += 1
        sleepTask?.cancel()
        sleepTask = nil
    }

    /// Saves everything the session has pending (the position, page ink, every live note), then
    /// lets it go.
    private func fallAsleep(generation: Int) async {
        guard let session, generation == sleepGeneration else { return }
        await session.suspend()
        await session.notesPanelIfCreated?.flushAll()
        // Woken (or shown) while saving: stay awake.
        guard generation == sleepGeneration, self.session === session else { return }
        sleepTask = nil
        leftState = session.restorableState
        // A session woken under the top screen and never shown keeps the place it was woken for.
        if let position = session.currentPosition { leftPosition = position }
        self.session = nil
        session.close()
    }
}
