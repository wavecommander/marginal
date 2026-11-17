import SwiftUI

/// Scenes (see docs/DESIGN.md "Windows and scenes"):
/// - `WindowID.library`: Library windows (first scene; the system "New Window" makes another).
/// - `WindowID.reader` (`ReaderWindowValue`): a reader in its own window, one per value.
/// - `WindowID.notebook` (`UUID` book ID): a book's Notebook window.
/// Every window hosts a `WindowRootView` (Library at the root, a reader or Notebook pushed in
/// place). One `AppEnvironment` is shared by all windows; each reader has its own session.
@main
struct TactileTextsApp: App {
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment.makeLive()
        _environment = State(initialValue: environment)
        PerfMarks.mark("appInit")
        // BGTaskScheduler requires every launch handler to be registered before the app
        // finishes launching; the App is initialised before that.
        environment.backupScheduler.registerBackgroundTask()
        // Marked-up PDF exports that finish in the background say so, in the app too.
        MarkedUpExportNotifications.install()
    }

    var body: some Scene {
        WindowGroup(id: WindowID.library) {
            WindowRootView(kind: .library, initialRoute: nil)
                .environment(environment)
                .environment(\.launchOptions, environment.launchOptions)
        }
        .commands { ReaderCommands() }
        // The app's phase (active while any window is): automatic backups run on activation and
        // schedule their background task when every window is in the background.
        .onChange(of: scenePhase) { _, phase in environment.backupScheduler.scenePhaseChanged(phase) }

        WindowGroup(id: WindowID.reader, for: ReaderWindowValue.self) { $value in
            WindowRootView(kind: .reader, initialRoute: value.map { .reader(bookID: $0.bookID) },
                           initialPageIndex: value?.pageIndex, initialNotesHeading: value?.notesHeading)
                .environment(environment)
                .environment(\.launchOptions, environment.launchOptions)
        }

        WindowGroup(id: WindowID.notebook, for: UUID.self) { $bookID in
            WindowRootView(kind: .notebook, initialRoute: bookID.map { .notebook(bookID: $0) })
                .environment(environment)
                .environment(\.launchOptions, environment.launchOptions)
        }
    }
}
