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
            return DeviceKind.current.pick(
                iPad: "This iPad doesn’t have the key to your \(name) backups yet. It arrives through iCloud Keychain from your other devices; if it doesn’t, enter your recovery key.",
                iPhone: "This iPhone doesn’t have the key to your \(name) backups yet. It arrives through iCloud Keychain from your other devices; if it doesn’t, enter your recovery key.")
        case .needsRecoveryKey(.differentKey):
            return DeviceKind.current.pick(
                iPad: "Your \(name) backups were made with a different key from the one on this iPad. Enter your recovery key to use them.",
                iPhone: "Your \(name) backups were made with a different key from the one on this iPhone. Enter your recovery key to use them.")
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
/// The state comes from the sign-in first (signed out: the service is not asked), then from the
/// service's last answer (every session, whoever asked for it, updates it; the App Store
/// transaction is sent when there is one, so a purchase binds to the account), then from the key
/// check in the account's folder. Signing in, signing out and a session that ended reset it.
@MainActor @Observable
final class CloudBackupAccount {
    enum Status: Hashable, Sendable {
        /// This build has no backup service (no product IDs, or no way of signing in).
        case notInThisBuild
        /// Not checked yet, or the last check failed before anything was known (`lastError`).
        case unknown
        /// Not signed in: the offer and the sign-in buttons. The library is unaffected.
        case signedOut
        /// The App Store could not be asked (the reason is reader-facing).
        case storeUnavailable(reason: String)
        /// Signed in, and the account has no subscription.
        case notSubscribed
        /// Signed in, but the subscription on this Apple Account pays for another account
        /// (`subscriptionOtherAccount` or `subscriptionInUse`).
        case subscriptionElsewhere(CloudServiceError)
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
    /// Whether this device holds the signed-in account's backup key; `nil` until known.
    private(set) var hasKeyOnThisDevice: Bool?
    /// Whether the recovery key for the current key has been shown on this device.
    private(set) var recoveryKeyShown: Bool
    /// Whether the reader said they saved the recovery key (or entered it here).
    private(set) var recoveryKeySaved: Bool
    /// A refresh is under way.
    private(set) var isRefreshing = false

    /// The App Store subscription; `nil` when the build has no service.
    let subscription: BackupSubscription?
    /// Signing in; `nil` when the build has no service.
    let signIn: CloudBackupSignIn?
    @ObservationIgnored let connection: CloudBackupConnection?
    /// Called when the account is seen subscribed and able to back up (automatic backup's
    /// default for a signed-in subscriber).
    @ObservationIgnored var onActiveSubscriber: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var access: Access = .unknown
    @ObservationIgnored private var keyNeed: CloudBackupKeyNeed?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var stateAtLastRefresh: BackupSubscription.State?
    @ObservationIgnored private var signInGenerationAtLastRefresh: Int?

    static let recoveryKeyShownKey = "software.tactile.texts.cloud-backup.recovery-key-shown"
    static let recoveryKeySavedKey = "software.tactile.texts.cloud-backup.recovery-key-saved"
    /// Delete-everything gives up after this many unfinished batches (100,000 objects each).
    static let maxDeletionRounds = 200

    /// The recovery key flags are kept per account: `<key>.<account ID>`.
    static func flagKey(_ key: String, account: String) -> String { "\(key).\(account)" }

    private enum Access {
        case unknown
        case granted(BackupServiceAccessMode)
        case refused(Status)
    }

    /// - Parameters:
    ///   - subscription, connection, signIn: all `nil` when the build has no service (the state
    ///     is then `notInThisBuild`); a sign-in with no way of signing in counts the same.
    ///   - defaults: where the recovery key flags are kept.
    init(subscription: BackupSubscription?, connection: CloudBackupConnection?, signIn: CloudBackupSignIn? = nil,
         defaults: UserDefaults = .standard) {
        self.subscription = subscription
        self.connection = connection
        self.signIn = signIn
        self.defaults = defaults
        recoveryKeyShown = false
        recoveryKeySaved = false
        if subscription == nil || connection == nil || signIn?.isAvailable != true {
            access = .refused(.notInThisBuild)
            status = .notInThisBuild
        } else if signIn?.isSignedIn != true {
            access = .refused(.signedOut)
            status = .signedOut
        } else {
            status = .unknown
        }
        loadRecoveryKeyFlags()
        connection?.setObserver { [weak self] event in
            await self?.handle(event)
        }
    }

    /// The subscription's plan (product), when the reader has or had one.
    var plan: BackupSubscription.Plan? {
        switch subscription?.state {
        case .subscribed(let plan, _, _), .ended(let plan, _): return plan
        default: break
        }
        if let info = subscriptionInfo { return BackupSubscription.Plan(productID: info.productID, product: subscription?.products.first { $0.id == info.productID }) }
        return nil
    }

    // MARK: Signing in and out

    /// Told first whenever the sign-in changes (sync stops and forgets its engine; the library
    /// and every account's sync directory stay).
    @ObservationIgnored var onSignInChanged: (() -> Void)?

    /// The sign-in changed (signed in, out, to another account, or the session ended): nothing
    /// known about the last account's folder is kept, and a signed-in account is checked again.
    /// The library is not touched.
    func signInChanged() {
        onSignInChanged?()
        connection?.reset()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        accessMode = nil
        usage = nil
        subscriptionInfo = nil
        lastError = nil
        keyNeed = nil
        hasKeyOnThisDevice = nil
        loadRecoveryKeyFlags()
        guard let signIn, signIn.isAvailable, subscription != nil, connection != nil else { return }
        if signIn.isSignedIn {
            access = .unknown
            status = .unknown
            Task { await self.refresh() }
        } else {
            access = .refused(.signedOut)
            status = .signedOut
            signInGenerationAtLastRefresh = signIn.generation
        }
    }

    // MARK: Refresh

    /// Works the state out again: the sign-in, StoreKit's view (loading the products first if
    /// needed), then a new session from the service (sending the App Store transaction when there
    /// is one), then the key check in the account's folder. Concurrent calls share one refresh.
    /// Failures land in `lastError` or in the state (signed out, lapsed, revoked, deleted);
    /// nothing is thrown.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        isRefreshing = true
        await task.value
        if refreshTask == task {
            refreshTask = nil
            isRefreshing = false
        }
    }

    private func performRefresh() async {
        guard let subscription, let connection, let signIn else { return }
        guard signIn.isAvailable else { return set(access: .refused(.notInThisBuild)) }
        if subscription.state == .loading { await subscription.load() }
        let state = subscription.state
        let generation = signIn.generation
        stateAtLastRefresh = state
        signInGenerationAtLastRefresh = generation
        if case .unavailable(.notConfigured) = state { return set(access: .refused(.notInThisBuild)) }
        guard signIn.isSignedIn else {
            accessMode = nil
            usage = nil
            subscriptionInfo = nil
            lastError = nil
            return set(access: .refused(.signedOut))
        }
        do {
            let session = try await connection.currentSession(forceNew: true)
            guard signIn.generation == generation else { return }
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
            noteActiveSubscriber()
        } catch is CancellationError {
            return
        } catch {
            guard signIn.generation == generation else { return }
            if case .notSubscribed = error as? CloudServiceError, case .unavailable(let reason) = state {
                // Nothing to buy with until the App Store answers.
                return refused(.storeUnavailable(reason: reason.message), info: nil)
            }
            applyFailure(error)
        }
    }

    /// Whether `availability` must ask before answering: nothing known yet, the App Store's view
    /// changed since the last refresh (a purchase, an expiry), or the sign-in changed.
    var needsRefresh: Bool {
        guard subscription != nil, let signIn else { return false }
        if case .unknown = status { return true }
        return subscription?.state != stateAtLastRefresh || signIn.generation != signInGenerationAtLastRefresh
    }

    /// The destination's availability: from the state, refreshing first only when
    /// `needsRefresh` (so automatic backups skip quietly when signed out or not subscribed,
    /// without a request).
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
        case .signedOut:
            return unavailable(CloudServiceError.notSignedIn)
        case .storeUnavailable(let reason):
            return .unavailable(reason: reason)
        case .notSubscribed:
            return unavailable(CloudServiceError.notSubscribed)
        case .subscriptionElsewhere(let error):
            return unavailable(error)
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

    /// Stores the key `text` stands for, after checking it against the account's folder: a valid
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

    /// Deletes every backup in the account's folder (`/v1/delete-my-data`, repeated until the
    /// service says it is done), then removes the account's key, so the next backup makes a
    /// fresh one. The key is removed only after the data is gone: removing it deletes it from
    /// every device through iCloud Keychain. Then refreshes.
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
            if case .sessionInvalid = error as? CloudServiceError {
                signIn?.endLocally(.sessionEnded)
            } else if !(error is CancellationError) {
                lastError = error
            }
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
            noteActiveSubscriber()
        case .sessionFailed(let error):
            applyFailure(error)
        case .keyCreated:
            hasKeyOnThisDevice = true
            keyNeed = nil
            setRecoveryKeyFlags(shown: false, saved: false)
            status = computedStatus()
            // The key can now name this device to the account's other devices.
            if let signIn { Task { await signIn.refreshAccount() } }
        }
    }

    /// The service's refusals become states; anything else is `lastError`, the state unchanged.
    /// A session that has ended signs out here (the library stays as it is).
    private func applyFailure(_ error: any Error) {
        switch error as? CloudServiceError {
        case .sessionInvalid:
            if let signIn, signIn.isSignedIn {
                signIn.endLocally(.sessionEnded)
            } else {
                refused(.signedOut, info: nil)
            }
        case .notSignedIn:
            refused(.signedOut, info: nil)
        case .subscriptionLapsed(let info):
            refused(.lapsed(deleteAfter: info?.deleteAfter), info: info)
        case .subscriptionRevoked(let info):
            refused(.revoked(deleteAfter: info?.deleteAfter), info: info)
        case .dataDeleted(let info):
            refused(.dataDeleted, info: info)
        case .notSubscribed:
            refused(.notSubscribed, info: nil)
        case .subscriptionOtherAccount:
            refused(.subscriptionElsewhere(.subscriptionOtherAccount), info: nil)
        case .subscriptionInUse:
            refused(.subscriptionElsewhere(.subscriptionInUse), info: nil)
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

    private func noteActiveSubscriber() {
        switch status {
        case .active, .overAllowance: onActiveSubscriber?()
        default: break
        }
    }

    private func loadRecoveryKeyFlags() {
        guard let account = signIn?.accountID else {
            recoveryKeyShown = false
            recoveryKeySaved = false
            return
        }
        recoveryKeyShown = defaults.bool(forKey: Self.flagKey(Self.recoveryKeyShownKey, account: account))
        recoveryKeySaved = defaults.bool(forKey: Self.flagKey(Self.recoveryKeySavedKey, account: account))
    }

    private func setRecoveryKeyFlags(shown: Bool, saved: Bool) {
        recoveryKeyShown = shown
        recoveryKeySaved = saved
        guard let account = signIn?.accountID else { return }
        defaults.set(shown, forKey: Self.flagKey(Self.recoveryKeyShownKey, account: account))
        defaults.set(saved, forKey: Self.flagKey(Self.recoveryKeySavedKey, account: account))
    }
}
