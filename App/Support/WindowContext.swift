import Foundation
import Observation
import ReaderCore
import SwiftUI
import UIKit

/// Scene identifiers and values. Every window is a `WindowRootView`: a navigation stack whose
/// root is the Library and whose path holds what the window shows in place.
nonisolated enum WindowID {
    /// The Library window group (the app's first scene; the system "New Window" makes one).
    static let library = "library"
    /// The reader window group, presented with a `ReaderWindowValue`.
    static let reader = "reader"
    /// The Notebook window group, presented with a book ID (`UUID`).
    static let notebook = "notebook"
}

/// The value of a reader window. `instanceID` makes every "Open in New Window" a new window,
/// so the same book can be open in two windows (a value-based group would otherwise focus the
/// existing window with an equal value).
nonisolated struct ReaderWindowValue: Codable, Hashable, Sendable {
    var bookID: UUID
    var instanceID = UUID()
    /// Zero-based page to open at, applied once when the window is first created (a restored
    /// window keeps its own page). `nil`: the book's last-read page.
    var pageIndex: Int?
}

/// A screen shown in place in a window (pushed on its navigation stack).
nonisolated enum WindowRoute: Codable, Hashable, Sendable {
    case reader(bookID: UUID)
    case notebook(bookID: UUID)

    var bookID: UUID {
        switch self {
        case .reader(let id), .notebook(let id): id
        }
    }
}

/// Per-window navigation and window actions. One per window, in the environment
/// (`@Environment(WindowContext.self)`) and published as a focused scene value for commands.
@Observable
@MainActor
final class WindowContext {
    /// Which window group the window belongs to (decides what happens when its path empties
    /// because its book was deleted: only Library windows stay open).
    enum Kind: String, Sendable {
        case library, reader, notebook
    }

    let kind: Kind
    /// The navigation path; empty shows the Library. Saved per window for restoration.
    var path: [WindowRoute]
    /// Increases when "Import PDF…" is chosen for this window. WP3's Library screen watches it
    /// (`.onChange(of: window.importRequestCount)`) and presents its importer.
    private(set) var importRequestCount = 0

    @ObservationIgnored weak var scene: UIWindowScene?
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var pendingOverrides: [UUID: ReaderOverrides] = [:]
    @ObservationIgnored private var hubToken: StoreChangeObservation?

    init(kind: Kind, path: [WindowRoute] = [], store: LibraryStore? = nil) {
        self.kind = kind
        self.path = path
        if let store {
            hubToken = store.hub.observe { [weak self] event in
                if case .bookDeleted(let id) = event.change { self?.bookWasDeleted(id) }
            }
        }
    }

    // MARK: In place

    /// Opens the reader on `bookID` in this window (pushing it), optionally at a page.
    func openReader(bookID: UUID, pageIndex: Int? = nil) {
        if let pageIndex { pendingOverrides[bookID] = ReaderOverrides(pageIndex: pageIndex) }
        if case .reader(let current)? = path.last, current == bookID {
            // Already showing it: the host picks up the override.
            if pageIndex != nil { readerJumpRequests += 1 }
            return
        }
        path.append(.reader(bookID: bookID))
    }

    /// Opens the Notebook of `bookID` in this window.
    func openNotebook(bookID: UUID) {
        path.append(.notebook(bookID: bookID))
    }

    /// Back to the Library (the root).
    func backToLibrary() {
        path.removeAll()
    }

    /// "Import PDF…": shows the Library and asks it to present its importer.
    func requestImport() {
        path.removeAll()
        importRequestCount += 1
    }

    /// Increases when `openReader(bookID:pageIndex:)` targets the reader already shown.
    private(set) var readerJumpRequests = 0

    /// One-shot overrides for the next reader on `bookID` (launch arguments, links to a page).
    func setReaderOverrides(_ overrides: ReaderOverrides, for bookID: UUID) {
        pendingOverrides[bookID] = overrides
    }

    /// Takes (and clears) the overrides for a reader on `bookID`.
    func takeReaderOverrides(for bookID: UUID) -> ReaderOverrides? {
        pendingOverrides.removeValue(forKey: bookID)
    }

    // MARK: Other windows

    /// Opens a new reader window on the book (always a new window, even for the same book), at
    /// `pageIndex` when given (applied once; not a section-history jump), else at the book's
    /// last-read page.
    func openReaderInNewWindow(bookID: UUID, pageIndex: Int? = nil) {
        openWindowAction?(id: WindowID.reader, value: ReaderWindowValue(bookID: bookID, pageIndex: pageIndex))
    }

    /// Opens (or focuses) the Notebook window of the book.
    func openNotebookInNewWindow(bookID: UUID) {
        openWindowAction?(id: WindowID.notebook, value: bookID)
    }

    /// Opens a new Library window.
    func openNewLibraryWindow() {
        openWindowAction?(id: WindowID.library)
    }

    /// Closes this window (its scene session is destroyed).
    func closeWindow() {
        guard let session = scene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
    }

    // MARK: Deletion

    /// Removes the deleted book's screens from the path. A reader or Notebook window left with
    /// nothing of its own closes; a Library window shows the Library.
    func bookWasDeleted(_ bookID: UUID) {
        let before = path.count
        path = Self.path(path, removingBook: bookID)
        if path.isEmpty, before > 0, kind != .library {
            closeWindow()
        }
    }

    /// `path` without the routes of `bookID` (pure; unit-tested).
    nonisolated static func path(_ path: [WindowRoute], removingBook bookID: UUID) -> [WindowRoute] {
        path.filter { $0.bookID != bookID }
    }
}

/// Gives a SwiftUI view its `UIWindowScene` and declares the window's minimum size there
/// (`UISceneSizeRestrictions`, honoured by Stage Manager on iPadOS 16+ and by the resizable
/// windows of iPadOS 26+; Split View and Slide Over sizes are system-defined and always at
/// least as wide as the minimum width).
struct WindowSceneReader: UIViewRepresentable {
    /// The smallest window the layouts must support.
    static let minimumWindowSize = CGSize(width: 320, height: 480)

    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneReaderView {
        let view = SceneReaderView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SceneReaderView, context: Context) {
        uiView.onScene = onScene
        if let scene = uiView.window?.windowScene { onScene(scene) }
    }

    final class SceneReaderView: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            scene.sizeRestrictions?.minimumSize = WindowSceneReader.minimumWindowSize
            onScene?(scene)
        }
    }
}
