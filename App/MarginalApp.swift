import SwiftUI

/// Scenes (see docs/DESIGN.md "Windows and scenes"):
/// - `WindowID.library`: Library windows (first scene; the system "New Window" makes another).
/// - `WindowID.reader` (`ReaderWindowValue`): a reader in its own window, one per value.
/// - `WindowID.notebook` (`UUID` book ID): a book's Notebook window.
/// Every window hosts a `WindowRootView` (Library at the root, a reader or Notebook pushed in
/// place). One `AppEnvironment` is shared by all windows; each reader has its own session.
@main
struct MarginalApp: App {
    @State private var environment = AppEnvironment.makeLive()

    var body: some Scene {
        WindowGroup(id: WindowID.library) {
            WindowRootView(kind: .library, initialRoute: nil)
                .environment(environment)
                .environment(\.launchOptions, environment.launchOptions)
        }
        .commands { ReaderCommands() }

        WindowGroup(id: WindowID.reader, for: ReaderWindowValue.self) { $value in
            WindowRootView(kind: .reader, initialRoute: value.map { .reader(bookID: $0.bookID) })
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
