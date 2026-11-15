import Foundation
import Observation
import ReaderBackup

/// Failures of Tactile Texts Cloud that are neither the service's (`CloudServiceError`) nor the
/// storage's (`CloudBackupError`). Reader-facing.
nonisolated enum TactileCloudError: LocalizedError, Hashable, Sendable {
    /// This build has no backup service configured.
    case notInThisBuild
    /// The subscription has ended: backups can be restored until `readOnlyUntil`, not made.
    case readOnly(readOnlyUntil: Date?, deleteAfter: Date?)
    /// Over the plan's storage allowance: backups can be restored and deleted, not made.
    case overAllowance(usedBytes: Int64?, allowanceBytes: Int64?)
    /// The backups need the recovery key on this device.
    case needsRecoveryKey(CloudBackupKeyNeed)
    /// The recovery key entered is valid but is not the key the backups were made with.
    case recoveryKeyDoesNotMatch
    /// Deleting everything did not finish after many rounds.
    case deletionUnfinished

    static let serviceName = CloudServiceError.serviceName

    var errorDescription: String? {
        let name = Self.serviceName
        switch self {
        case .notInThisBuild:
            return "\(name) isn’t available in this version of Tactile Texts."
        case .readOnly(let until, _):
            if let until {
                return "Your \(name) subscription has ended, so new backups can’t be made. You can restore from your backups until \(CloudServiceError.day(until)). Resubscribe to back up again."
            }
            return "Your \(name) subscription has ended, so new backups can’t be made. You can still restore from your backups for now. Resubscribe to back up again."
        case .overAllowance(let used, let allowance):
            if let used, let allowance {
                return "Your backups in \(name) use \(Self.bytes(used)) of your plan’s \(Self.bytes(allowance)), so new backups can’t be made. Delete some backups to make room."
            }
            return "Your backups in \(name) are over your plan’s storage allowance, so new backups can’t be made. Delete some backups to make room."
        case .needsRecoveryKey(.noKeyOnThisDevice):
            return "This iPad doesn’t have the key to your \(name) backups yet. It arrives through iCloud Keychain from your other devices; if it doesn’t, enter your recovery key."
        case .needsRecoveryKey(.differentKey):
            return "Your \(name) backups were made with a different key from the one on this iPad. Enter your recovery key to use them."
        case .recoveryKeyDoesNotMatch:
            return "That recovery key isn’t the one your \(name) backups were made with. Check it and try again."
        case .deletionUnfinished:
            return "\(name) didn’t finish deleting your backups. Try again."
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Why a session's mode refuses a backup (`readOnly` or `overAllowance`).
    static func uploadRefused(_ session: BackupServiceSession) -> TactileCloudError {
        session.mode == .readOnly
            ? .readOnly(readOnlyUntil: session.subscription.readOnlyUntil, deleteAfter: session.subscription.deleteAfter)
            : .overAllowance(usedBytes: session.usage.bytes, allowanceBytes: session.usage.allowanceBytes)
    }
}

/// The reader's Tactile Texts Cloud account, as the UI shows it: one state, the plan, usage and
/// allowance, the recovery key, refresh and delete-everything.
///
/// The state comes from StoreKit first (never subscribed: the service is not asked), then from
/// the service's last answer (every session, whoever asked for it, updates it), then from the
/// key check in the reader's folder.
@MainActor @Observable
final class CloudBackupAccount {
    enum Status: Hashable, Sendable {
        /// This build has no backup service (no product IDs configured).
        case notInThisBuild
        /// Not checked yet, or the last check failed before anything was known (`lastError`).
        case unknown
        /// The App Store could not be asked (the reason is reader-facing).
        case storeUnavailable(reason: String)
        /// Never subscribed on this Apple ID (StoreKit says so; the service was not asked).
        case notSubscribed
        /// Backups exist that this device cannot read without the recovery key. `accessMode`
        /// still says what the subscription allows.
        case needsRecoveryKey(CloudBackupKeyNeed)
        /// Subscribed: back up, restore and delete.
        case active
        /// Subscribed but over the allowance: restore and delete only.
        case overAllowance
        /// The subscription ended: restore only, until `readOnlyUntil`; deleted after `deleteAfter`.
        case readOnly(readOnlyUntil: Date?, deleteAfter: Date?)
        /// The subscription ended long enough ago that there is no access; the backups are kept
        /// until `deleteAfter`, and resubscribing restores access.
        case lapsed(deleteAfter: Date?)
        /// Refunded or revoked: no access; the backups are deleted after `deleteAfter`.
        case revoked(deleteAfter: Date?)
        /// The subscription ended and its backups were deleted.
        case dataDeleted
    }

    /// The single state for the UI.
    private(set) var status: Status
    /// The last failure that left the state as it was (no network, App Attest, the Keychain…),
    /// cleared by the next success. Reader-facing through `localizedDescription`.
    private(set) var lastError: (any Error)?
    /// What the last session's credentials allow; `nil` without a session.
    private(set) var accessMode: BackupServiceAccessMode?
    /// The subscription as the service last described it (dates for read-only and lapsed).
    private(set) var subscriptionInfo: BackupServiceSubscriptionInfo?
    /// Usage and allowance at the service's last count.
    private(set) var usage: BackupServiceUsage?
    /// Whether this device holds a backup key; `nil` until known.
    private(set) var hasKeyOnThisDevice: Bool?
    /// Whether the recovery key for the current key has been shown on this device.
    private(set) var recoveryKeyShown: Bool
    /// Whether the reader said they saved the recovery key (or entered it here).
    private(set) var recoveryKeySaved: Bool
    /// A refresh is under way.
    private(set) var isRefreshing = false

    /// The App Store subscription; `nil` when the build has no service.
    let subscription: BackupSubscription?
    @ObservationIgnored let connection: CloudBackupConnection?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var access: Access = .unknown
    @ObservationIgnored private var keyNeed: CloudBackupKeyNeed?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var stateAtLastRefresh: BackupSubscription.State?

    static let recoveryKeyShownKey = "software.tactile.marginal.cloud-backup.recovery-key-shown"
    static let recoveryKeySavedKey = "software.tactile.marginal.cloud-backup.recovery-key-saved"
    /// Delete-everything gives up after this many unfinished batches (100,000 objects each).
    static let maxDeletionRounds = 200

    private enum Access {
        case unknown
        case granted(BackupServiceAccessMode)
        case refused(Status)
    }

    /// - Parameters:
    ///   - subscription, connection: both `nil` when the build has no service (the state is then
    ///     `notInThisBuild`).
    ///   - defaults: where the recovery key flags are kept.
    init(subscription: BackupSubscription?, connection: CloudBackupConnection?, defaults: UserDefaults = .standard) {
        self.subscription = subscription
        self.connection = connection
        self.defaults = defaults
        recoveryKeyShown = defaults.bool(forKey: Self.recoveryKeyShownKey)
        recoveryKeySaved = defaults.bool(forKey: Self.recoveryKeySavedKey)
        if subscription == nil || connection == nil {
            access = .refused(.notInThisBuild)
            status = .notInThisBuild
        } else {
            status = .unknown
        }
        connection?.setObserver { [weak self] event in
            await self?.handle(event)
        }
    }

    /// The subscription's plan (product), when the reader has or had one.
    var plan: BackupSubscription.Plan? {
        switch subscription?.state {
        case .subscribed(let plan, _, _), .ended(let plan, _): plan
        default: nil
        }
    }

    // MARK: Refresh

    /// Works the state out again: StoreKit's view (loading the products first if needed), then a
    /// new session from the service (unless StoreKit says the reader never subscribed), then the
    /// key check in the reader's folder. Concurrent calls share one refresh. Failures land in
    /// `lastError` or in the state (lapsed, revoked, deleted); nothing is thrown.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        isRefreshing = true
        await task.value
        refreshTask = nil
        isRefreshing = false
    }

    private func performRefresh() async {
        guard let subscription, let connection else { return }
        if subscription.state == .loading { await subscription.load() }
        let state = subscription.state
        stateAtLastRefresh = state
        switch state {
        case .loading:
            return
        case .unavailable(.notConfigured):
            set(access: .refused(.notInThisBuild))
        case .unavailable(let reason):
            set(access: .refused(.storeUnavailable(reason: reason.message)))
        case .notSubscribed:
            accessMode = nil
            usage = nil
            subscriptionInfo = nil
            lastError = nil
            set(access: .refused(.notSubscribed))
        case .subscribed, .ended:
            do {
                let session = try await connection.currentSession(forceNew: true)
                switch try await connection.keyState(for: session) {
                case .ready:
                    hasKeyOnThisDevice = true
                    keyNeed = nil
                case .noKeyYet:
                    hasKeyOnThisDevice = false
                    keyNeed = nil
                case .needsRecoveryKey(let need):
                    hasKeyOnThisDevice = need == .differentKey
                    keyNeed = need
                }
                lastError = nil
                status = computedStatus()
            } catch is CancellationError {
                return
            } catch {
                applyFailure(error)
            }
        }
    }

    /// Whether `availability` must ask before answering: nothing known yet, or the App Store's
    /// view changed since the last refresh (a purchase, an expiry).
    var needsRefresh: Bool {
        guard subscription != nil else { return false }
        if case .unknown = status { return true }
        return subscription?.state != stateAtLastRefresh
    }

    /// The destination's availability: from the state, refreshing first only when
    /// `needsRefresh` (so automatic backups skip quietly when not subscribed, without a request).
    func availability() async -> BackupDestinationAvailability {
        if needsRefresh { await refresh() }
        return Self.availability(status: status, info: subscriptionInfo, lastError: lastError)
    }

    /// Available while backups can be used at all (active, read-only, over the allowance);
    /// otherwise the reason. Read-only and over-allowance are available so restores and
    /// deletes work; a backup is refused when it starts, with the reason.
    static func availability(status: Status, info: BackupServiceSubscriptionInfo?,
                             lastError: (any Error)?) -> BackupDestinationAvailability {
        func unavailable(_ error: any Error) -> BackupDestinationAvailability {
            .unavailable(reason: error.localizedDescription)
        }
        switch status {
        case .active, .overAllowance, .readOnly:
            return .available
        case .notInThisBuild:
            return unavailable(TactileCloudError.notInThisBuild)
        case .unknown:
            return .unavailable(reason: lastError?.localizedDescription ?? "Checking \(TactileCloudError.serviceName)…")
        case .storeUnavailable(let reason):
            return .unavailable(reason: reason)
        case .notSubscribed:
            return unavailable(CloudServiceError.notSubscribed)
        case .needsRecoveryKey(let need):
            return unavailable(TactileCloudError.needsRecoveryKey(need))
        case .lapsed:
            return unavailable(CloudServiceError.subscriptionLapsed(info))
        case .revoked:
            return unavailable(CloudServiceError.subscriptionRevoked(info))
        case .dataDeleted:
            return unavailable(CloudServiceError.dataDeleted(info))
        }
    }

    // MARK: The recovery key

    /// Stores the key `text` stands for, after checking it against the reader's folder: a valid
    /// key that is not the backups' key throws `recoveryKeyDoesNotMatch` and stores nothing.
    /// Throws `BackupError`'s recovery key errors for a mistyped key, and the service's or
    /// storage's errors when the folder can't be checked.
    func adoptRecoveryKey(_ text: String) async throws {
        guard let connection else { throw TactileCloudError.notInThisBuild }
        let key = try BackupEncryptionKey(recoveryKey: text)
        let session = try await connection.currentSession()
        if try await connection.check(key, storage: session.storage) == .differentKey {
            throw TactileCloudError.recoveryKeyDoesNotMatch
        }
        _ = try await connection.keyStore.adoptKey(recoveryKey: text)
        connection.invalidateDestinations()
        hasKeyOnThisDevice = true
        keyNeed = nil
        setRecoveryKeyFlags(shown: true, saved: true)
        status = computedStatus()
    }

    /// The recovery key for this device's key (marks it shown). Throws
    /// `BackupKeyStoreError.noKey` before the first backup made one.
    func recoveryKey() async throws -> BackupRecoveryKey {
        guard let connection else { throw TactileCloudError.notInThisBuild }
        let key = try await connection.keyStore.recoveryKey()
        setRecoveryKeyFlags(shown: true, saved: recoveryKeySaved)
        return key
    }

    /// The reader confirmed they saved the recovery key.
    func markRecoveryKeySaved() {
        setRecoveryKeyFlags(shown: true, saved: true)
    }

    // MARK: Deleting everything

    /// Deletes every backup in the reader's folder (`/v1/delete-my-data`, repeated until the
    /// service says it is done), then removes the key, so the next backup makes a fresh one.
    /// The key is removed only after the data is gone: removing it deletes it from every device
    /// through iCloud Keychain. Then refreshes.
    func deleteEverything() async throws {
        guard let connection else { throw TactileCloudError.notInThisBuild }
        do {
            var rounds = 0
            while true {
                try Task.checkCancellation()
                if try await connection.deleteMyData().done { break }
                rounds += 1
                if rounds >= Self.maxDeletionRounds { throw TactileCloudError.deletionUnfinished }
            }
            try await connection.keyStore.removeKey()
        } catch {
            if !(error is CancellationError) { lastError = error }
            throw error
        }
        connection.invalidateDestinations()
        hasKeyOnThisDevice = false
        keyNeed = nil
        setRecoveryKeyFlags(shown: false, saved: false)
        await refresh()
    }

    // MARK: - Internals

    private func handle(_ event: CloudBackupConnectionEvent) {
        switch event {
        case .session(let session):
            accessMode = session.mode
            subscriptionInfo = session.subscription
            usage = session.usage
            lastError = nil
            set(access: .granted(session.mode))
        case .sessionFailed(let error):
            applyFailure(error)
        case .keyCreated:
            hasKeyOnThisDevice = true
            keyNeed = nil
            setRecoveryKeyFlags(shown: false, saved: false)
            status = computedStatus()
        }
    }

    /// The service's refusals become states; anything else is `lastError`, the state unchanged.
    private func applyFailure(_ error: any Error) {
        switch error as? CloudServiceError {
        case .subscriptionLapsed(let info):
            refused(.lapsed(deleteAfter: info?.deleteAfter), info: info)
        case .subscriptionRevoked(let info):
            refused(.revoked(deleteAfter: info?.deleteAfter), info: info)
        case .dataDeleted(let info):
            refused(.dataDeleted, info: info)
        case .notSubscribed:
            refused(.notSubscribed, info: nil)
        default:
            lastError = error
        }
    }

    private func refused(_ status: Status, info: BackupServiceSubscriptionInfo?) {
        accessMode = nil
        usage = nil
        subscriptionInfo = info
        lastError = nil
        set(access: .refused(status))
    }

    private func set(access: Access) {
        self.access = access
        status = computedStatus()
    }

    private func computedStatus() -> Status {
        switch access {
        case .unknown:
            return .unknown
        case .refused(let status):
            return status
        case .granted(let mode):
            if let keyNeed { return .needsRecoveryKey(keyNeed) }
            switch mode {
            case .readWrite: return .active
            case .readDelete: return .overAllowance
            case .readOnly: return .readOnly(readOnlyUntil: subscriptionInfo?.readOnlyUntil, deleteAfter: subscriptionInfo?.deleteAfter)
            }
        }
    }

    private func setRecoveryKeyFlags(shown: Bool, saved: Bool) {
        recoveryKeyShown = shown
        recoveryKeySaved = saved
        defaults.set(shown, forKey: Self.recoveryKeyShownKey)
        defaults.set(saved, forKey: Self.recoveryKeySavedKey)
    }
}
