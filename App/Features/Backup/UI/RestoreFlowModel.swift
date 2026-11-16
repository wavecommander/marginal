import Foundation
import Observation
import ReaderBackup
import ReaderCore
import UniformTypeIdentifiers

/// The `.ttbackup` type (exported by the app; `project.yml` declares it).
extension UTType {
    static let tactileTextsBackup = UTType(exportedAs: BackupFormat.typeIdentifier)
}

/// A request to show the restore sheet for one backup.
struct RestoreRequest: Identifiable {
    enum Source {
        /// A `.ttbackup` file. `consume`: it is the app's Inbox copy, deleted when the sheet closes.
        case file(URL, consume: Bool)
        /// A backup at a destination.
        case snapshot(BackupSnapshotInfo, destination: any BackupDestination)
    }

    let id = UUID()
    let source: Source
}

/// One restore sheet: opens the backup, shows the preview, runs the restore and keeps its
/// summary. Closes the `RestoreSession` (and deletes a consumed Inbox copy) once the sheet is
/// gone and no restore is running.
@Observable
@MainActor
final class RestoreFlowModel {
    enum Stage {
        case opening
        case preview
        case restoring
        case finished(RestoreSummary)
        case failed(BackupFailure)
    }

    private(set) var stage: Stage = .opening
    private(set) var plan: RestorePlan?
    /// Ticked books, and Merge or Replace for each book already in the Library.
    private(set) var choices = RestoreChoices()
    /// What merging would do, per backed-up book already in the Library (filled in after the
    /// preview opens).
    private(set) var mergePreviews: [UUID: BookMergePreview] = [:]
    /// `false` while the merge previews are being worked out.
    private(set) var mergePreviewsLoaded = false
    /// After a restore: whether it kept a safety copy, so Undo Last Restore can put things back.
    private(set) var restoreCanBeUndone = false
    var restorePDFs = true
    /// The replace confirmation waiting for an answer.
    var confirmation: RestorePreviewLogic.Confirmation?
    /// Set when the sheet should go away by itself (the reader cancelled opening).
    private(set) var shouldClose = false

    let request: RestoreRequest
    @ObservationIgnored private let service: BackupService
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private(set) var session: RestoreSession?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var mergePreviewTask: Task<Void, Never>?
    @ObservationIgnored private var observation: StoreChangeObservation?
    @ObservationIgnored private var isDismissed = false
    @ObservationIgnored private var isFinishedWithFiles = false

    init(request: RestoreRequest, service: BackupService, store: LibraryStore) {
        self.request = request
        self.service = service
        self.store = store
    }

    var isRestoring: Bool { if case .restoring = stage { true } else { false } }

    /// The ticked items, in plan order.
    var selectedItems: [RestorePlan.Item] {
        plan.map { choices.selectedItems(in: $0) } ?? []
    }

    /// What restoring each ticked book does (books left as they are are not listed).
    var actions: [UUID: RestoreAction] {
        plan.map { choices.actions(in: $0) } ?? [:]
    }

    /// The ticked items with what restoring each does, in plan order.
    var selectedWithActions: [(item: RestorePlan.Item, action: RestoreAction)] {
        selectedItems.compactMap { item in choices.action(for: item).map { (item, $0) } }
    }

    /// The Restore button's title ("Merge 1 Book", "Restore 3 Books").
    var restoreButtonTitle: String {
        RestorePreviewLogic.restoreButtonTitle(actions: selectedWithActions.map(\.action))
    }

    /// Whether any ticked book is set to Merge.
    var anyMerge: Bool { plan.map { choices.anyMerge(in: $0) } ?? false }

    var offersRestorePDFs: Bool { plan.map(RestorePreviewLogic.offersRestorePDFs) ?? false }

    /// Where the backup came from, for the header.
    var sourceLine: String {
        switch request.source {
        case .file(let url, _): "File: \(url.lastPathComponent)"
        case .snapshot(_, let destination): "From \(destination.displayName)"
        }
    }

    // MARK: Opening

    func start() {
        guard openTask == nil, session == nil else { return }
        let service = service
        let source = request.source
        openTask = Task { [weak self] in
            do {
                let session: RestoreSession
                switch source {
                case .file(let url, _): session = try await service.openBackup(at: url)
                case .snapshot(let snapshot, let destination): session = try await service.openBackup(snapshot, from: destination)
                }
                guard let self, !self.isDismissed else {
                    session.close()
                    self?.finishWithFiles()
                    return
                }
                self.session = session
                self.plan = session.plan
                self.choices = RestoreChoices(plan: session.plan)
                self.stage = .preview
                self.observeLibrary()
                self.loadMergePreviews()
            } catch {
                guard let self else { return }
                if let failure = BackupFailure.from(error, title: "Can’t Open Backup") {
                    self.stage = .failed(failure)
                } else {
                    self.shouldClose = true
                }
                if self.isDismissed { self.finishWithFiles() }
            }
            self?.openTask = nil
        }
    }

    // MARK: Preview

    func toggle(_ id: UUID) {
        guard case .preview = stage else { return }
        choices.toggle(id)
    }

    /// The menu of a book already in the Library.
    func choose(_ choice: RestoreRowChoice, for id: UUID) {
        guard case .preview = stage else { return }
        choices.choose(choice, for: id)
    }

    /// Works out what merging each book already in the Library would do, without blocking the
    /// preview (rows show "Working out…" until it is done).
    private func loadMergePreviews() {
        guard let session else { return }
        mergePreviewTask?.cancel()
        mergePreviewsLoaded = false
        let service = service
        mergePreviewTask = Task { [weak self] in
            let previews = await service.mergePreview(for: session)
            guard !Task.isCancelled, let self else { return }
            self.mergePreviews = previews
            self.mergePreviewsLoaded = true
        }
    }

    /// Restore asks first when a ticked book is set to Replace with Backup.
    func requestRestore() {
        guard case .preview = stage, !actions.isEmpty else { return }
        if let confirmation = RestorePreviewLogic.confirmation(selected: selectedWithActions) {
            self.confirmation = confirmation
        } else {
            restore()
        }
    }

    func restore() {
        confirmation = nil
        guard case .preview = stage, let session, restoreTask == nil else { return }
        let actions = actions
        guard !actions.isEmpty else { return }
        let restorePDFs = offersRestorePDFs ? self.restorePDFs : true
        let service = service
        mergePreviewTask?.cancel()
        stage = .restoring
        restoreTask = Task { [weak self] in
            let started = Date()
            let outcome: Result<RestoreSummary, any Error>
            do {
                outcome = .success(try await service.restore(actions, from: session, restorePDFs: restorePDFs))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.restoreTask = nil
            switch outcome {
            case .success(let summary):
                // The safety copy this restore kept, if any (one that changed or added nothing
                // is not listed).
                self.restoreCanBeUndone = service.latestRestoreSafetyRecord().map { $0.createdAt >= started } ?? false
                self.stage = .finished(summary)
            case .failure(let error):
                if let failure = BackupFailure.from(error, title: "Couldn’t Restore") {
                    self.stage = .failed(failure)
                } else {
                    // Cancelled before anything was committed: back to the preview.
                    self.stage = .preview
                    await service.refreshPlan(of: session)
                    self.plan = session.plan
                    self.choices.reconcile(with: session.plan)
                    self.loadMergePreviews()
                }
            }
            if self.isDismissed { self.finishWithFiles() }
        }
    }

    /// Cancel while opening: stops the job (the sheet then closes).
    func cancelOpening() {
        if let job = service.job, job.kind == .openBackup { job.cancel() } else { shouldClose = true }
    }

    // MARK: Library changes

    /// Rebuilds the preview when the Library changes under it (another window imports or
    /// deletes a book), so New / Already in Library stay true.
    private func observeLibrary() {
        observation = store.hub.observe { [weak self] event in
            switch event.change {
            case .bookSaved, .bookDeleted: self?.schedulePlanRefresh()
            default: break
            }
        }
    }

    private func schedulePlanRefresh() {
        guard case .preview = stage, let session else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, service] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, case .preview = self.stage else { return }
            await service.refreshPlan(of: session)
            guard case .preview = self.stage else { return }
            self.plan = session.plan
            self.choices.reconcile(with: session.plan)
            self.loadMergePreviews()
        }
    }

    // MARK: Dismissal

    /// The sheet went away. The session is closed now, or when a running restore finishes.
    func dismissed() {
        isDismissed = true
        refreshTask?.cancel()
        mergePreviewTask?.cancel()
        if openTask != nil {
            openTask?.cancel()
            return  // the open task finishes the files
        }
        if restoreTask == nil { finishWithFiles() }
    }

    private func finishWithFiles() {
        guard !isFinishedWithFiles else { return }
        isFinishedWithFiles = true
        observation = nil
        session?.close()
        session = nil
        if case .file(let url, true) = request.source {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
