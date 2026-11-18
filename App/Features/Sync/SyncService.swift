import Foundation
import Observation
import OSLog
import ReaderBackup
import ReaderCore
import ReaderSync
import S3Kit
import UIKit

let syncLog = Logger(subsystem: "software.tactile.texts", category: "Sync")

/// Why sync waits.
nonisolated enum SyncWaitReason: Hashable, Sendable {
    /// Nobody is signed in to Tactile Texts Cloud.
    case signedOut
    /// A backup or restore is running (one job at a time).
    case backupOrRestore
    /// The network or the service cannot be reached now.
    case offline
    /// The session is read-only or over the allowance: changes here wait (`SyncMode.pullOnly`).
    case pullOnly
    /// The reader is working on something the round left for later.
    case editInProgress
    /// A book was synced by a newer version of the app, which must be updated to send changes.
    case needsNewerApp
    /// The account holds data in a newer format than this app reads: sync stops for the account
    /// until the app is updated, and nothing changed (`SyncEngineError.formatTooNew`).
    case accountNeedsNewerApp
}

/// Where sync stands, for the status line (C4b).
nonisolated enum SyncStatus: Hashable, Sendable {
    /// Not started, or no account to sync with.
    case idle
    case syncing
    /// Everything agreed with the account when the last round ended.
    case upToDate(Date)
    case waiting(SyncWaitReason)
    /// This device has never synced with the account: show `joinPreview()` and confirm with
    /// `confirmJoin()`.
    case needsJoinConfirmation
    /// The recovery key is needed here (`CloudBackupKeyNeed`), on the Tactile Texts Cloud page.
    case needsKey(CloudBackupKeyNeed)
    /// The last round failed (a reader-facing message, never key material or note text).
    case failed(String)
}

/// Sync with Tactile Texts Cloud (`docs/CLOUD_SYNC_PLAN.md` "Sync"): the object the Sync switch,
/// status line, join sheet and scheduler (C4b) drive. One per app; it keeps one engine per
/// signed-in account, in `Application Support/Sync/<account>/` (outside `Books/`, so backups,
/// restores and older versions never see it; excluded from the device's own backup, so a device
/// restored from one joins afresh rather than trusting another device's bases).
///
/// - `syncNow(joinConfirmed:)` runs one round (or waits for the one running). It waits for launch
///   work (interrupted restores finished, duplicate books merged), refuses to run while a backup
///   or restore runs, checks the key before anything, and picks `.pullOnly` for a read-only or
///   over-allowance session.
/// - A backup or restore starting cancels the round in progress and waits for it to stop
///   (`stopForBackupJob`); the engine is safe to cut off anywhere.
/// - Signing out, or in to another account, stops the round; each account's directory is kept,
///   so signing back in carries on without a join, and another account joins on its own.
@Observable
@MainActor
final class SyncService {
    private(set) var status: SyncStatus = .idle
    /// The last round's report (books changed, skipped, failed).
    private(set) var lastReport: SyncReport?
    /// When a round last ended with everything agreed.
    private(set) var lastSyncedAt: Date?
    /// How many rounds this service has started (each `syncNow` that ran one), for the
    /// scheduler's tests and the UI tests' debug readout.
    private(set) var roundsStarted = 0

    @ObservationIgnored let library: LibrarySyncCore
    @ObservationIgnored let access: any SyncAccountProvider
    /// `Application Support/Sync`.
    @ObservationIgnored let root: URL
    @ObservationIgnored let inkMerger: any SyncInkMerger
    /// The one-job-at-a-time rule: sync does not run while it has a job.
    @ObservationIgnored weak var backupService: BackupService?
    /// Launch work (`AppEnvironment.launchPlan()`); rounds wait for it.
    @ObservationIgnored var waitUntilReady: @MainActor () async -> Void = {}
    @ObservationIgnored let deviceName: () -> String
    @ObservationIgnored let now: @Sendable () -> Date

    @ObservationIgnored private var engine: (accountID: String, key: BackupEncryptionKey, engine: SyncEngine,
                                             snapshots: (any SyncSnapshotReferences)?)?
    @ObservationIgnored private var roundTask: Task<Void, Never>?
    /// The last housekeeping run's report (tests, diagnostics).
    @ObservationIgnored private(set) var lastHousekeeping: SyncHousekeepingReport?
    /// Housekeeping's limits (tests make them small).
    @ObservationIgnored var housekeepingLimits = SyncHousekeepingLimits()

    init(library: LibrarySyncCore, access: any SyncAccountProvider, root: URL, inkMerger: any SyncInkMerger = AppSyncInkMerger(),
         deviceName: @escaping () -> String = { UIDevice.current.name }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.access = access
        self.root = root
        self.inkMerger = inkMerger
        self.deviceName = deviceName
        self.now = now
    }

    /// `Application Support/Sync` under the store's root.
    static func defaultRoot(storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent("Sync", isDirectory: true)
    }

    // MARK: Rounds

    /// Runs one round now, or waits for the one already running. `joinConfirmed`: the reader
    /// confirmed the join this device's first round needs (`status == .needsJoinConfirmation`).
    func syncNow(joinConfirmed: Bool = false) async {
        if let roundTask { return await roundTask.value }
        let task = Task { @MainActor in await self.round(joinConfirmed: joinConfirmed) }
        roundTask = task
        await task.value
        if roundTask == task { roundTask = nil }
    }

    /// Runs `body` with the engine to itself: the round in progress is stopped first (it is safe
    /// to cut off anywhere), and rounds asked for meanwhile wait for it. Not while a backup or
    /// restore runs. `body` gets the engine and the round's mode.
    private func exclusively<T: Sendable>(_ body: @escaping @MainActor (SyncEngine, SyncMode) async throws -> T) async throws -> T {
        await waitUntilReady()
        if backupService?.job != nil { throw BackupServiceError.busy }
        if let running = roundTask {
            running.cancel()
            await running.value
            if roundTask == running { roundTask = nil }
        }
        let work = Task { @MainActor () -> Result<T, any Error> in
            do {
                let ready = try await self.readyEngine()
                return .success(try await body(ready.engine, ready.mode))
            } catch {
                return .failure(error)
            }
        }
        let holder = Task { @MainActor in _ = await work.value }
        roundTask = holder
        let result = await work.value
        if roundTask == holder { roundTask = nil }
        return try result.get()
    }

    /// The reader confirmed the join: runs the round that joins.
    func confirmJoin() async {
        await syncNow(joinConfirmed: true)
    }

    /// What a join would do (books only here, only in the account, on both), for the join
    /// sheet. Throws the account's errors; `SyncServiceError.notReady` when there is no account
    /// to join or no key.
    func joinPreview() async throws -> SyncJoinPreview {
        await waitUntilReady()
        return try await readyEngine().engine.joinPreview()
    }

    /// Downloads the book's PDF from the account and puts it in place (the download policy and
    /// the moment are C4b's). Not while a backup or restore runs.
    func downloadPDF(bookID: UUID) async throws {
        await waitUntilReady()
        if backupService?.job != nil { throw BackupServiceError.busy }
        try await readyEngine().engine.downloadPDF(bookID: bookID)
    }

    // MARK: Recently Deleted and earlier versions (C5)

    /// The account's deleted books that can still be restored, newest deletion first.
    func recentlyDeleted() async throws -> [SyncDeletedBook] {
        await waitUntilReady()
        return try await readyEngine().engine.recentlyDeleted()
    }

    /// This device's sync identity (to say "this iPad" for a book deleted here).
    func deviceID() -> UUID? { try? device().id }

    /// Restores a deleted book: it comes back on this device at once, and on the others with
    /// their next round. Throws `SyncRestoreError` (nothing changed), the account's errors.
    func restoreDeleted(bookKey: String) async throws {
        let report = try await exclusively { engine, mode in try await engine.restoreDeleted(bookKey: bookKey, mode: mode) }
        if let failure = report?.failure {
            // The head is live again; making it here failed and the next round tries again.
            syncLog.error("restored book \(bookKey.prefix(8)) not made here yet: \(failure.description)")
        }
    }

    /// The sync key of a book on this device, `nil` when its PDF is not known by its hash.
    func bookKey(bookID: UUID) async throws -> String? {
        await waitUntilReady()
        guard let book = try library.store.books.book(id: bookID),
              let digest = try? await library.store.contentDigest(of: book) else { return nil }
        let engine = try await readyEngine().engine
        return try await engine.store.bookKey(pdfSHA256: digest.sha256)
    }

    /// What the book on this device holds now, in counts (for the Earlier Versions confirmation).
    func currentSummary(bookID: UUID) async -> SyncContentSummary? {
        guard let snapshot = try? await library.snapshot(bookID: bookID) else { return nil }
        let pages = snapshot.files.keys.filter { if case .pageInk = $0 { true } else { false } }.count
        return SyncContentSummary(archive: snapshot.archive, inkedPages: pages)
    }

    /// The earlier versions of a book on this device that the account keeps, newest first.
    func versions(bookID: UUID) async throws -> [SyncBookVersion] {
        guard let key = try await bookKey(bookID: bookID) else { throw SyncRestoreError.bookNotOnThisDevice }
        return try await readyEngine().engine.versions(bookKey: key)
    }

    /// Makes an earlier version's content the book's content again (`SyncEngine.restoreVersion`),
    /// after taking a restore safety copy of the book as it is, so Undo Last Restore on the Backup
    /// screen puts it back. Never while the reader is working in the book, a backup or restore
    /// runs, or a round runs (it is stopped first). Open windows on the book reload what they
    /// show, as for a change from another window. A round then carries it to the other devices.
    /// Returns what changed (`nil`: the version is the book as it is now).
    @discardableResult
    func restoreEarlierVersion(bookID: UUID, version: Int, versionDate: Date) async throws -> SyncVersionRestorePlan? {
        guard let backupService else { throw SyncServiceError.notReady }
        guard let key = try await bookKey(bookID: bookID) else { throw SyncRestoreError.bookNotOnThisDevice }
        let copyBox = SafetyCopyBox()
        let title = (try? library.store.books.book(id: bookID))?.title ?? ""
        let sourceName = String(localized: "Earlier version of “\(title)” from \(versionDate.formatted(date: .abbreviated, time: .shortened))",
                                comment: "Undo Last Restore: what an earlier-version restore restored. Arguments: the book's title, a date and time.")
        do {
            let plan = try await exclusively { engine, _ in
                try await engine.restoreVersion(bookKey: key, version: version) { plan in
                    try await self.takeSafetyCopy(of: plan.bookID, sourceName: sourceName, backupService: backupService,
                                                  into: copyBox)
                }
            }
            copyBox.copy?.finish()
            if plan != nil { Task { await self.syncNow() } }
            return plan
        } catch {
            if let copy = copyBox.copy, let book = try? library.store.books.book(id: bookID) {
                copy.commitFailed(book, replacing: [bookID])
                copy.finish()
            }
            throw error
        }
    }

    /// The safety copy of the book an earlier-version restore is about to change (the engine
    /// calls this just before it writes), recorded as changed by it, as a restore's is.
    private func takeSafetyCopy(of bookID: UUID, sourceName: String, backupService: BackupService,
                                into box: SafetyCopyBox) async throws {
        let copy = try await backupService.makeSafetyCopy(protecting: [bookID], sourceName: sourceName)
        box.copy = copy
        if let book = try library.store.books.book(id: bookID) { copy.willCommit(book, replacing: [bookID]) }
    }

    /// Holds the safety copy made inside the engine's call.
    @MainActor
    private final class SafetyCopyBox {
        var copy: RestoreSafetyCopy?
    }

    /// Stops the round in progress, if any, and waits for it to stop. A round is safe to cut off
    /// anywhere (`SyncEngine`).
    func stop() async {
        guard let roundTask else { return }
        roundTask.cancel()
        await roundTask.value
    }

    /// A backup or restore is about to start (`BackupService.beforeJob`).
    func stopForBackupJob() async {
        await stop()
        status = .waiting(.backupOrRestore)
    }

    /// The sign-in changed (signed out, or in to another account): stop, and forget the engine;
    /// the next round builds the account's own (its directory, and so its bases, are kept).
    func signInChanged() {
        roundTask?.cancel()
        engine = nil
        status = .idle
        lastReport = nil
    }

    private func round(joinConfirmed: Bool) async {
        roundsStarted += 1
        await waitUntilReady()
        if backupService?.job != nil {
            status = .waiting(.backupOrRestore)
            return
        }
        status = .syncing
        do {
            let ready = try await readyEngine()
            try Task.checkCancellation()
            if backupService?.job != nil {
                status = .waiting(.backupOrRestore)
                return
            }
            let report = try await ready.engine.sync(mode: ready.mode, joinConfirmed: joinConfirmed)
            lastReport = report
            status = Self.status(after: report, at: now())
            if case .upToDate(let date) = status { lastSyncedAt = date }
            for book in report.books {
                if let failure = book.failure { syncLog.error("book \(book.bookKey.prefix(8)) failed: \(failure.description)") }
                if book.skipped.contains(where: { if case .duplicatePDF = $0 { true } else { false } }) {
                    // Unreachable in normal use (one book per PDF); left for the launch merge.
                    syncLog.error("book \(book.bookKey.prefix(8)): two books with one PDF")
                }
            }
            // Housekeeping after a full round that ran to the end, at most once a day here.
            if ready.mode == .full { await housekeepIfDue(ready) }
        } catch is CancellationError {
            if case .syncing = status { status = .idle }
        } catch SyncEngineError.joinConfirmationRequired {
            status = .needsJoinConfirmation
        } catch SyncEngineError.formatTooNew {
            // A newer app wrote the account's format: nothing changed; the app must be updated.
            status = .waiting(.accountNeedsNewerApp)
        } catch SyncEngineError.roundInProgress {
            // Another caller's round (a download, say) holds the engine; this one ends quietly.
            status = .idle
        } catch SyncServiceError.signedOut {
            status = .waiting(.signedOut)
        } catch SyncServiceError.needsKey(let need) {
            status = .needsKey(need)
        } catch SyncServiceError.nothingToSync {
            lastSyncedAt = now()
            status = .upToDate(lastSyncedAt!)
        } catch {
            status = Self.isOffline(error) ? .waiting(.offline) : .failed(Self.message(for: error))
            syncLog.error("round failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// The engine for the signed-in account, the round's mode and the account's snapshots.
    private struct Ready {
        var accountID: String
        var engine: SyncEngine
        var mode: SyncMode
        var snapshots: (any SyncSnapshotReferences)?
    }

    /// The engine for the signed-in account and its key, made (or reused) after the key check.
    private func readyEngine() async throws -> Ready {
        switch try await access.prepareRound() {
        case .signedOut:
            engine = nil
            throw SyncServiceError.signedOut
        case .needsKey(_, let need):
            throw SyncServiceError.needsKey(need)
        case .nothingToSync:
            throw SyncServiceError.nothingToSync
        case .ready(let account):
            if let engine, engine.accountID == account.accountID, engine.key == account.key {
                return Ready(accountID: account.accountID, engine: engine.engine, mode: account.mode, snapshots: engine.snapshots)
            }
            let directory = try accountDirectory(account.accountID)
            let temporary = root.appendingPathComponent("tmp", isDirectory: true)
            let store = EncryptedSyncStore(store: account.store, key: account.key, temporaryDirectory: temporary)
            let made = SyncEngine(store: store, library: LibrarySyncSource(core: library), inkMerger: inkMerger,
                                  directory: directory, device: try device(), now: now)
            let snapshots = account.backupStore.map { backupStore in
                SyncSnapshotPDFReferences(destination: EncryptedBackupDestination(id: "sync-housekeeping", displayName: "",
                                                                                  store: backupStore, key: account.key,
                                                                                  temporaryDirectory: temporary),
                                          cacheDirectory: directory.appendingPathComponent("snapshots", isDirectory: true))
            }
            engine = (account.accountID, account.key, made, snapshots)
            return Ready(accountID: account.accountID, engine: made, mode: account.mode, snapshots: snapshots)
        }
    }

    // MARK: Housekeeping

    /// `Sync/<account>/housekeeping/last-run`: when housekeeping last ran to the end on this device.
    private func lastHousekeepingFile(_ accountID: String) throws -> URL {
        try accountDirectory(accountID).appendingPathComponent("housekeeping", isDirectory: true)
            .appendingPathComponent("last-run", isDirectory: false)
    }

    /// When housekeeping last ran here for the account (its own clock), or `nil`.
    func lastHousekeepingDate(accountID: String) -> Date? {
        guard let url = try? lastHousekeepingFile(accountID), let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Runs housekeeping (`SyncEngine.housekeep`) when it has not run here for a day, inside the
    /// round's task (so it is cancelled with it). Its failure is logged and changes nothing the
    /// reader sees; it runs again after the next round.
    private func housekeepIfDue(_ ready: Ready) async {
        let current = now()
        if let last = lastHousekeepingDate(accountID: ready.accountID), current.timeIntervalSince(last) >= 0,
           current.timeIntervalSince(last) < SyncHousekeeping.interval {
            return
        }
        do {
            let report = try await ready.engine.housekeep(limits: housekeepingLimits, snapshots: ready.snapshots)
            lastHousekeeping = report
            let url = try lastHousekeepingFile(ready.accountID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(current.timeIntervalSinceReferenceDate)\n".utf8).write(to: url, options: .atomic)
            syncLog.notice("housekeeping: \(String(describing: report.outcome), privacy: .public); removed \(report.removedHistory) history, \(report.removedBlobs) blobs, \(report.removedPDFs) PDFs; \(report.tombstoned) tombstones; \(report.repairedBlobs) repaired")
        } catch is CancellationError {
            return
        } catch {
            syncLog.error("housekeeping failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: Synced books

    /// The books on this device the signed-in account's engine has agreed with at least once
    /// (it holds a base for them): their PDFs are in the account, so one that is missing here
    /// can be downloaded. Empty when signed out. Read from the engine's directory (`bases/`, as
    /// `SyncEngine` lays it out), so it holds across launches.
    func syncedBookIDs() async -> Set<UUID> {
        guard let accountID = await access.currentAccountID(),
              let directory = try? accountDirectory(accountID) else { return [] }
        let bases = SyncBaseStore(root: directory.appendingPathComponent("bases", isDirectory: true))
        return Set((try? bases.bookIDs()) ?? [])
    }

    // MARK: Status

    static func status(after report: SyncReport, at date: Date) -> SyncStatus {
        if let failure = report.failures.first?.failure { return .failed(failure.description) }
        let skipped = report.books.flatMap(\.skipped)
        if skipped.contains(where: { if case .readOnly = $0 { true } else { false } }) { return .waiting(.needsNewerApp) }
        if skipped.contains(.pullOnly) { return .waiting(.pullOnly) }
        if skipped.contains(where: { if case .busy = $0 { true } else { false } }) { return .waiting(.editInProgress) }
        return .upToDate(date)
    }

    static func isOffline(_ error: any Error) -> Bool {
        if let s3 = error as? S3Error, case .noNetwork = s3 { return true }
        if let url = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .dataNotAllowed, .internationalRoamingOff].contains(url.code)
        }
        return false
    }

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Sync couldn’t finish. It will try again."
    }

    // MARK: Directories

    /// `Sync/<account>/`: the account's engine directory. An account ID that is not a plain
    /// token is named by its hash.
    func accountDirectory(_ accountID: String) throws -> URL {
        try prepareRoot()
        let plain = !accountID.isEmpty && accountID.count <= 64
            && accountID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && !accountID.hasPrefix(".") && accountID != "tmp"
        let name = plain ? accountID : "account-" + ContentHash.sha256(of: Data(accountID.utf8)).prefix(32)
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func prepareRoot() throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// This device as heads name it: an ID made once and kept in `Sync/device.json`.
    private func device() throws -> SyncEngine.Device {
        try prepareRoot()
        let file = root.appendingPathComponent("device.json")
        struct Stored: Codable { var id: UUID }
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return SyncEngine.Device(id: stored.id, name: deviceName())
        }
        let made = Stored(id: UUID())
        try JSONEncoder().encode(made).write(to: file, options: .atomic)
        return SyncEngine.Device(id: made.id, name: deviceName())
    }
}

/// Why the sync service did not run a round (mapped to `SyncStatus`).
nonisolated enum SyncServiceError: Error, Hashable, Sendable, LocalizedError {
    case signedOut
    case needsKey(CloudBackupKeyNeed)
    case nothingToSync
    /// The app's backup service is not set up (a build or test without it).
    case notReady

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Tactile Texts Cloud to sync."
        case .needsKey: "Enter your recovery key on the Tactile Texts Cloud page to sync."
        case .nothingToSync: "There’s nothing to sync yet."
        case .notReady: "Sync isn’t ready yet. Try again in a moment."
        }
    }
}
