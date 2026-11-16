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
    /// A heading whose note the new window shows in the notes panel (Section tab), applied once
    /// like `pageIndex`.
    var notesHeading: HeadingAnchor?
}

/// A page of the Settings sheet that can be opened directly.
nonisolated enum SettingsPage: Hashable, Sendable {
    case backup
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
    var path: [WindowRoute] {
        didSet {
            updateReaderSlots(popped: oldValue.count > path.count && Array(oldValue.prefix(path.count)) == path)
        }
    }
    /// How long a reader two or more screens below the top stays awake (design: "Sleeping
    /// readers"). `-readerSleepDelay` shortens it for UI tests.
    @ObservationIgnored var readerSleepDelay: Duration = WindowContext.defaultReaderSleepDelay
    nonisolated static let defaultReaderSleepDelay: Duration = .seconds(5)
    /// Increases when "Import PDF…" is chosen for this window. WP3's Library screen watches it
    /// (`.onChange(of: window.importRequestCount)`) and presents its importer.
    private(set) var importRequestCount = 0
    /// Whether this window shows the Settings sheet (Library gear button, "Settings…" ⌘,).
    var isSettingsPresented = false
    /// The page the Settings sheet opens on (`nil`: its first page). Read when the sheet is
    /// presented; cleared when it is dismissed.
    private(set) var settingsPage: SettingsPage?
    /// Increases each time a Settings page is asked for, so an open sheet can go to it.
    private(set) var settingsPageRequestCount = 0
    /// The restore sheet this window shows ("Open in" of a `.ttbackup`, the empty Library's
    /// "Restore from Backup…").
    var restoreRequest: RestoreRequest?
    /// Per book: increases when a reader on it should be rebuilt (its PDF was just linked).
    private(set) var readerGenerations: [UUID: Int] = [:]

    @ObservationIgnored weak var scene: UIWindowScene?
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var pendingOverrides: [UUID: ReaderOverrides] = [:]
    @ObservationIgnored private var hubToken: StoreChangeObservation?
    /// The reader screens shown in this window so far (weak: a popped screen's slot goes with it).
    @ObservationIgnored private var readerSlots: [WeakSlot] = []
    private final class WeakSlot {
        weak var value: ReaderSlot?
        init(_ value: ReaderSlot) { self.value = value }
    }
    /// The window's latest reader state per book (panels, section history), as also kept in
    /// scene storage: a new reader on a book in this window starts from it (a woken reader
    /// resumes its own, `ReaderSlot`).
    @ObservationIgnored private var readerStates: [UUID: ReaderSession.RestorableState] = [:]

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

    /// Opens the reader on `bookID` in this window (pushing it), optionally at a page, and
    /// optionally with the notes panel on the Section tab showing `notesHeading`'s note.
    func openReader(bookID: UUID, pageIndex: Int? = nil, notesHeading: HeadingAnchor? = nil) {
        if pageIndex != nil || notesHeading != nil {
            pendingOverrides[bookID] = ReaderOverrides(pageIndex: pageIndex, notesHeading: notesHeading)
        }
        if case .reader(let current)? = path.last, current == bookID {
            // Already showing it: the host picks up the override.
            if pageIndex != nil || notesHeading != nil { readerJumpRequests += 1 }
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

    /// "Settings…" (⌘,) and the Library gear button: show Settings over whatever this window shows.
    func showSettings() {
        if !isSettingsPresented { settingsPage = nil }
        isSettingsPresented = true
    }

    /// "Back Up & Restore…": Settings, straight on the Backup screen (pushed onto an open sheet).
    func showBackupSettings() {
        settingsPage = .backup
        settingsPageRequestCount += 1
        isSettingsPresented = true
    }

    /// The Settings sheet was dismissed.
    func settingsDidDismiss() {
        settingsPage = nil
    }

    /// Shows the restore sheet in this window. An open Settings sheet closes first (one sheet
    /// at a time).
    func openRestore(_ request: RestoreRequest) {
        guard isSettingsPresented else {
            restoreRequest = request
            return
        }
        isSettingsPresented = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.restoreRequest = request
        }
    }

    /// The window the system sign-in sheet presents over (Google Drive).
    var presentationAnchor: UIWindow? {
        scene?.keyWindow ?? scene?.windows.first
    }

    /// Rebuilds any reader on `bookID` in this window (after its PDF was linked).
    func reloadReader(bookID: UUID) {
        readerGenerations[bookID, default: 0] += 1
    }

    func readerGeneration(for bookID: UUID) -> Int {
        readerGenerations[bookID] ?? 0
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

    // MARK: Sleeping readers

    /// The window's latest reader state for a book (`nil` before any reader on it was shown).
    func readerState(for bookID: UUID) -> ReaderSession.RestorableState? {
        readerStates[bookID]
    }

    func setReaderState(_ state: ReaderSession.RestorableState, for bookID: UUID) {
        readerStates[bookID] = state
    }

    /// A reader screen was shown (pushed, or revealed by a pop or the back swipe): learns its
    /// place in the path and applies the sleep rule.
    func readerSlotDidAppear(_ slot: ReaderSlot) {
        slot.pathIndex = Self.pathIndex(ofShownReader: slot.bookID, in: path)
        if !readerSlots.contains(where: { $0.value === slot }) {
            readerSlots.append(WeakSlot(slot))
        }
        updateReaderSlots()
    }

    /// Where a reader on `bookID` that is being shown sits in `path`: the top, or the screen just
    /// under it while the back swipe reveals it (the path drops the top only when the swipe ends).
    /// Neighbouring screens are never two readers on one book.
    nonisolated static func pathIndex(ofShownReader bookID: UUID, in path: [WindowRoute]) -> Int? {
        let route = WindowRoute.reader(bookID: bookID)
        if path.last == route { return path.count - 1 }
        if path.count >= 2, path[path.count - 2] == route { return path.count - 2 }
        return nil
    }

    /// The top screen and the one directly under it stay awake; readers further down sleep.
    nonisolated static func readerStaysAwake(pathIndex: Int, pathCount: Int) -> Bool {
        pathCount - 1 - pathIndex <= 1
    }

    /// A popped reader lets its session go after this long (once its screen has animated away),
    /// even if SwiftUI still holds the screen's state.
    nonisolated static let poppedReaderSleepDelay: Duration = .seconds(1)

    /// A memory warning: every reader that is not on screen falls asleep now, the one under the
    /// top screen and any still counting down included (`WindowRootView` calls this). The reader
    /// on screen stays, and handles the warning itself (`ReaderSession.handleMemoryWarning()`).
    /// A reader put to sleep here wakes like any other: when it is shown, or when the path next
    /// changes and it is the top screen or the one under it.
    func sleepOffScreenReaders() {
        readerSlots.removeAll { $0.value == nil }
        for slot in readerSlots.compactMap(\.value) where !slot.isShown {
            slot.sleepNow()
        }
    }

    /// Wakes the readers near the top and counts down the others. `popped`: the path lost
    /// screens from its top (and nothing else changed).
    private func updateReaderSlots(popped: Bool = false) {
        readerSlots.removeAll { $0.value == nil }
        var placed: [(slot: ReaderSlot, index: Int)] = []
        for slot in readerSlots.compactMap(\.value) {
            guard let index = slot.pathIndex, path.indices.contains(index),
                  path[index] == .reader(bookID: slot.bookID) else {
                if popped, let index = slot.pathIndex, index >= path.count {
                    // Its position is saved now, before a reader it uncovers wakes.
                    slot.session?.saveLastReadPageNow()
                    slot.cancelSleep()
                    slot.scheduleSleep(after: Self.poppedReaderSleepDelay)
                } else if slot.pathIndex != nil {
                    // The path was rearranged (a deletion): no longer placed; it is placed again
                    // when shown.
                    slot.cancelSleep()
                }
                if slot.pathIndex != nil { slot.pathIndex = nil }
                continue
            }
            placed.append((slot, index))
        }
        for (slot, index) in placed {
            if Self.readerStaysAwake(pathIndex: index, pathCount: path.count) {
                slot.wake()
            } else {
                slot.scheduleSleep(after: readerSleepDelay)
            }
        }
    }

    // MARK: Other windows

    /// Opens a new reader window on the book (always a new window, even for the same book), at
    /// `pageIndex` when given (applied once; not a section-history jump), else at the book's
    /// last-read page.
    func openReaderInNewWindow(bookID: UUID, pageIndex: Int? = nil, notesHeading: HeadingAnchor? = nil) {
        openWindowAction?(id: WindowID.reader,
                          value: ReaderWindowValue(bookID: bookID, pageIndex: pageIndex, notesHeading: notesHeading))
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
        readerStates[bookID] = nil
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
