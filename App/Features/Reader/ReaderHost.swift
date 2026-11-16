import ReaderCore
import SwiftUI
import UIKit

/// Owns one `ReaderSession` for as long as the reader is shown (in place or in its own window),
/// restores and saves its per-window state, and drives its lifecycle: suspend (flush) on
/// background, window close and when the reader is left; memory warnings.
struct ReaderHost: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage private var storedState: Data?
    @State private var session: ReaderSession?
    @State private var isMissing = false

    init(bookID: UUID) {
        self.bookID = bookID
        _storedState = SceneStorage("reader.state.\(bookID.uuidString)")
    }

    var body: some View {
        Group {
            if let session {
                ReaderScreen(session: session)
                    .onChange(of: session.restorableState) { _, state in
                        storedState = try? JSONEncoder().encode(state)
                        session.saveNotesPanelState()
                    }
            } else if isMissing {
                ContentUnavailableView("Book Not Found", systemImage: "book.closed",
                                       description: Text("This book is no longer in the library."))
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: makeSessionIfNeeded)
        .onDisappear {
            guard let session else { return }
            Task { await session.suspend() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let session else { return }
            if phase == .active {
                session.markup.reassertToolPicker()
            } else {
                Task { await session.suspend() }
            }
        }
        .task(id: session?.id) {
            // SwiftUI may move the first responder while the reader is pushed; in markup mode
            // (e.g. `-markup` at launch) take it back for the tool picker once things settle.
            for delay in [300, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                session?.markup.reassertToolPicker()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            session?.handleMemoryWarning()
        }
        .onChange(of: window.readerJumpRequests) { _, _ in
            guard let overrides = window.takeReaderOverrides(for: bookID) else { return }
            if let page = overrides.pageIndex { session?.jump(toPage: page) }
            if let heading = overrides.notesHeading { session?.showNotes(.section, heading: heading) }
        }
    }

    private func makeSessionIfNeeded() {
        guard session == nil, !isMissing else { return }
        guard let book = try? environment.store.books.book(id: bookID) else {
            isMissing = true
            // Never leave a dead reader on screen: drop this route (an empty reader window
            // closes, a Library window shows the Library).
            DispatchQueue.main.async { window.bookWasDeleted(bookID) }
            return
        }
        var configuration = ReaderSession.Configuration()
        #if DEBUG
        // Test switches from the launch arguments; a release build has none (`LaunchOptions`).
        configuration.inkAnyInput = environment.launchOptions.inkAnyInput
        configuration.selectionMenuProbe = environment.launchOptions.selectionMenuProbe
        configuration.markupProbeSurface = environment.launchOptions.markupProbeSurface
        configuration.exposesViewportAnchor = environment.launchOptions.exposeViewportAnchor
        configuration.exposesSelection = environment.launchOptions.exposeSelection
        configuration.exposesMarkupState = environment.launchOptions.exposeMarkupState
        configuration.hardwareKeyboard = environment.launchOptions.hardwareKeyboard
        configuration.scrollDirection = environment.launchOptions.scrollDirection
        #endif
        if let storedState {
            configuration.restoredState = try? JSONDecoder().decode(ReaderSession.RestorableState.self, from: storedState)
        }
        let overrides = window.takeReaderOverrides(for: bookID)
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
}
