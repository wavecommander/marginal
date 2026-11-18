import Foundation
import Observation
import ReaderBackup
import ReaderCore
import ReaderStore
import SwiftUI

/// The composition root: created once per process by `TactileTextsApp` and shared by every window
/// through the SwiftUI environment (`@Environment(AppEnvironment.self)`). Holds only app-wide
/// things: the one `LibraryStore`, the launch options, and launch-time work. Nothing per window
/// lives here (that is `WindowContext` and `ReaderSession`).
@Observable
@MainActor
final class AppEnvironment {
    /// The shared store (one `ModelContainer` for the app).
    let store: LibraryStore
    /// Parsed launch arguments.
    let launchOptions: LaunchOptions
    /// Set when the persistent store failed to open and an in-memory store is used instead.
    /// Every window then shows `LibraryUnavailableView` instead of the Library, so nothing is
    /// imported or written into a store that vanishes when the app quits, and automatic backups
    /// stay off. It holds the ways back in (open a newer library in this version, put back a copy).
    let libraryRecovery: LibraryRecovery?
    /// The store's error when it failed to open (`libraryRecovery`), else `nil`.
    var storeErrorMessage: String? { libraryRecovery?.details }
    /// The app's one import pipeline, shared by every window.
    @ObservationIgnored let importService: ImportService
    /// The fixture importer (`-importFixture`), handed `importService`.
    @ObservationIgnored let fixtureImporter: FixtureImporter
    /// Backup and restore, one job at a time for the app (beside the import service).
    @ObservationIgnored let backupService: BackupService
    /// The backup destinations the app offers.
    @ObservationIgnored let backupDestinations: BackupDestinationRegistry
    /// The folder the reader picked in Files to back up to (the Backup screen sets and clears it).
    @ObservationIgnored let backupFolderStore: BackupFolderStore
    /// Tactile Texts Cloud (subscription, account, destination); `nil` unless the build sets
    /// `BACKUP_SERVICE_HOST` and `BACKUP_PRODUCT_IDS` (empty by default).
    @ObservationIgnored let cloudBackup: TactileCloudBackup?
    /// Automatic-backup preferences and the outcome of the last automatic run.
    @ObservationIgnored let backupAutomaticSettings: BackupAutomaticSettings
    /// Runs automatic backups (`TactileTextsApp` registers its background task and forwards the
    /// scene phase). Disarmed in a `-resetState` launch until automatic backups are switched on.
    @ObservationIgnored let backupScheduler: BackupScheduler
    /// First-run onboarding: the welcome sheet, the Quick Guide and tip resets.
    let onboarding: OnboardingCoordinator
    /// Every marked-up PDF export and the files they made, kept until the user deletes them
    /// (`<store root>/Marked-Up Exports`).
    let markedUpExports: MarkedUpExportLibrary
    /// Sync with Tactile Texts Cloud (`SyncService`), `nil` when the build has no service (and no
    /// `-syncTestFolder`). C4b's Sync switch, status line and scheduler drive it.
    @ObservationIgnored let syncService: SyncService?
    /// The library side of sync, shared by every account's engine (`nil` with `syncService`).
    @ObservationIgnored let syncLibrary: LibrarySyncCore?
    /// Sync as the reader meets it: the switch, the scheduler, PDF downloads and the join (`nil`
    /// with `syncService`). The Sync section appears only on the Tactile Texts Cloud page, so a
    /// build without the service shows no sync anywhere.
    @ObservationIgnored let sync: SyncController?
    /// The change origin of the launch-time merge of books with one PDF.
    @ObservationIgnored let duplicateMergeOrigin = ChangeOrigin(label: "duplicate books")
    /// The one text-recognition queue for scanned books (started after launch work). The
    /// search status (S3) calls its entry points; progress reaches windows through the hub.
    @ObservationIgnored let textRecognition: TextRecognitionEngine

    @ObservationIgnored private var launchTask: Task<LaunchPlan, Never>?
    @ObservationIgnored private var launchPlanClaimed = false

    /// What the first window does after launch (from the launch arguments).
    struct LaunchPlan: Sendable {
        /// The first window's navigation path (empty: the Library).
        var path: [WindowRoute] = []
        /// Overrides for the reader opened by `-openBook` (page, markup, notes tab).
        var readerOverrides: ReaderOverrides?
        /// `-alsoOpenWindow`: open a second reader window on this book.
        var alsoOpenBookID: UUID?
        /// `-alsoOpenWindowPage`: the zero-based page that window opens at.
        var alsoOpenPageIndex: Int?
        /// `-importFixture` files waiting for the Convert to PDF sheet: the first window takes
        /// these requests (`ImportService.address`).
        var conversionRequestIDs: [UUID] = []
        /// Import failures, for diagnostics.
        var errors: [String] = []
    }

    /// - Parameter infoDictionary: the build's settings (the app's `Info.plist`; tests pass their own).
    init(store: LibraryStore, launchOptions: LaunchOptions, libraryRecovery: LibraryRecovery? = nil,
         infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.store = store
        self.launchOptions = launchOptions
        self.libraryRecovery = libraryRecovery
        let importService = ImportService(store: store, converters: FixtureImporter.converters(for: launchOptions))
        self.importService = importService
        self.fixtureImporter = FixtureImporter(service: importService)
        self.onboarding = OnboardingCoordinator()
        self.markedUpExports = MarkedUpExportLibrary(
            archive: MarkedUpExportArchive(root: MarkedUpExportArchive.defaultRoot(storeRoot: store.rootDirectory)))
        self.textRecognition = TextRecognitionEngine(store: store)
        let backupService = BackupService(store: store)
        let backupDestinations = BackupDestinationRegistry()
        let backupAutomaticSettings = BackupAutomaticSettings()
        self.backupService = backupService
        self.backupDestinations = backupDestinations
        self.backupAutomaticSettings = backupAutomaticSettings
        // Never armed when the library could not be opened: the stand-in store is empty, and an
        // automatic backup of it would look like a backup of a library with no books.
        self.backupScheduler = BackupScheduler(settings: backupAutomaticSettings, service: backupService,
                                               destinations: backupDestinations,
                                               armed: !launchOptions.resetState && libraryRecovery == nil)
        let backupFolderStore = BackupFolderStore()
        self.backupFolderStore = backupFolderStore
        if let folder = launchOptions.backupFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            backupDestinations.register(FolderBackupDestination(root: folder))
        }
        // The folder picked in Files (which is how iCloud Drive, Google Drive and other
        // providers are reached; it reports itself unavailable until a folder is chosen), then
        // the developer's S3-compatible bucket when the build is configured for one.
        backupDestinations.register(PickedFolderBackupDestination(store: backupFolderStore))
        if let s3 = BackupDestinationFactory.s3() { backupDestinations.register(s3) }
        // Tactile Texts Cloud, last, only when the build is configured for the service.
        var cloudBackup: TactileCloudBackup?
        #if DEBUG
        // `-cloudBackupUITest <state>`: the service on fakes, for UI tests and screenshots.
        cloudBackup = launchOptions.cloudBackupUITest.flatMap { CloudBackupUITestMode.make(stateName: $0) }
        #endif
        if cloudBackup == nil { cloudBackup = TactileCloudBackup.make(infoDictionary: infoDictionary) }
        self.cloudBackup = cloudBackup
        InkContentSupport.prepare()
        // Sync, over the service when the build has it (C4b decides when it runs).
        var syncAccess: (any SyncAccountProvider)?
        #if DEBUG
        let testAccess = launchOptions.syncTestFolder.flatMap { SyncTestAccess.make(folder: $0) }
        if let testAccess {
            syncAccess = testAccess
            // With the fake service too, the test account follows its sign-in.
            if let cloudBackup { testAccess.accountID = cloudBackup.signIn.isSignedIn ? SyncTestAccess.accountID : nil }
        }
        #endif
        if syncAccess == nil, let cloudBackup, let connection = cloudBackup.account.connection {
            let signIn = cloudBackup.signIn
            syncAccess = TactileCloudSyncAccess(connection: connection, accountID: { [weak signIn] in
                await MainActor.run { signIn?.accountID }
            })
        }
        if let syncAccess, libraryRecovery == nil {
            let core = LibrarySyncCore(store: store)
            let service = SyncService(library: core, access: syncAccess,
                                      root: SyncService.defaultRoot(storeRoot: store.rootDirectory))
            service.backupService = backupService
            backupService.beforeJob = { [weak service] in await service?.stopForBackupJob() }
            let controller = SyncController(service: service, store: store, backupService: backupService)
            #if DEBUG
            let signInForTest = cloudBackup?.signIn
            cloudBackup?.account.onSignInChanged = { [weak service, weak controller, weak signInForTest] in
                if let testAccess {
                    testAccess.accountID = signInForTest?.isSignedIn == true ? SyncTestAccess.accountID : nil
                }
                service?.signInChanged()
                controller?.signInChanged()
            }
            #else
            cloudBackup?.account.onSignInChanged = { [weak service, weak controller] in
                service?.signInChanged()
                controller?.signInChanged()
            }
            #endif
            // Sync shares the backup's background processing task.
            backupScheduler.companion = controller.scheduler
            self.syncLibrary = core
            self.syncService = service
            self.sync = controller
        } else {
            self.syncLibrary = nil
            self.syncService = nil
            self.sync = nil
        }
        if let cloudBackup {
            backupDestinations.register(cloudBackup.destination)
            // Automatic backup is on by default for a signed-in subscriber (unless the reader
            // already set automatic backups up, or turned them off).
            cloudBackup.account.onActiveSubscriber = { [weak backupAutomaticSettings] in
                backupAutomaticSettings?.applyDefault(destinationID: TactileCloudBackupDestination.destinationID)
            }
            cloudBackup.start()
        }
        // Jobs wait for launch work: it finishes interrupted restores and removes their leftovers.
        backupService.waitUntilReady = { [weak self] in _ = await self?.launchPlan() }
        backupScheduler.waitUntilReady = { [weak self] in _ = await self?.launchPlan() }
        syncService?.waitUntilReady = { [weak self] in _ = await self?.launchPlan() }
        if let sync { Task { await sync.start() } }
    }

    /// Saves every open reader's and note editor's pending text and ink, and waits for it (the
    /// backup engine runs this before reading a snapshot and before a restore commits). Editors
    /// whose book was deleted or replaced save nothing.
    func flushOpenEditors() async {
        await OpenEditorRegistry.shared.flushAll(store: store)
    }

    /// The live environment: `LibraryStore.live(reset: -resetState)`, falling back to an
    /// in-memory store (with `libraryRecovery` set) if the persistent store cannot open.
    static func makeLive(launchOptions: LaunchOptions = .current) -> AppEnvironment {
        PerfMarks.mark("storeOpening")
        defer { PerfMarks.mark("storeOpen") }
        if launchOptions.resetState {
            // The notes panel's level picker starts collapsed in a fresh state, as on a first launch.
            UserDefaults.standard.removeObject(forKey: NotesLevelPicker.expandedKey)
            UserDefaults.standard.removeObject(forKey: NotesPanelRegions.collapsedKey)
            UserDefaults.standard.removeObject(forKey: AccentChoice.storageKey)
            // A fresh state has no backup folder chosen and automatic backups off.
            UserDefaults.standard.removeObject(forKey: BackupFolderStore.defaultKey)
            BackupAutomaticSettings.reset(in: .standard)
            ReaderScrollDirectionStore().removeAll()
            ReaderNotesPanelStore().removeAll()
            ReaderPositionStore().removeAll()
            // Sync off for every account, PDFs downloaded automatically.
            SyncSettings.reset(in: .standard)
        }
        OnboardingState().applyLaunch(resetState: launchOptions.resetState, option: launchOptions.onboarding)
        if let accent = launchOptions.accent {
            UserDefaults.standard.set(accent.rawValue, forKey: AccentChoice.storageKey)
        }
        var resetState = launchOptions.resetState
        #if DEBUG
        if let planted = launchOptions.plantLibraryStore {
            // `-plantLibraryStore`: this file is the library's store (after any reset).
            do {
                let root = try LibraryStore.defaultRootDirectory()
                if resetState { try LibraryStore.removeAllData(rootDirectory: root) }
                resetState = false
                let database = root.appendingPathComponent(ReaderStore.databaseDirectoryName, isDirectory: true)
                let storeURL = database.appendingPathComponent(ReaderStore.databaseFileName)
                try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
                }
                try FileManager.default.copyItem(at: planted, to: storeURL)
            } catch {
                print("plantLibraryStore: \(error)")
            }
        }
        #endif
        do {
            let store = try LibraryStore.live(reset: resetState)
            if launchOptions.resetState {
                // A reset wipes `Database` and `Books`; an interrupted restore left by an earlier
                // run must not be rolled forward into the empty library.
                try? FileManager.default.removeItem(at: RestoreLayout.root(storeRoot: store.rootDirectory))
                try? FileManager.default.removeItem(at: RestoreSafetyStore.root(storeRoot: store.rootDirectory))
                try? FileManager.default.removeItem(at: MarkedUpExportArchive.defaultRoot(storeRoot: store.rootDirectory))
                // A fresh library has never synced: no bases, no join mark (it joins afresh).
                try? FileManager.default.removeItem(at: SyncService.defaultRoot(storeRoot: store.rootDirectory))
            }
            return AppEnvironment(store: store, launchOptions: launchOptions)
        } catch {
            let root = (try? LibraryStore.defaultRootDirectory())
                ?? URL.applicationSupportDirectory
            return AppEnvironment(store: .inMemory(), launchOptions: launchOptions,
                                  libraryRecovery: LibraryRecovery(error: error, rootDirectory: root))
        }
    }

    // MARK: Launch

    /// Launch work, run once per process and shared by every caller: finish any restore a crash
    /// interrupted (`RestoreRecovery`, which must come first: the sweep would delete a
    /// swapped-in book directory whose record is not committed yet), sweep orphaned book
    /// directories (before any import), import `-importFixture` files in order, then resolve
    /// `-openBook`, `-screen` and `-alsoOpenWindow` into a plan.
    func launchPlan() async -> LaunchPlan {
        if let launchTask { return await launchTask.value }
        let task = Task { await self.runLaunchTasks() }
        launchTask = task
        return await task.value
    }

    /// `true` for the first caller only: the first window applies the launch plan.
    func claimLaunchPlan() -> Bool {
        defer { launchPlanClaimed = true }
        return !launchPlanClaimed
    }

    /// The book whose title matches (case-insensitively), most recently added first.
    func book(titled title: String) -> Book? {
        let books = (try? store.books.allBooks()) ?? []
        return books
            .filter { $0.title.compare(title, options: [.caseInsensitive]) == .orderedSame }
            .max { $0.addedAt < $1.addedAt }
    }

    private func runLaunchTasks() async -> LaunchPlan {
        PerfMarks.mark("launchTasks")
        defer { PerfMarks.mark("launchPlan") }
        var plan = LaunchPlan()
        backupService.removeStaleTemporaryFiles()
        RestoreSafetyStore.removeStale(storeRoot: store.rootDirectory)
        let recovery = await RestoreRecovery.recover(store: store, origin: backupService.origin)
        if !recovery.rolledForward.isEmpty || !recovery.rolledBack.isEmpty || !recovery.keptSessions.isEmpty {
            backupLog.notice("restore recovery: \(recovery.rolledForward.count) finished, \(recovery.rolledBack.count) undone, \(recovery.keptSessions.count) kept")
        }
        _ = try? await store.sweepOrphanedBookDirectories()
        PerfMarks.mark("sweepDone")
        // One book per PDF: books that hold one PDF are merged into the oldest, before sync or
        // any import can run (idempotent, so a crash part-way is finished here next time).
        if libraryRecovery == nil {
            _ = await LibraryDuplicateMerge.run(store: store, origin: duplicateMergeOrigin)
        }
        #if DEBUG
        // `-syncTestSeedBook`: another "device" puts books in the test account first.
        if let folder = launchOptions.syncTestFolder, !launchOptions.syncTestSeedBooks.isEmpty {
            await SyncTestSeed.seed(folder: folder, books: launchOptions.syncTestSeedBooks)
        }
        #endif
        var imported: [Book] = []
        for url in launchOptions.importFixtures {
            let result = await fixtureImporter.importFixture(at: url, confirmConversions: launchOptions.confirmConversions)
            if let book = result.book {
                imported.append(book)
            } else if let requestID = result.conversionRequestID {
                plan.conversionRequestIDs.append(requestID)
            } else if let error = result.error {
                plan.errors.append("\(url.lastPathComponent): \(error)")
            }
        }

        var target: Book?
        if let title = launchOptions.openBook {
            target = book(titled: title)
        } else if launchOptions.screen == .reader || launchOptions.screen == .notebook {
            target = imported.first ?? ((try? store.books.allBooks()) ?? []).max {
                ($0.lastOpenedAt ?? $0.addedAt) < ($1.lastOpenedAt ?? $1.addedAt)
            }
        }
        if let target {
            switch launchOptions.screen ?? .reader {
            case .library:
                break
            case .reader:
                plan.path = [.reader(bookID: target.id)]
                plan.readerOverrides = ReaderOverrides(
                    pageIndex: launchOptions.openPage.map(PageNumbering.pageIndex(forDisplayNumber:)),
                    startInMarkup: launchOptions.markup,
                    startMaximized: launchOptions.maximized,
                    notesTab: launchOptions.notesPanel.flatMap { ReaderSession.NotesTab(rawValue: $0.rawValue) })
            case .notebook:
                plan.path = [.notebook(bookID: target.id)]
            }
        }
        if let title = launchOptions.alsoOpenWindow {
            plan.alsoOpenBookID = book(titled: title)?.id
            plan.alsoOpenPageIndex = launchOptions.alsoOpenWindowPage.map(PageNumbering.pageIndex(forDisplayNumber:))
        }
        // Scanned books in progress resume once interrupted restores are finished and orphans
        // swept; the plan does not wait for it.
        Task { await self.textRecognition.start() }
        return plan
    }

    // MARK: Incoming documents (Library import hook)

    /// "A document URL arrived from outside" (Files "Open in", a document opened from another
    /// app): a PDF or any format the app converts. Every window root forwards `.onOpenURL` here.
    /// The behaviour is in `IncomingDocumentHandler` (in the Library folder).
    func handleIncomingPDF(_ url: URL, in window: WindowContext) {
        onboarding.documentArrived()
        IncomingDocumentHandler.handle(url, environment: self, window: window)
    }
}

/// One-shot overrides for a reader opened by a launch argument or by a link to a page.
nonisolated struct ReaderOverrides: Sendable, Equatable {
    var pageIndex: Int?
    var startInMarkup = false
    var startMaximized = false
    var notesTab: ReaderSession.NotesTab?
    /// A heading whose note the notes panel shows on the Section tab (a Notebook heading-note
    /// row); applied with `ReaderSession.showNotes(.section, heading:)`.
    var notesHeading: HeadingAnchor?
}
