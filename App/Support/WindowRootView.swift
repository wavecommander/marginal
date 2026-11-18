import ReaderCore
import ReaderStore
import SwiftUI
import UIKit

/// The root of every window (Library, reader and Notebook groups alike): a navigation stack
/// whose root is the Library and whose path shows a reader or a Notebook in place, so the
/// system back button ("‹ Library") always returns to the Library in that window.
///
/// Restoration: the path is kept in `@SceneStorage("window.path")` per window; the window's
/// reader state for each book (panels, section history) is in scene storage too (`ReaderHost`),
/// and a restored reader opens at its book's latest position (`ReaderPositionStore`). Routes to books
/// that no longer exist are dropped on restore. Readers deep in the path sleep (`ReaderSlot`).
struct WindowRootView: View {
    let kind: WindowContext.Kind
    /// What the window shows first when it has no restored state (a reader or Notebook window's
    /// value).
    let initialRoute: WindowRoute?
    /// The page a new reader window opens at (`ReaderWindowValue.pageIndex`); used only when the
    /// window has no restored state.
    var initialPageIndex: Int? = nil
    /// The heading whose note a new reader window shows (`ReaderWindowValue.notesHeading`);
    /// used only when the window has no restored state.
    var initialNotesHeading: HeadingAnchor? = nil

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("window.path") private var storedPath: Data?
    @State private var context: WindowContext?
    @State private var scene: UIWindowScene?
    /// The scene storage as it was when the window appeared (before this run wrote to it).
    @State private var storedPathAtLaunch: Data?

    var body: some View {
        ZStack {
            if let recovery = environment.libraryRecovery {
                LibraryUnavailableView(recovery: recovery)
            } else if let context {
                WindowContent(context: context, storedPath: $storedPath)
            }
        }
        .background(WindowSceneReader { scene in
            if self.scene !== scene { self.scene = scene }
            context?.scene = scene
        })
        .accentRoot(scene: scene)
        .onAppear(perform: makeContextIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            context?.sleepOffScreenReaders()
        }
        .task { await applyLaunchPlanIfFirstWindow() }
        .onChange(of: environment.markedUpExports.revealRequest) { _, _ in showRequestedExports() }
        .onChange(of: scenePhase) { _, phase in
            showRequestedExports()
            // This window coming forward: sync runs a round (the app's own activation does too).
            if phase == .active { environment.sync?.scheduler.windowBecameActive() }
        }
    }

    /// A marked-up export's notification was opened: the window in front shows that book's
    /// Notebook, where the export is listed under "Exported PDFs".
    private func showRequestedExports() {
        guard scenePhase == .active, let context, environment.libraryRecovery == nil,
              let request = environment.markedUpExports.revealRequest else { return }
        environment.markedUpExports.revealRequest = nil
        if context.path.last == .notebook(bookID: request.bookID) { return }
        context.openNotebook(bookID: request.bookID)
    }

    private func makeContextIfNeeded() {
        PerfMarks.mark("firstWindow")
        guard context == nil else { return }
        storedPathAtLaunch = storedPath
        var path: [WindowRoute] = []
        if let storedPath, let restored = try? JSONDecoder().decode([WindowRoute].self, from: storedPath) {
            path = restored
        } else if let initialRoute {
            path = [initialRoute]
        }
        let opensAt: (bookID: UUID, overrides: ReaderOverrides)? =
            if storedPath == nil, initialPageIndex != nil || initialNotesHeading != nil, case .reader(let bookID)? = initialRoute {
                (bookID, ReaderOverrides(pageIndex: initialPageIndex, notesHeading: initialNotesHeading))
            } else { nil }
        // A restored window never shows a reader or Notebook of a book that is gone: those
        // screens are dropped (a reader/Notebook window left empty shows the Library).
        path = path.filter { (try? environment.store.books.book(id: $0.bookID)) != nil }
        let context = WindowContext(kind: kind, path: path, store: environment.store)
        #if DEBUG
        if let delay = environment.launchOptions.readerSleepDelay {
            context.readerSleepDelay = .milliseconds(Int(delay * 1000))
        }
        #endif
        if let opensAt {
            context.setReaderOverrides(opensAt.overrides, for: opensAt.bookID)
        }
        context.openWindowAction = openWindow
        context.scene = scene
        self.context = context
    }

    private func applyLaunchPlanIfFirstWindow() async {
        guard environment.claimLaunchPlan() else {
            // `-resetState`: a window restored from an earlier run (it has stored state) closes
            // itself; windows opened during this launch (e.g. `-alsoOpenWindow`) have none.
            if environment.launchOptions.resetState, storedPathAtLaunch != nil {
                context?.closeWindow()
            }
            return
        }
        let plan = await environment.launchPlan()
        guard let context else { return }
        // `-importFixture` files that need converting: this window shows their sheet.
        environment.importService.address(plan.conversionRequestIDs, to: ObjectIdentifier(context))
        if environment.launchOptions.resetState, let own = (context.scene ?? scene)?.session {
            // A fresh launch shows one window: drop scene sessions restored from earlier runs.
            // Best effort: SpringBoard may report a killed process's sessions as unknown.
            for session in UIApplication.shared.openSessions where session !== own {
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
            }
        }
        if !plan.path.isEmpty {
            if let overrides = plan.readerOverrides, case .reader(let bookID)? = plan.path.last {
                context.setReaderOverrides(overrides, for: bookID)
            }
            context.path = plan.path
        }
        if let bookID = plan.alsoOpenBookID {
            // Let the first window settle before the system brings in the second.
            try? await Task.sleep(for: .milliseconds(800))
            context.openReaderInNewWindow(bookID: bookID, pageIndex: plan.alsoOpenPageIndex)
        }
    }
}

/// Shown in place of every screen when the library's store could not be opened
/// (`AppEnvironment.libraryRecovery`). The app is then running on an empty stand-in store that
/// is gone when it quits, so nothing may be imported, written or backed up: this screen offers
/// no way into the rest of the app. It offers the ways back in (docs/DESIGN.md "A library from a
/// newer version"): a library from a newer version can be opened in this version, and a kept copy
/// this version can open can be put back. Either takes effect at the next launch.
struct LibraryUnavailableView: View {
    let recovery: LibraryRecovery
    @State private var confirmingOpenInThisVersion = false
    @State private var copyToPutBack: LibraryDatabase.Copy?

    var body: some View {
        if recovery.phase == .ready {
            ContentUnavailableView {
                Label("Library Ready", systemImage: "checkmark.circle")
                    .accessibilityIdentifier(AccessibilityID.Library.recoveryReady)
            } description: {
                Text("Close Tactile Texts and open it again to see your books and notes.")
            }
        } else {
            problem
        }
    }

    private var problem: some View {
        ContentUnavailableView {
            Group {
                if recovery.isFromNewerVersion {
                    Label("Library From a Newer Version", systemImage: "exclamationmark.triangle")
                } else {
                    Label("Library Couldn't Be Opened", systemImage: "exclamationmark.triangle")
                }
            }
            // On the title: on the whole view it would replace the buttons' identifiers.
            .accessibilityIdentifier(AccessibilityID.Library.unavailable)
        } description: {
            if recovery.isFromNewerVersion {
                Text("Your books and notes were last opened by a newer version of Tactile Texts, which saved them in a way this version can't read. Install the newer version to open them as they are, or open them in this version.")
            } else {
                Text("Your books and notes have not been deleted, but Tactile Texts couldn't open them. Close the app and open it again. If this keeps happening, restart your iPad.")
            }
            if case .failed(let message) = recovery.phase {
                Text(message)
                    .foregroundStyle(.red)
            }
            if !recovery.isFromNewerVersion {
                Text(recovery.details)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        } actions: {
            if recovery.phase == .working {
                ProgressView()
            } else {
                if recovery.isFromNewerVersion {
                    Button("Open in This Version…") { confirmingOpenInThisVersion = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(AccessibilityID.Library.openInThisVersion)
                }
                if !recovery.copies.isEmpty {
                    Menu("Use an Earlier Copy") {
                        ForEach(recovery.copies) { copy in
                            Button(LibraryRecovery.label(for: copy)) { copyToPutBack = copy }
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Library.useEarlierCopy)
                }
            }
        }
        .alert("Open in This Version?", isPresented: $confirmingOpenInThisVersion) {
            Button("Open in This Version") { Task { await recovery.openInThisVersion() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your books, notes, ink, highlights, bookmarks and headings are kept. Anything only the newer version understands is left out. A copy of your library as it is now stays on this iPad.")
        }
        .alert("Use This Copy?", isPresented: Binding(get: { copyToPutBack != nil },
                                                       set: { if !$0 { copyToPutBack = nil } }),
               presenting: copyToPutBack) { copy in
            Button("Use This Copy") { Task { await recovery.putBack(copy) } }
            Button("Cancel", role: .cancel) {}
        } message: { copy in
            Text("Your library will be the copy from \(copy.date.formatted(date: .abbreviated, time: .shortened)). Changes made since then won't be in it. Your library as it is now is kept as another copy.")
        }
    }
}

/// A reader shown in place. Its identity follows the window's reader generation for the book,
/// so linking the book's PDF (`WindowContext.reloadReader`) rebuilds the reader and opens it.
private struct ReaderRouteView: View {
    let bookID: UUID
    let context: WindowContext

    var body: some View {
        ReaderHost(bookID: bookID)
            .id(context.readerGeneration(for: bookID))
    }
}

private struct WindowContent: View {
    @Bindable var context: WindowContext
    @Binding var storedPath: Data?
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack(path: $context.path) {
            LibraryScreen()
                .navigationDestination(for: WindowRoute.self) { route in
                    switch route {
                    case .reader(let bookID):
                        ReaderRouteView(bookID: bookID, context: context)
                    case .notebook(let bookID):
                        NotebookScreen(bookID: bookID)
                    }
                }
        }
        .environment(context)
        .focusedSceneValue(context)
        .sheet(isPresented: $context.isSettingsPresented, onDismiss: context.settingsDidDismiss) {
            SettingsView(initialPage: context.settingsPage, openQuickGuide: {
                Task { await environment.onboarding.openQuickGuide(environment: environment, window: context) }
            })
                .environment(context)
        }
        .sheet(item: $context.restoreRequest) { request in
            RestoreFlowView(request: request)
                .environment(context)
        }
        .onOpenURL { url in environment.handleIncomingPDF(url, in: context) }
        .onChange(of: context.path, initial: true) { _, path in
            storedPath = try? JSONEncoder().encode(path)
        }
    }
}
