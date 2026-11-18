/// Accessibility identifiers used by UI tests. One place for the whole app: each feature adds
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
    }

    enum Library {
        static let importButton = "library.importButton"
        /// One row/cell per book: `library.book.<title>`.
        static func book(_ title: String) -> String { "library.book.\(title)" }
        /// The empty state's "Restore from Backup…" (beside "Import PDF").
        static let emptyRestoreButton = "library.emptyRestoreButton"
        /// The compact row of the app's running backup or restore (its Cancel is
        /// `Backup.progressCancel`).
        static let backupProgress = "library.backupProgress"
        /// The "PDF missing" badge on a book's cover: `library.book.<title>.pdfMissing`.
        static func pdfMissing(_ title: String) -> String { "library.book.\(title).pdfMissing" }
        /// The title of the screen shown instead of the Library when the store could not be opened.
        static let unavailable = "library.unavailable"
        /// Its "Open in This Version…" (a library from a newer version).
        static let openInThisVersion = "library.unavailable.openInThisVersion"
        /// Its "Use an Earlier Copy" menu.
        static let useEarlierCopy = "library.unavailable.useEarlierCopy"
        /// Shown once the library was changed and opens at the next launch.
        static let recoveryReady = "library.unavailable.ready"
        // Search results when notes or highlights match (`LibrarySearchResultsView`); the rows
        // themselves carry the Notebook's identifiers (`NotebookAccessibilityID`).
        static let searchResults = "library.search.results"
        /// The column of books with matches (wide windows).
        static let searchBookColumn = "library.search.books"
        /// "All Books" in that column.
        static let searchAllBooks = "library.search.allBooks"
        /// A book in that column: `library.search.book.<title>`.
        static func searchBook(_ title: String) -> String { "library.search.book.\(title)" }
        /// A book whose title matches: `library.search.title.<title>`.
        static func searchTitle(_ title: String) -> String { "library.search.title.\(title)" }
        /// The results column.
        static let searchFeed = "library.search.feed"
        /// A book's header in the results column: `library.search.header.<title>`.
        static func searchHeader(_ title: String) -> String { "library.search.header.\(title)" }
    }

    /// Settings ▸ Backup & Restore and a destination's screen.
    enum Backup {
        /// The Settings row that opens the Backup screen.
        static let settingsRow = "settings.backup"
        static let screen = "backup.screen"
        /// Done on the Backup screens (closes Settings).
        static let done = "backup.done"
        // Back up to a file
        static let fileIncludePDFs = "backup.file.includePDFs"
        static let fileEstimate = "backup.file.estimate"
        static let saveFile = "backup.file.save"
        static let fileStatus = "backup.file.status"
        /// One row per destination: `backup.destination.<destination id>`.
        static func destination(_ id: String) -> String { "backup.destination.\(id)" }
        // Automatic backup
        static let automaticToggle = "backup.automatic.toggle"
        static let automaticDestination = "backup.automatic.destination"
        static let automaticIncludePDFs = "backup.automatic.includePDFs"
        static let automaticStatus = "backup.automatic.status"
        // Restore
        static let restoreFromFile = "backup.restoreFromFile"
        /// Undo Last Restore (shown only when a restore can be undone).
        static let undoRestore = "backup.undoRestore"
        /// The result of the last undo.
        static let undoResult = "backup.undoRestore.result"
        static let footnote = "backup.footnote"
        // The running job (Backup screens, restore sheet)
        static let progress = "backup.progress"
        static let progressStatus = "backup.progress.status"
        static let progressCancel = "backup.progress.cancel"
        // A destination's screen
        static let destinationScreen = "backup.destinationScreen"
        static let destinationStatus = "backup.destinationScreen.status"
        static let destinationIncludePDFs = "backup.destinationScreen.includePDFs"
        static let backUpNow = "backup.destinationScreen.backUpNow"
        static let destinationResult = "backup.destinationScreen.result"
        static let chooseFolder = "backup.destinationScreen.chooseFolder"
        static let folderFooter = "backup.destinationScreen.folder.footer"
        /// One row per backup at the destination: `backup.snapshot.<snapshot name>`.
        static func snapshot(_ name: String) -> String { "backup.snapshot.\(name)" }
        static let snapshotsEmpty = "backup.snapshots.empty"
        static let snapshotsLoading = "backup.snapshots.loading"
    }

    /// Tactile Texts Cloud's screens: the offer, the status page, the recovery key.
    enum CloudBackup {
        static let checking = "cloud.checking"
        // The offer
        static let offer = "cloud.offer"
        /// One Subscribe button per product: `cloud.subscribe.<product id>`.
        static func subscribe(_ productID: String) -> String { "cloud.subscribe.\(productID)" }
        static let offerUnavailable = "cloud.offer.unavailable"
        static let restorePurchases = "cloud.restorePurchases"
        static let terms = "cloud.terms"
        static let privacy = "cloud.privacy"
        static let notice = "cloud.notice"
        // Signing in (the offer, signed out)
        static let signInApple = "cloud.signIn.apple"
        static let signInGoogle = "cloud.signIn.google"
        /// Why this iPad was signed out (session ended, Apple revoked, account deleted).
        static let signedOutNotice = "cloud.signedOut"
        // The account (signed in)
        static let accountSignIn = "cloud.account.signIn"
        /// One row per device: `cloud.account.device.<n>`, oldest first from 0.
        static func device(_ index: Int) -> String { "cloud.account.device.\(index)" }
        static let changeSignIn = "cloud.account.change"
        static let signOut = "cloud.account.signOut"
        static let signOutAll = "cloud.account.signOutAll"
        static let deleteAccount = "cloud.account.delete"
        static let accountBusy = "cloud.account.busy"
        // The status page
        static let status = "cloud.status"
        static let banner = "cloud.banner"
        static let bannerTryAgain = "cloud.banner.tryAgain"
        static let bannerEnterKey = "cloud.banner.enterKey"
        static let bannerResubscribe = "cloud.banner.resubscribe"
        static let plan = "cloud.plan"
        static let renewal = "cloud.renewal"
        static let usage = "cloud.usage"
        static let lastBackup = "cloud.lastBackup"
        static let manageSubscription = "cloud.manageSubscription"
        static let keyReminder = "cloud.keyReminder"
        static let showKey = "cloud.showKey"
        static let deleteAll = "cloud.deleteAll"
        static let deleting = "cloud.deleting"
        // The recovery key
        static let keyScreen = "cloud.recoveryKey"
        static let keyText = "cloud.recoveryKey.text"
        static let keyCopy = "cloud.recoveryKey.copy"
        static let keyShare = "cloud.recoveryKey.share"
        static let keySaved = "cloud.recoveryKey.saved"
        static let keyClose = "cloud.recoveryKey.close"
        // Entering the recovery key
        static let enterScreen = "cloud.enterKey"
        static let enterField = "cloud.enterKey.field"
        static let enterProgress = "cloud.enterKey.progress"
        static let enterSubmit = "cloud.enterKey.submit"
        static let enterError = "cloud.enterKey.error"
        static let enterTryAgain = "cloud.enterKey.tryAgain"
        static let enterStartOver = "cloud.enterKey.startOver"
        static let enterCancel = "cloud.enterKey.cancel"
    }

    /// The restore sheet: preview, progress and summary.
    /// Sync (C4b): the section on the Tactile Texts Cloud page, the join sheet, and the states
    /// in the Library and the reader.
    enum Sync {
        static let section = "sync.section"
        static let toggle = "sync.toggle"
        /// The status line; its value names the state (`SyncSectionView.statusValue`).
        static let status = "sync.status"
        /// The status line's button (Try Again, Enter Recovery Key…, Review…).
        static let statusAction = "sync.status.action"
        static let syncNow = "sync.now"
        static let pdfPolicy = "sync.pdfPolicy"
        /// DEBUG with `-syncTestFolder`: the rounds this launch has started, as its value.
        static let debugRounds = "sync.debug.rounds"
        // The join sheet
        static let joinSheet = "sync.join"
        static let joinOnlyHere = "sync.join.onlyHere"
        static let joinOnlyInAccount = "sync.join.onlyInAccount"
        static let joinInBoth = "sync.join.inBoth"
        static let joinConfirm = "sync.join.confirm"
        static let joinNotNow = "sync.join.notNow"
        // The Library
        /// A synced book's PDF download state: `library.book.<title>.download` (value: the state).
        static func download(_ title: String) -> String { "library.book.\(title).download" }
        /// A book that is not yet up to date: `library.book.<title>.syncState`.
        static func bookState(_ title: String) -> String { "library.book.\(title).syncState" }
        // The reader (a synced book opened without its PDF)
        static let readerDownload = "reader.syncDownload"
        static let readerDownloadCancel = "reader.syncDownload.cancel"
        static let readerDownloadRetry = "reader.syncDownload.retry"
    }

    enum Restore {
        static let sheet = "restore.sheet"
        static let header = "restore.header"
        /// A book's checkbox: `restore.book.<title>`; value "Selected" or "Not selected".
        static func book(_ title: String) -> String { "restore.book.\(title)" }
        static func status(_ title: String) -> String { "restore.book.\(title).status" }
        static func replaceWarning(_ title: String) -> String { "restore.book.\(title).replaceWarning" }
        static func pdfSource(_ title: String) -> String { "restore.book.\(title).pdf" }
        /// A book already in the Library: the Merge / Replace with Backup / Leave as Is menu
        /// (value: the current choice's title).
        static func action(_ title: String) -> String { "restore.book.\(title).action" }
        /// What a merge would add and combine.
        static func mergeText(_ title: String) -> String { "restore.book.\(title).mergeText" }
        static func leaveText(_ title: String) -> String { "restore.book.\(title).leaveText" }
        /// "In a merge, anything deleted on this iPad … comes back".
        static let mergeFootnote = "restore.mergeFootnote"
        static let restorePDFs = "restore.restorePDFs"
        static let confirm = "restore.confirm"
        static let cancel = "restore.cancel"
        static let summary = "restore.summary"
        /// A merged book in the summary: `restore.summary.merged.<title>`.
        static func merged(_ title: String) -> String { "restore.summary.merged.\(title)" }
        /// "To put things back as they were, use Undo Last Restore…".
        static let undoHint = "restore.summary.undoHint"
        /// "Locate PDF…" for a restored book without its PDF: `restore.summary.locate.<title>`.
        static func locate(_ title: String) -> String { "restore.summary.locate.\(title)" }
        static let done = "restore.done"
        static let error = "restore.error"
        static let opening = "restore.opening"
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
        static let memoryWarningProbe = "reader.memoryWarning"
        static let loading = "reader.loading"
        /// The "Cannot Open Book" state's "Locate PDF…" and "Open Notebook" (book without its PDF).
        static let locatePDF = "reader.locatePDF"
        static let missingPDFNotebook = "reader.missingPDF.notebook"

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
        /// The ink Undo / Redo over a maximized page (markup mode at compact width, as in the
        /// toolbar).
        static let maximizedUndo = "reader.maximized.undo"
        static let maximizedRedo = "reader.maximized.redo"
        /// Undo / Redo of ink: only in markup mode at compact width (elsewhere the tool picker has them).
        static let undo = "reader.toolbar.undo"
        static let redo = "reader.toolbar.redo"
        /// The title block (fallback toolbar title before iOS 26; label = title, value = subtitle).
        static let titleBlock = "reader.toolbar.title"

        // Page
        /// The "312 of 742" pill; its label is "Page 312 of 742".
        static let pagePill = "reader.pagePill"
        static let goToPageField = "reader.goToPageField"
        static let goToPageGo = "reader.goToPageGo"
        static let goToPageNumPad = "reader.goToPageNumPad"
        static func goToPageKey(_ key: String) -> String { "reader.goToPageNumPad.\(key)" }

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
        /// The "Settings…" item in the Reader's More menu.
        static let readerMenuItem = "reader.more.settings"
        static let sheet = "settings.sheet"
        static let done = "settings.done"
        /// One swatch per preset: `settings.accent.<rawValue>`; value "selected" on the chosen one.
        static func accent(_ rawValue: String) -> String { "settings.accent.\(rawValue)" }
        static let reset = "settings.accent.reset"
        static let preview = "settings.accent.preview"
        /// Settings ▸ About: the build's version, branch, commit and time (`BuildInfo`).
        static let aboutVersion = "settings.about.version"
        static let aboutBranch = "settings.about.branch"
        static let aboutCommit = "settings.about.commit"
        static let aboutBuilt = "settings.about.built"
        static let aboutCopy = "settings.about.copy"
        static let aboutMadeBy = "settings.about.madeBy"
    }

    /// The reader's "Export Marked-Up PDF" (More menu) and its progress card.
    enum MarkedUpExport {
        /// The submenu in the reader's More menu.
        static let menu = "reader.more.exportMarkedUp"
        static let bookOnly = "reader.more.exportMarkedUp.bookOnly"
        static let withNotes = "reader.more.exportMarkedUp.withNotes"
        static let progress = "reader.exportMarkedUp.progress"
        static let cancel = "reader.exportMarkedUp.cancel"
        /// The confirmation alert's buttons.
        static let confirmExport = "reader.exportMarkedUp.confirm.export"
        static let confirmCancel = "reader.exportMarkedUp.confirm.cancel"
        /// The progress card's "Continue in Background".
        static let background = "reader.exportMarkedUp.background"
        /// "About 3 minutes left" (progress card and status pill).
        static let timeLeft = "reader.exportMarkedUp.timeLeft"
        /// The status pill shown while the export runs in the background, or when it is ready.
        static let status = "reader.exportMarkedUp.status"
        static let backgroundCancel = "reader.exportMarkedUp.status.cancel"
        static let share = "reader.exportMarkedUp.status.share"
        /// Puts away the pill of an export that ended (the file is kept).
        static let hide = "reader.exportMarkedUp.status.hide"
        static let retry = "reader.exportMarkedUp.status.retry"
        /// "Stop Export" in the "Stop Exporting?" confirmation.
        static let confirmStop = "reader.exportMarkedUp.confirm.stop"
        /// "Delete" in the "Delete Exported PDF?" confirmation.
        static let confirmDelete = "reader.exportMarkedUp.confirm.delete"
        /// The Notebook's "Exported PDFs" section and its rows (row IDs end in the file name).
        static let notebookSection = "notebook.exportedPDFs"
        static let notebookRow = "notebook.exportedPDFs.row"
        static let notebookShare = "notebook.exportedPDFs.share"
        static let notebookDelete = "notebook.exportedPDFs.delete"
        static let notebookStop = "notebook.exportedPDFs.stop"
        static let notebookRetry = "notebook.exportedPDFs.retry"
    }

    /// Placeholders the next packages replace (keep the identifiers if convenient).
    enum Placeholder {
        static let contents = "placeholder.contents"
        static let notes = "placeholder.notes"
        static let search = "placeholder.search"
        static let notebook = "placeholder.notebook"
    }
}
