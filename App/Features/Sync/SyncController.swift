import Foundation
import Observation
import ReaderCore
import ReaderStore
import ReaderSync

/// Sync as the reader meets it (C4b): the Sync switch and its preferences, the scheduler that
/// decides when rounds run, the PDF downloads, and the join. One per app, on `AppEnvironment`
/// (`nil` when the build has no sync service); every window reads the same one, so the switch,
/// the status line, the Library's states and a download in progress are the same in each.
@Observable
@MainActor
final class SyncController {
    @ObservationIgnored let service: SyncService
    let settings: SyncSettings
    @ObservationIgnored let scheduler: SyncScheduler
    let pdfs: SyncPDFDownloads
    @ObservationIgnored let network: any SyncNetworkMonitoring

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var observation: StoreChangeObservation?

    init(service: SyncService, settings: SyncSettings = SyncSettings(), store: LibraryStore, backupService: BackupService,
         network: any SyncNetworkMonitoring = SystemSyncNetworkMonitor(),
         lifecycle: any BackupAppLifecycle = SystemBackupAppLifecycle()) {
        self.service = service
        self.settings = settings
        self.store = store
        self.network = network
        scheduler = SyncScheduler(runner: service, settings: settings, hub: store.hub, syncOrigin: service.library.origin,
                                  isBackupRunning: { [weak backupService] in backupService?.isBusy ?? false },
                                  lifecycle: lifecycle)
        pdfs = SyncPDFDownloads(isActive: { [weak settings] in settings?.isEnabled ?? false },
                                policy: { [weak settings] in settings?.pdfPolicy ?? .automaticOnWiFi },
                                path: { [weak network] in network?.path },
                                download: { [weak service] id in
                                    guard let service else { throw CancellationError() }
                                    try await service.downloadPDF(bookID: id)
                                },
                                syncedBookIDs: { [weak service] in await service?.syncedBookIDs() ?? [] },
                                hasPDF: { [store] id in await Self.hasDocument(id, store: store) })
        scheduler.afterRound = { [weak self] status, trigger in self?.roundEnded(status, trigger: trigger) }
        network.onChange = { [weak self] path in self?.networkChanged(path) }
        observation = store.hub.observe { [weak self] event in self?.noteChange(event) }
    }

    /// Whether sync is on for the signed-in account (the switch).
    var isOn: Bool { settings.isEnabled }

    /// Each book that is not yet up to date after the last round (sync on).
    var bookStates: [UUID: SyncBookState] {
        isOn ? SyncBookState.all(service.lastReport) : [:]
    }

    func bookState(_ bookID: UUID) -> SyncBookState? {
        isOn ? SyncBookState.make(service.lastReport, bookID: bookID) : nil
    }

    // MARK: Starting and the sign-in

    /// Reads who is signed in, and the synced books without their PDFs.
    func start() async {
        settings.setAccount(await service.access.currentAccountID())
        await pdfs.refresh(thenDownload: false)
    }

    /// The sign-in changed (`SyncService.signInChanged()` has stopped the round): the switch of
    /// the account now signed in, if any (another account starts off; signing back in to this
    /// one resumes with the switch as it was).
    func signInChanged() {
        pdfs.stopAll()
        Task {
            settings.setAccount(await service.access.currentAccountID())
            await pdfs.refresh(thenDownload: false)
            if settings.isEnabled { await scheduler.run(.appActivated) }
        }
    }

    // MARK: The switch and the join

    /// What turning the switch on found.
    enum TurnOnResult: Equatable {
        /// Syncing (or waiting, as the status line says).
        case started
        /// This device and the account both have books: ask first (`SyncJoinLogic`).
        case needsJoinConfirmation(SyncJoinPreview)
    }

    /// Turns the switch on and runs the first round. When this device has never synced with the
    /// account and both sides have books, nothing is changed and the join preview comes back for
    /// the sheet; when only one side has books, the join runs at once (nothing can be surprised).
    func turnOn() async -> TurnOnResult {
        settings.isEnabled = true
        await scheduler.run(.switchedOn)
        guard service.status == .needsJoinConfirmation else { return .started }
        return await joinOrPreview()
    }

    /// The join preview when a sheet is needed; else confirms the join at once.
    func joinOrPreview() async -> TurnOnResult {
        do {
            let preview = try await service.joinPreview()
            if SyncJoinLogic.needsSheet(preview) { return .needsJoinConfirmation(preview) }
            await confirmJoin()
        } catch {
            // The status line says what is wrong; the join waits ("Review…").
            syncLog.error("join preview failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return .started
    }

    /// The reader confirmed the join (or none was needed).
    func confirmJoin() async {
        for _ in 0..<2 {
            await service.confirmJoin()
            // A round already running when this was asked for ends first; ask again.
            if service.status != .needsJoinConfirmation { break }
        }
        roundEnded(service.status, trigger: .switchedOn)
    }

    /// Turns the switch off: the round in progress stops, downloads stop, no more rounds run.
    func turnOff() async {
        settings.isEnabled = false
        pdfs.stopAll()
        await scheduler.stop()
    }

    /// Sync Now, or Try Again: a round now, through any back-off.
    func syncNow() async {
        await scheduler.run(.manual)
    }

    // MARK: After a round, a change, the network

    private func roundEnded(_ status: SyncStatus, trigger: SyncTrigger) {
        // Downloads only while the app is in front, not in a background run's short time.
        let download = scheduler.isInForeground && trigger != .wentToBackground && trigger != .backgroundTask
        Task { await pdfs.refresh(thenDownload: download) }
    }

    /// A book was made, deleted or got its PDF (from any window, a restore or sync): the list of
    /// synced books without their PDFs is read again.
    private func noteChange(_ event: StoreChangeEvent) {
        switch event.change {
        case .bookSaved, .bookDeleted:
            if isOn { pdfs.scheduleRefresh() }
        default:
            break
        }
    }

    private func networkChanged(_ path: SyncNetworkPath) {
        pdfs.considerAutomatic()
        if path.isSatisfied { scheduler.networkBecameAvailable() }
    }

    /// The Download PDFs choice changed.
    func pdfPolicyChanged() {
        pdfs.considerAutomatic()
    }

    @concurrent
    nonisolated private static func hasDocument(_ bookID: UUID, store: LibraryStore) async -> Bool {
        guard let book = await MainActor.run(body: { try? store.books.book(id: bookID) }) else { return true }
        return store.hasDocument(book)
    }
}
