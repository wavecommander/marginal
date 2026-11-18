import Foundation
import Observation
import os
import ReaderCore

/// Downloads the PDFs of synced books (owner decision 5): automatically after a round when the
/// policy and the network allow, one at a time; and at once when the reader opens or taps such a
/// book. One per app (`SyncController`); every window's Library and reader read its state.
///
/// - A **synced book without its PDF** is one the signed-in account's engine holds a base for
///   (so the account has its PDF) and whose PDF is not on this device. Only while the Sync
///   switch is on; otherwise such a book is an ordinary book whose PDF is missing (Locate PDF…).
/// - **Automatic**: `considerAutomatic()` queues every such book when `SyncPDFRule` allows
///   (automatic on Wi‑Fi, a path that is neither expensive nor in Low Data Mode), and stops an
///   automatic download whose path turns expensive or constrained (it is queued again).
/// - **Asked for** (`requestNow`): the book goes first; an automatic download of another book
///   in progress is stopped and queued again, so still only one runs at a time. Any network.
/// - **Cancel** stops the book's download and drops it from the queue until it is asked for
///   again or the next automatic pass.
@Observable
@MainActor
final class SyncPDFDownloads {
    enum State: Equatable, Sendable {
        /// Queued.
        case waiting
        case downloading
        /// The last attempt failed (a reader-facing message).
        case failed(String)
    }

    /// Books with a download state (queued, downloading or failed).
    private(set) var states: [UUID: State] = [:]
    /// Synced books whose PDF is not on this device (as of the last refresh).
    private(set) var booksWithoutPDF: Set<UUID> = []
    /// Downloads started (tests).
    @ObservationIgnored private(set) var started: [UUID] = []

    /// Whether sync is on for the signed-in account (the switch).
    @ObservationIgnored var isActive: () -> Bool
    @ObservationIgnored var policy: () -> SyncPDFPolicy
    @ObservationIgnored var path: () -> SyncNetworkPath?
    @ObservationIgnored private let download: (UUID) async throws -> Void
    @ObservationIgnored private let syncedBookIDs: () async -> Set<UUID>
    @ObservationIgnored private let hasPDF: (UUID) async -> Bool

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var current: (bookID: UUID, isAutomatic: Bool, task: Task<Void, Never>)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - download: downloads and installs the book's PDF (`SyncService.downloadPDF`).
    ///   - syncedBookIDs: the books the account's engine holds a base for.
    ///   - hasPDF: whether the book's PDF is on this device (checked off the main thread).
    init(isActive: @escaping () -> Bool, policy: @escaping () -> SyncPDFPolicy, path: @escaping () -> SyncNetworkPath?,
         download: @escaping (UUID) async throws -> Void, syncedBookIDs: @escaping () async -> Set<UUID>,
         hasPDF: @escaping (UUID) async -> Bool) {
        self.isActive = isActive
        self.policy = policy
        self.path = path
        self.download = download
        self.syncedBookIDs = syncedBookIDs
        self.hasPDF = hasPDF
    }

    // MARK: What the Library and the reader show

    /// Whether `bookID` is a synced book without its PDF (sync on): its cell shows a download
    /// state instead of "PDF missing", and opening it downloads first.
    func isSyncedWithoutPDF(_ bookID: UUID) -> Bool {
        isActive() && booksWithoutPDF.contains(bookID)
    }

    /// The Library's badge for `bookID`, or `nil` when it is not a synced book without its PDF.
    func badge(for bookID: UUID) -> SyncPDFBadge? {
        guard isSyncedWithoutPDF(bookID) else { return nil }
        switch states[bookID] {
        case .waiting?: return .waiting
        case .downloading?: return .downloading
        case .failed(let message)?: return .failed(message)
        case nil: return .notDownloaded
        }
    }

    // MARK: Refreshing

    /// Reads the synced books again and which of them lack their PDF; then, when allowed, queues
    /// the automatic downloads. Returns when done.
    func refresh(thenDownload: Bool = true) async {
        guard isActive() else {
            booksWithoutPDF = []
            return
        }
        let synced = await syncedBookIDs()
        var missing = Set<UUID>()
        for id in synced where !(await hasPDF(id)) { missing.insert(id) }
        booksWithoutPDF = missing
        for id in states.keys where !missing.contains(id) && current?.bookID != id { states[id] = nil }
        queue.removeAll { !missing.contains($0) }
        if thenDownload { considerAutomatic() }
    }

    /// `refresh()` without waiting, coalescing calls.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    // MARK: Automatic

    /// Queues every synced book without its PDF when the policy and the path allow; otherwise
    /// stops an automatic download in progress (queued again for later).
    func considerAutomatic() {
        guard isActive(), SyncPDFRule.allowsAutomatic(policy(), path: path()) else {
            if let current, current.isAutomatic {
                current.task.cancel()
                // Waits as queued for when it is allowed again.
            }
            // Queued books that were only waiting for an automatic turn go back to "not downloaded";
            // books the reader asked for stay.
            for id in queue where !requested.contains(id) { states[id] = nil }
            queue.removeAll { !requested.contains($0) }
            return
        }
        for id in booksWithoutPDF.sorted(by: { $0.uuidString < $1.uuidString })
        where current?.bookID != id && !queue.contains(id) && !isFailed(id) {
            queue.append(id)
            states[id] = .waiting
        }
        pump()
    }

    private func isFailed(_ id: UUID) -> Bool {
        if case .failed = states[id] { true } else { false }
    }

    // MARK: Asked for

    /// The reader opened or tapped the book: download it now, before anything else.
    func requestNow(_ bookID: UUID) {
        guard isActive() else { return }
        if let current {
            if current.bookID == bookID, !current.task.isCancelled {
                // Already downloading: it is no longer only an automatic one.
                self.current = (bookID, false, current.task)
                return
            }
            if current.bookID != bookID, current.isAutomatic {
                current.task.cancel()
                queue.insert(current.bookID, at: 0)
            }
        }
        queue.removeAll { $0 == bookID }
        queue.insert(bookID, at: 0)
        states[bookID] = .waiting
        requested.insert(bookID)
        pump()
    }

    /// Books the reader asked for (they run on any network).
    @ObservationIgnored private var requested: Set<UUID> = []

    /// Stops the book's download, if any, and takes it out of the queue.
    func cancel(_ bookID: UUID) {
        queue.removeAll { $0 == bookID }
        requested.remove(bookID)
        if let current, current.bookID == bookID { current.task.cancel() }
        states[bookID] = nil
    }

    /// Stops everything (the switch turned off, a sign-in change).
    func stopAll() {
        queue.removeAll()
        requested.removeAll()
        current?.task.cancel()
        states = [:]
    }

    // MARK: One at a time

    private func pump() {
        guard current == nil else { return }
        while let next = queue.first {
            queue.removeFirst()
            let isAutomatic = !requested.contains(next)
            if isAutomatic, !SyncPDFRule.allowsAutomatic(policy(), path: path()) {
                states[next] = nil
                continue
            }
            start(next, isAutomatic: isAutomatic)
            return
        }
    }

    private func start(_ bookID: UUID, isAutomatic: Bool) {
        states[bookID] = .downloading
        started.append(bookID)
        let download = download
        let task = Task { [weak self] in
            do {
                try await download(bookID)
                self?.finished(bookID, error: nil)
            } catch {
                self?.finished(bookID, error: error)
            }
        }
        current = (bookID, isAutomatic, task)
    }

    private func finished(_ bookID: UUID, error: (any Error)?) {
        let wasCancelled = current?.task.isCancelled == true
        if current?.bookID == bookID { current = nil }
        if let error {
            if wasCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                // Stopped (cancelled, or set aside for a book the reader asked for): leave it as
                // queued if it is still in the queue, else as not downloaded.
                states[bookID] = queue.contains(bookID) ? .waiting : nil
            } else {
                states[bookID] = .failed(SyncService.message(for: error))
                syncLog.error("PDF download failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        } else {
            states[bookID] = nil
            booksWithoutPDF.remove(bookID)
        }
        if !queue.contains(bookID) { requested.remove(bookID) }
        pump()
    }

    /// Whether a download is running (tests).
    var isDownloading: Bool { current != nil }
    /// The book downloading now (tests).
    var currentBookID: UUID? { current?.bookID }
    /// Queued books (tests).
    var queued: [UUID] { queue }
}
