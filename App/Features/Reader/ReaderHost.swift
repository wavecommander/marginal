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
            if let page = window.takeReaderOverrides(for: bookID)?.pageIndex { session?.jump(toPage: page) }
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
        configuration.inkAnyInput = environment.launchOptions.inkAnyInput
        configuration.selectionMenuProbe = environment.launchOptions.selectionMenuProbe
        configuration.markupProbeSurface = environment.launchOptions.markupProbeSurface
        if let storedState {
            configuration.restoredState = try? JSONDecoder().decode(ReaderSession.RestorableState.self, from: storedState)
        }
        if let overrides = window.takeReaderOverrides(for: bookID) {
            configuration.initialPageIndex = overrides.pageIndex
            configuration.startInMarkup = overrides.startInMarkup
            configuration.openNotesTab = overrides.notesTab
        }
        let session = ReaderSession(book: book, store: environment.store, configuration: configuration)
        self.session = session
        session.open()
    }
}
