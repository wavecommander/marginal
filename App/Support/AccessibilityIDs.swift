/// Accessibility identifiers used by UI tests. One place for the whole app: later packages add
/// their own nested enum (or cases to the existing ones) here rather than inlining strings.
/// UI tests mirror the strings they use (the test target cannot import the app).
nonisolated enum AccessibilityID {
    enum Library {
        static let importButton = "library.importButton"
        /// One row/cell per book: `library.book.<title>`.
        static func book(_ title: String) -> String { "library.book.\(title)" }
    }

    enum Reader {
        static let pdfView = "reader.pdfView"
        /// Test hook (`-exposeViewportAnchor`): value "page N x X y Y scale S" (page space).
        static let viewportAnchor = "reader.viewportAnchor"
        /// Test hook (`-exposeSelection`): label = selected text, value "pages P; ms T".
        static let selectionProbe = "reader.selectionProbe"
        static let loading = "reader.loading"

        // Toolbar
        static let contentsToggle = "reader.toolbar.contents"
        /// Section history Back ("Back to Previous Section"; press and hold for the list).
        static let historyBack = "reader.toolbar.historyBack"
        /// Section history Forward ("Forward to Next Section").
        static let historyForward = "reader.toolbar.historyForward"
        static let search = "reader.toolbar.search"
        static let bookmark = "reader.toolbar.bookmark"
        static let markupToggle = "reader.toolbar.markup"
        static let notesToggle = "reader.toolbar.notes"
        static let more = "reader.toolbar.more"
        /// Undo / Redo of ink: only in markup mode at compact width (elsewhere the tool picker has them).
        static let undo = "reader.toolbar.undo"
        static let redo = "reader.toolbar.redo"
        /// The title block (fallback toolbar title before iOS 26; label = title, value = subtitle).
        static let titleBlock = "reader.toolbar.title"

        // Page
        /// The "312 of 742" pill; its label is "Page 312 of 742".
        static let pagePill = "reader.pagePill"
        static let goToPageField = "reader.goToPageField"

        // Panes
        static let contentsPane = "reader.pane.contents"
        static let contentsOverlay = "reader.pane.contentsOverlay"
        static let notesPane = "reader.pane.notes"
        static let notesSheet = "reader.pane.notesSheet"
        static let notesDivider = "reader.notesDivider"
    }

    /// Placeholders the next packages replace (keep the identifiers if convenient).
    enum Placeholder {
        static let contents = "placeholder.contents"
        static let notes = "placeholder.notes"
        static let search = "placeholder.search"
        static let notebook = "placeholder.notebook"
    }
}
