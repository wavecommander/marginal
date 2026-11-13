import ReaderCore
import SwiftUI
import UIKit

/// The root of every window (Library, reader and Notebook groups alike): a navigation stack
/// whose root is the Library and whose path shows a reader or a Notebook in place, so the
/// system back button ("‹ Library") always returns to the Library in that window.
///
/// Restoration: the path is kept in `@SceneStorage("window.path")` per window; each reader keeps
/// its own state (page, panels) in scene storage too (`ReaderHost`). Routes to books that no
/// longer exist are dropped on restore.
struct WindowRootView: View {
    let kind: WindowContext.Kind
    /// What the window shows first when it has no restored state (a reader or Notebook window's
    /// value).
    let initialRoute: WindowRoute?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("window.path") private var storedPath: Data?
    @State private var context: WindowContext?
    @State private var scene: UIWindowScene?

    var body: some View {
        ZStack {
            if let context {
                WindowContent(context: context, storedPath: $storedPath)
            }
        }
        .background(WindowSceneReader { scene in
            if self.scene !== scene { self.scene = scene }
            context?.scene = scene
        })
        .onAppear(perform: makeContextIfNeeded)
        .task { await applyLaunchPlanIfFirstWindow() }
    }

    private func makeContextIfNeeded() {
        guard context == nil else { return }
        var path: [WindowRoute] = []
        if let storedPath, let restored = try? JSONDecoder().decode([WindowRoute].self, from: storedPath) {
            path = restored.filter { (try? environment.store.books.book(id: $0.bookID)) != nil }
        } else if let initialRoute {
            path = [initialRoute]
        }
        let context = WindowContext(kind: kind, path: path, store: environment.store)
        context.openWindowAction = openWindow
        context.scene = scene
        self.context = context
    }

    private func applyLaunchPlanIfFirstWindow() async {
        guard environment.claimLaunchPlan() else { return }
        let plan = await environment.launchPlan()
        guard let context else { return }
        if environment.launchOptions.resetState, let own = (context.scene ?? scene)?.session {
            // A fresh launch shows one window: drop scene sessions restored from earlier runs.
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
            context.openReaderInNewWindow(bookID: bookID)
        }
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
                        ReaderHost(bookID: bookID)
                    case .notebook(let bookID):
                        NotebookScreen(bookID: bookID)
                    }
                }
        }
        .environment(context)
        .focusedSceneValue(context)
        .onOpenURL { url in environment.handleIncomingPDF(url, in: context) }
        .onChange(of: context.path, initial: true) { _, path in
            storedPath = try? JSONEncoder().encode(path)
        }
    }
}
