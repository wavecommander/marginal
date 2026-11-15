import SwiftUI

/// The menu bar (iPadOS 26+) / keyboard shortcut overlay (earlier) commands. Every reader
/// command acts on the **focused window's** session (`focusedSceneValue`) and is disabled when
/// no reader is focused. Undo/Redo of markup are the system Edit ▸ Undo/Redo (⌘Z / ⇧⌘Z): in
/// markup mode the first responder is the session's `MarkupResponderView`, whose `undoManager`
/// (`MarkupRoutingUndoManager`) acts on the surface last drawn on; the tool picker's own
/// Undo/Redo buttons use the same manager.
struct ReaderCommands: Commands {
    @FocusedValue(ReaderSession.self) private var session
    @FocusedValue(WindowContext.self) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Library Window") {
                if let window { window.openNewLibraryWindow() } else { openWindow(id: WindowID.library) }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Open in New Window") {
                if let session { window?.openReaderInNewWindow(bookID: session.book.id) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(session == nil)
            Button("Open Notebook") {
                if let session { window?.openNotebookInNewWindow(bookID: session.book.id) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(session == nil)
            Divider()
            Button("Import…") { window?.requestImport() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(window == nil)
            Button("Back Up & Restore…") { window?.showBackupSettings() }
                .disabled(window == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { window?.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(window == nil)
        }

        // Contents is the reader's sidebar: it replaces the system "Show Sidebar" item (⌃⌘S).
        // Adding ⌃⌘S beside the system item crashes the main-menu build ("Replacement elements
        // contain duplicates"), so the group is replaced, not appended to.
        CommandGroup(replacing: .sidebar) {
            Button(session?.isContentsShown == true ? "Hide Contents" : "Show Contents") {
                session?.toggleContents()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(session == nil)
            Button(session?.isNotesVisible == true ? "Hide Notes" : "Show Notes") {
                session?.toggleNotes()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(session == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { session?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { session?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
            Button("Actual Size") { session?.zoomToActualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)
            Button("Fit Width") { session?.zoomToFitWidth() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(session == nil)
            Divider()
            Button("Scroll Vertically") { session?.setScrollDirection(.vertical) }
                .disabled(session == nil || session?.scrollDirection == .vertical)
            Button("Scroll Horizontally") { session?.setScrollDirection(.horizontal) }
                .disabled(session == nil || session?.scrollDirection == .horizontal)
        }

        // Notes are plain text (design): the system Format menu (Bold ⌘B, Bigger ⌘+, Smaller ⌘-…)
        // is removed so it can never collide with Zoom In/Out when a text view is focused.
        CommandGroup(replacing: .textFormatting) {}

        CommandMenu("Go") {
            Button("Back to Library") { window?.backToLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
            Button("Go to Page…") { session?.showGoToPage() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Next Page") { session?.goToNextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(session?.canGoToNextPage != true)
            Button("Previous Page") { session?.goToPreviousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(session?.canGoToPreviousPage != true)
            Button("First Page") { session?.jumpToFirstPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Last Page") { session?.jumpToLastPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
            Button("Back to Previous Section") { session?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session?.canGoBack != true)
            Button("Forward to Next Section") { session?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session?.canGoForward != true)
        }

        CommandMenu("Book") {
            // ⇧⌘F, not ⌘F: the system Find group (⌘F, ⌘G, ⌘E…) appears while a text field is
            // first responder, and a duplicate shortcut aborts the main-menu build.
            Button("Find in Book…") { session?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(session == nil)
            // ⌃⌘G / ⌃⇧⌘G: the system Find group owns ⌘G / ⇧⌘G (Find Next / Previous).
            Button("Next Result") { activeSearch?.selectNext() }
                .keyboardShortcut("g", modifiers: [.command, .control])
                .disabled(activeSearch == nil)
            Button("Previous Result") { activeSearch?.selectPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .control, .shift])
                .disabled(activeSearch == nil)
            Button("Add Heading at This Page…") { session?.requestAddHeading() }
                .keyboardShortcut("h", modifiers: [.command, .option])
                .disabled(session == nil)
            Button(bookmarkTitle) {
                if let session { BookmarkActions.toggle(session: session) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(session == nil)
            Divider()
            Button(session?.isMarkupMode == true ? "Done with Markup" : "Markup") {
                session?.toggleMarkup()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(session == nil)
            Button("Undo Markup") { session?.markup.undo() }
                .disabled(session?.isMarkupMode != true || session?.markup.canUndo != true)
            Button("Redo Markup") { session?.markup.redo() }
                .disabled(session?.isMarkupMode != true || session?.markup.canRedo != true)
        }
    }

    /// The focused reader's search, if one exists and has results to step through.
    private var activeSearch: SearchModel? {
        guard let model = session?.existingFeatureState(SearchModel.self), model.canStep else { return nil }
        return model
    }

    private var bookmarkTitle: String {
        guard let session else { return "Add Bookmark" }
        _ = session.revisions.bookmarks
        return BookmarkActions.isBookmarked(session: session) ? "Remove Bookmark" : "Add Bookmark"
    }
}
