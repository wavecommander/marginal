import ReaderCore
import SwiftUI
import UIKit

/// One reader screen (in place or in its own window): holds its `ReaderSlot`, which owns the
/// `ReaderSession` while the reader is awake (see `ReaderSlot` for sleeping), saves the window's
/// state for the book, and drives the session's lifecycle: suspend (flush) on background, window
/// close and when the reader is left; memory warnings.
struct ReaderHost: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage private var storedState: Data?
    @State private var slot: ReaderSlot?

    init(bookID: UUID) {
        self.bookID = bookID
        _storedState = SceneStorage("reader.state.\(bookID.uuidString)")
    }

    private var session: ReaderSession? { slot?.session }

    private var isOnTop: Bool {
        guard let index = slot?.pathIndex else { return false }
        return index == window.path.count - 1
    }

    var body: some View {
        Group {
            if let session {
                ReaderScreen(session: session, isOnTop: isOnTop)
                    .onChange(of: session.restorableState) { _, state in
                        storedState = try? JSONEncoder().encode(state)
                        window.setReaderState(state, for: bookID)
                        session.saveNotesPanelState()
                    }
            } else if slot?.isMissing == true {
                ContentUnavailableView("Book Not Found", systemImage: "book.closed",
                                       description: Text("This book is no longer in the library."))
            } else {
                // Loading, or asleep (then only the back button's menu shows the title).
                ProgressView()
                    .navigationTitle(slot?.title ?? "")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        // The menu bar commands act on the top reader of the focused window. The slot, not the
        // session, is published: SwiftUI can keep a published value after its screen has gone,
        // and an asleep or popped slot holds no session.
        .focusedSceneValue(isOnTop ? slot : nil)
        .onAppear(perform: appeared)
        .onDisappear {
            slot?.isShown = false
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
            // On screen only: the window puts its off-screen readers to sleep (`WindowRootView`).
            guard slot?.isShown == true else { return }
            session?.handleMemoryWarning()
        }
        .onChange(of: window.readerJumpRequests) { _, _ in
            // Only the reader on top is "already showing" the book (a sleeping or buried reader
            // on it must not take the request).
            guard let session, isOnTop, let overrides = window.takeReaderOverrides(for: bookID) else { return }
            if let page = overrides.pageIndex { session.jump(toPage: page) }
            if let heading = overrides.notesHeading { session.showNotes(.section, heading: heading) }
            else if let tab = overrides.notesTab { session.showNotes(tab) }
            else if overrides.hideNotesPanel { session.isNotesVisible = false }
        }
    }

    private func appeared() {
        let shown: ReaderSlot
        if let slot {
            shown = slot
            shown.wake()
        } else {
            if window.readerState(for: bookID) == nil, let storedState,
               let state = try? JSONDecoder().decode(ReaderSession.RestorableState.self, from: storedState) {
                window.setReaderState(state, for: bookID)
            }
            shown = ReaderSlot(bookID: bookID, environment: environment, window: window)
            slot = shown
            shown.wake(takingOverrides: true)
        }
        shown.isShown = true
        window.readerSlotDidAppear(shown)
    }
}
