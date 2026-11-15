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
    /// Ticked books.
    var selection: Set<UUID> = []
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
        plan?.items.filter { selection.contains($0.id) } ?? []
    }

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
                self.selection = RestorePreviewLogic.initialSelection(session.plan)
                self.stage = .preview
                self.observeLibrary()
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
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Restore asks first when a ticked book replaces one in the Library.
    func requestRestore() {
        guard case .preview = stage, !selection.isEmpty else { return }
        if let confirmation = RestorePreviewLogic.confirmation(selected: selectedItems) {
            self.confirmation = confirmation
        } else {
            restore()
        }
    }

    func restore() {
        confirmation = nil
        guard case .preview = stage, let session, restoreTask == nil else { return }
        let ids = Set(selectedItems.map(\.id))
        guard !ids.isEmpty else { return }
        let restorePDFs = offersRestorePDFs ? self.restorePDFs : true
        let service = service
        stage = .restoring
        restoreTask = Task { [weak self] in
            let outcome: Result<RestoreSummary, any Error>
            do {
                outcome = .success(try await service.restore(ids, from: session, restorePDFs: restorePDFs))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.restoreTask = nil
            switch outcome {
            case .success(let summary):
                self.stage = .finished(summary)
            case .failure(let error):
                if let failure = BackupFailure.from(error, title: "Couldn’t Restore") {
                    self.stage = .failed(failure)
                } else {
                    // Cancelled before anything was committed: back to the preview.
                    self.stage = .preview
                    await service.refreshPlan(of: session)
                    self.plan = session.plan
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
            self.selection.formIntersection(Set(session.plan.items.map(\.id)))
        }
    }

    // MARK: Dismissal

    /// The sheet went away. The session is closed now, or when a running restore finishes.
    func dismissed() {
        isDismissed = true
        refreshTask?.cancel()
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
