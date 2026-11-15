/// Accessibility identifiers used by UI tests. One place for the whole app: later packages add
/// their own nested enum (or cases to the existing ones) here rather than inlining strings.
/// UI tests mirror the strings they use (the test target cannot import the app).
nonisolated enum AccessibilityID {
    enum Onboarding {
        static let welcomeTitle = "onboarding.welcome.title"
        static let welcomeOpenGuide = "onboarding.welcome.openGuide"
        static let welcomeNotNow = "onboarding.welcome.notNow"
        /// "Open the Quick Guide" in the empty Library.
        static let emptyLibraryOpenGuide = "library.emptyOpenGuide"
        /// Settings ▸ Help.
        static let settingsOpenGuide = "settings.help.openGuide"
        static let settingsShowTips = "settings.help.showTips"
    }

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
        /// Test hooks (`-exposeMarkupState`, `ReaderStateProbe`): markup, tool picker, notes and
        /// undo state as `key=value` tokens; the two buttons undo / redo through the markup
        /// responder's undo manager.
        static let markupState = "reader.markupState"
        static let markupUndoProbe = "reader.markupUndo"
        static let markupRedoProbe = "reader.markupRedo"
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

    enum Settings {
        /// The Library toolbar's gear button.
        static let openButton = "settings.open"
        static let sheet = "settings.sheet"
        static let done = "settings.done"
        /// One swatch per preset: `settings.accent.<rawValue>`; value "selected" on the chosen one.
        static func accent(_ rawValue: String) -> String { "settings.accent.\(rawValue)" }
        static let reset = "settings.accent.reset"
        static let preview = "settings.accent.preview"
    }

    /// Placeholders the next packages replace (keep the identifiers if convenient).
    enum Placeholder {
        static let contents = "placeholder.contents"
        static let notes = "placeholder.notes"
        static let search = "placeholder.search"
        static let notebook = "placeholder.notebook"
    }
}
