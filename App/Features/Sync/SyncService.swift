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

    @ObservationIgnored private var engine: (accountID: String, key: BackupEncryptionKey, engine: SyncEngine)?
    @ObservationIgnored private var roundTask: Task<Void, Never>?

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
        roundTask = nil
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
        let (engine, _) = try await readyEngine()
        return try await engine.joinPreview()
    }

    /// Downloads the book's PDF from the account and puts it in place (the download policy and
    /// the moment are C4b's). Not while a backup or restore runs.
    func downloadPDF(bookID: UUID) async throws {
        await waitUntilReady()
        if backupService?.job != nil { throw BackupServiceError.busy }
        let (engine, _) = try await readyEngine()
        try await engine.downloadPDF(bookID: bookID)
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
        await waitUntilReady()
        if backupService?.job != nil {
            status = .waiting(.backupOrRestore)
            return
        }
        status = .syncing
        do {
            let (engine, mode) = try await readyEngine()
            try Task.checkCancellation()
            if backupService?.job != nil {
                status = .waiting(.backupOrRestore)
                return
            }
            let report = try await engine.sync(mode: mode, joinConfirmed: joinConfirmed)
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
        } catch is CancellationError {
            if case .syncing = status { status = .idle }
        } catch SyncEngineError.joinConfirmationRequired {
            status = .needsJoinConfirmation
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

    /// The engine for the signed-in account and its key, made (or reused) after the key check.
    private func readyEngine() async throws -> (SyncEngine, SyncMode) {
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
                return (engine.engine, account.mode)
            }
            let directory = try accountDirectory(account.accountID)
            let store = EncryptedSyncStore(store: account.store, key: account.key,
                                           temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true))
            let made = SyncEngine(store: store, library: LibrarySyncSource(core: library), inkMerger: inkMerger,
                                  directory: directory, device: try device(), now: now)
            engine = (account.accountID, account.key, made)
            return (made, account.mode)
        }
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

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Tactile Texts Cloud to sync."
        case .needsKey: "Enter your recovery key on the Tactile Texts Cloud page to sync."
        case .nothingToSync: "There’s nothing to sync yet."
        }
    }
}
