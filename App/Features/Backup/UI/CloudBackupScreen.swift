import AuthenticationServices
import Observation
import ReaderBackup
import StoreKit
import SwiftUI
import UIKit

/// Tactile Texts Cloud's screen state: the account, the backups (through the same
/// `BackupDestinationModel` as every destination), buying and restoring the subscription, and
/// deleting everything.
@Observable
@MainActor
final class CloudBackupScreenModel {
    /// What a sheet over the screen shows.
    enum Sheet: Identifiable, Equatable {
        /// The recovery key; `prompt` after the first backup made it.
        case recoveryKey(prompt: Bool)
        case enterRecoveryKey

        var id: String {
            switch self {
            case .recoveryKey(let prompt): "recoveryKey.\(prompt)"
            case .enterRecoveryKey: "enterRecoveryKey"
            }
        }
    }

    /// A confirmation or explanation about the account.
    enum AccountAlert: Identifiable, Equatable {
        case signOut
        case signOutEverywhere
        case change(to: CloudSignInProvider)
        case delete
        /// After the change: suggests Sign Out of All Devices.
        case changed(to: CloudSignInProvider)
        /// The change was refused: the new identity has an account of its own.
        case identityInUse(CloudSignInProvider)

        var id: String {
            switch self {
            case .signOut: "signOut"
            case .signOutEverywhere: "signOutEverywhere"
            case .change(let provider): "change.\(provider.rawValue)"
            case .delete: "delete"
            case .changed(let provider): "changed.\(provider.rawValue)"
            case .identityInUse(let provider): "identityInUse.\(provider.rawValue)"
            }
        }
    }

    let cloud: TactileCloudBackup
    let destination: BackupDestinationModel
    var failure: BackupFailure?
    var sheet: Sheet?
    var accountAlert: AccountAlert?
    var isDeleteConfirmationPresented = false
    var isManageSubscriptionsPresented = false
    /// Objects deleted so far while the account is being deleted.
    private(set) var accountDeletionCount = 0
    /// Something to tell the reader (a purchase waiting for approval, nothing to restore).
    private(set) var notice: String?
    private(set) var isPurchasing = false
    private(set) var isRestoringPurchases = false
    private(set) var isDeleting = false

    init(cloud: TactileCloudBackup, environment: AppEnvironment, screenModel: BackupScreenModel?) {
        self.cloud = cloud
        destination = BackupDestinationModel(entryID: TactileCloudBackupDestination.destinationID, environment: environment,
                                             screenModel: screenModel)
    }

    var account: CloudBackupAccount { cloud.account }
    var subscription: BackupSubscription { cloud.subscription }
    var signIn: CloudBackupSignIn { cloud.signIn }

    var page: CloudBackupPage { CloudBackupPage.make(account.status, hasError: account.lastError != nil) }

    /// Asks the App Store and the service again (and the account screen), then lists the backups.
    func refresh() async {
        async let accountScreen: Void = signIn.refreshAccount()
        await account.refresh()
        await accountScreen
        await destination.refresh()
    }

    // MARK: Signing in and the account

    func signIn(with provider: CloudSignInProvider, anchor: ASPresentationAnchor?) {
        notice = nil
        Task {
            do {
                try await signIn.signIn(with: provider, anchor: anchor)
                await destination.refresh()
            } catch {
                if case .cancelled = error as? CloudSignInError { return }
                failure = BackupFailure.from(error, title: "Couldn’t Sign In")
            }
        }
    }

    func changeSignIn(anchor: ASPresentationAnchor?) {
        guard let target = signIn.session?.provider.other else { return }
        Task {
            do {
                try await signIn.changeSignIn(anchor: anchor)
                accountAlert = .changed(to: target)
            } catch CloudServiceError.identityInUse {
                accountAlert = .identityInUse(target)
            } catch {
                if case .cancelled = error as? CloudSignInError { return }
                failure = BackupFailure.from(error, title: "Couldn’t Change the Sign-In")
            }
        }
    }

    func signOut() {
        Task { await signIn.signOut() }
    }

    func signOutEverywhere() {
        Task {
            do {
                try await signIn.signOutEverywhere()
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Sign Out Every Device")
            }
        }
    }

    func deleteAccount(anchor: ASPresentationAnchor?) {
        accountDeletionCount = 0
        Task {
            do {
                try await cloud.deleteAccount(anchor: anchor) { count in self.accountDeletionCount = count }
            } catch {
                if case .cancelled = error as? CloudSignInError { return }
                failure = BackupFailure.from(error, title: "Couldn’t Delete Your Account")
            }
        }
    }

    // MARK: Subscribing

    /// The product to buy again after the subscription ended: the reader's plan, else the first.
    var resubscribeProductID: String? {
        account.plan?.productID ?? subscription.products.first?.id
    }

    func subscribe(_ productID: String, scene: UIScene?) {
        guard !isPurchasing, signIn.isSignedIn else { return }
        notice = nil
        isPurchasing = true
        Task {
            defer { isPurchasing = false }
            do {
                // The account's token, so the purchase names the account it pays for.
                let outcome = try await subscription.purchase(productID, appAccountToken: signIn.appAccountToken,
                                                              confirmIn: scene)
                notice = CloudBackupOfferText.message(after: outcome)
                if outcome == .purchased { await refresh() }
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Subscribe")
            }
        }
    }

    func restorePurchases() {
        guard !isRestoringPurchases, signIn.isSignedIn else { return }
        notice = nil
        isRestoringPurchases = true
        Task {
            defer { isRestoringPurchases = false }
            do {
                try await subscription.restore()
                notice = CloudBackupOfferText.messageAfterRestore(subscription.state)
                await refresh()
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Restore Purchases")
            }
        }
    }

    // MARK: Deleting everything

    /// Deletes every backup and the key (`CloudBackupAccount.deleteEverything`). `true` when it
    /// finished.
    @discardableResult
    func deleteEverything() async -> Bool {
        guard !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await account.deleteEverything()
            notice = "Your backups in \(CloudServiceError.serviceName) have been deleted."
            await destination.refresh()
            return true
        } catch {
            failure = BackupFailure.from(error, title: "Couldn’t Delete Your Cloud Backups")
            return false
        }
    }
}

/// Tactile Texts Cloud: the offer when the reader isn't subscribed; otherwise the subscription,
/// a banner for every state but plain active, Back Up Now, the backups, the recovery key and
/// Delete My Cloud Backups. Reached from its row on the Backup screen.
struct CloudBackupScreen: View {
    let cloud: TactileCloudBackup
    let screenModel: BackupScreenModel?

    @Environment(AppEnvironment.self) private var environment
    @State private var model: CloudBackupScreenModel?

    var body: some View {
        Group {
            if let model {
                CloudBackupContent(model: model)
            } else {
                ProgressView()
            }
        }
        .settingsPageMargins()
        .navigationTitle(CloudServiceError.serviceName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = CloudBackupScreenModel(cloud: cloud, environment: environment, screenModel: screenModel) }
        }
    }
}

private struct CloudBackupContent: View {
    @Bindable var model: CloudBackupScreenModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window: WindowContext?
    @State private var restoreRequest: RestoreRequest?

    private var account: CloudBackupAccount { model.account }
    private var service: BackupService { environment.backupService }
    private var scene: UIScene? { window?.presentationAnchor?.windowScene }

    private var shouldPromptForKey: Bool {
        CloudBackupRecoveryKeyLogic.shouldPrompt(hasKey: account.hasKeyOnThisDevice, shown: account.recoveryKeyShown,
                                                 isBusy: service.isBusy, status: account.status)
    }

    var body: some View {
        Group {
            switch model.page {
            case .checking:
                VStack(spacing: Space.m) {
                    ProgressView()
                    Text("Checking \(CloudServiceError.serviceName)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.checking)
            case .offer:
                CloudBackupOfferView(model: model, scene: scene, anchor: window?.presentationAnchor)
            case .status:
                CloudBackupStatusView(model: model, restoreRequest: $restoreRequest, scene: scene)
            }
        }
        .toolbar { BackupDoneToolbarItem() }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .onChange(of: service.isBusy) { _, busy in
            if !busy { Task { await model.destination.refresh() } }
        }
        .onChange(of: account.status) { _, _ in
            Task { await model.destination.refresh() }
        }
        .onChange(of: shouldPromptForKey, initial: true) { _, prompt in
            if prompt, model.sheet == nil { model.sheet = .recoveryKey(prompt: true) }
        }
        .sheet(item: $restoreRequest, onDismiss: { Task { await model.destination.refresh() } }) { RestoreFlowView(request: $0) }
        // On its own view: one sheet modifier per view.
        .background {
            Color.clear
                .sheet(item: $model.sheet) { sheet in
                    switch sheet {
                    case .recoveryKey(let prompt):
                        CloudRecoveryKeyScreen(account: account, isPrompt: prompt)
                    case .enterRecoveryKey:
                        CloudEnterRecoveryKeyScreen(model: model)
                    }
                }
        }
        .manageSubscriptionsSheet(isPresented: $model.isManageSubscriptionsPresented)
        .backupFailureAlert($model.failure)
        .backupFailureAlert(Binding(get: { model.destination.failure }, set: { model.destination.failure = $0 }))
        .backupSnapshotDeleteAlert(model.destination)
        .alert(CloudBackupRecoveryKeyText.deleteTitle, isPresented: $model.isDeleteConfirmationPresented) {
            Button("Delete My Cloud Backups", role: .destructive) { Task { await model.deleteEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CloudBackupRecoveryKeyText.deleteMessage)
        }
        // On its own view: the account's confirmations.
        .background {
            CloudAccountAlerts(model: model, anchor: window?.presentationAnchor)
        }
    }
}

/// The account's confirmations and explanations (`CloudBackupScreenModel.AccountAlert`).
private struct CloudAccountAlerts: View {
    @Bindable var model: CloudBackupScreenModel
    let anchor: UIWindow?

    private var current: CloudSignInProvider { model.signIn.session?.provider ?? .apple }

    var body: some View {
        Color.clear
            .alert(title, isPresented: Binding(get: { model.accountAlert != nil }, set: { if !$0 { model.accountAlert = nil } }),
                   presenting: model.accountAlert) { alert in
                switch alert {
                case .signOut:
                    Button(CloudAccountText.signOutButton, role: .destructive) { model.signOut() }
                    Button("Cancel", role: .cancel) {}
                case .signOutEverywhere:
                    Button(CloudAccountText.signOutAllButton, role: .destructive) { model.signOutEverywhere() }
                    Button("Cancel", role: .cancel) {}
                case .change:
                    Button(CloudAccountText.changeButton) { model.changeSignIn(anchor: anchor) }
                    Button("Cancel", role: .cancel) {}
                case .delete:
                    Button(CloudAccountText.deleteButton, role: .destructive) { model.deleteAccount(anchor: anchor) }
                    Button("Cancel", role: .cancel) {}
                case .changed:
                    Button(CloudAccountText.signOutAllButton + "…") {
                        // After this alert has gone.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(500))
                            model.accountAlert = .signOutEverywhere
                        }
                    }
                    Button("Not Now", role: .cancel) {}
                case .identityInUse:
                    Button("OK", role: .cancel) {}
                }
            } message: { alert in
                Text(message(alert))
            }
    }

    private var title: String {
        switch model.accountAlert {
        case .signOut: CloudAccountText.signOutTitle
        case .signOutEverywhere: CloudAccountText.signOutAllTitle
        case .change(let provider): CloudAccountText.changeConfirmTitle(to: provider)
        case .delete: CloudAccountText.deleteTitle
        case .changed(let provider): CloudAccountText.changedTitle(to: provider)
        case .identityInUse(let provider): CloudAccountText.identityInUseTitle(provider)
        case nil: ""
        }
    }

    private func message(_ alert: CloudBackupScreenModel.AccountAlert) -> String {
        switch alert {
        case .signOut: CloudAccountText.signOutMessage
        case .signOutEverywhere: CloudAccountText.signOutAllMessage
        case .change(let provider): CloudAccountText.changeConfirmMessage(from: current, to: provider)
        case .delete: CloudAccountText.deleteMessage(provider: current)
        case .changed: CloudAccountText.changedMessage
        case .identityInUse(let provider): CloudAccountText.identityInUseMessage(provider)
        }
    }
}

// MARK: - Signing in and the account

/// Sign in with Apple and Sign in with Google at equal weight (App Store Review Guideline 4.8):
/// the same width and height, Apple's in the system's own button. Only the ways this build
/// offers are shown.
private struct CloudSignInSection: View {
    let model: CloudBackupScreenModel
    let anchor: UIWindow?

    @Environment(\.colorScheme) private var colorScheme

    private var signIn: CloudBackupSignIn { model.signIn }
    private static let buttonHeight: CGFloat = 50

    var body: some View {
        Section {
            if let reason = signIn.signedOutReason {
                Label {
                    Text(CloudAccountText.signedOutNotice(reason))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(Color.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.signedOutNotice)
            }
            Text(CloudAccountText.signInIntro)
                .foregroundStyle(.secondary)
            VStack(spacing: Space.s) {
                if signIn.availableProviders.contains(.apple) {
                    AppleSignInButton(dark: colorScheme == .dark) { model.signIn(with: .apple, anchor: anchor) }
                        .frame(maxWidth: .infinity, minHeight: Self.buttonHeight, maxHeight: Self.buttonHeight)
                        .accessibilityLabel(CloudAccountText.signInTitle(.apple))
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.signInApple)
                }
                if signIn.availableProviders.contains(.google) {
                    Button {
                        model.signIn(with: .google, anchor: anchor)
                    } label: {
                        Text(CloudAccountText.signInTitle(.google))
                            .font(.system(size: 19, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(colorScheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.signInGoogle)
                }
            }
            .disabled(signIn.activity != nil)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if let activity = signIn.activity {
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text(CloudAccountText.busy(activity)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.accountBusy)
            }
        } header: {
            Text(CloudAccountText.signInHeader)
        } footer: {
            Text(CloudAccountText.lostAccess)
        }
    }
}

/// The system's Sign in with Apple button (`ASAuthorizationAppleIDButton`), which starts the
/// app's own flow (the nonce comes from the service first).
private struct AppleSignInButton: UIViewRepresentable {
    let dark: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: dark ? .white : .black)
        button.cornerRadius = 8
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

/// The signed-in account: which sign-in (and the email it carries, from this device's sign-in
/// only), Change to the other sign-in, the devices, Sign Out, Sign Out of All Devices and Delete
/// Account.
private struct CloudAccountSection: View {
    let model: CloudBackupScreenModel

    @Environment(AppEnvironment.self) private var environment

    private var signIn: CloudBackupSignIn { model.signIn }

    var body: some View {
        if let session = signIn.session {
            Section {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(CloudAccountText.signedInWith(session.provider))
                    if let email = session.email {
                        Text(email)
                            .font(Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.accountSignIn)
                if let activity = signIn.activity {
                    HStack(spacing: Space.s) {
                        ProgressView()
                        Text(activity == .deletingAccount && model.accountDeletionCount > 0
                             ? "\(CloudAccountText.deleting) (\(model.accountDeletionCount.formatted(.number)) items)"
                             : CloudAccountText.busy(activity))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.accountBusy)
                }
                if signIn.availableProviders.contains(session.provider.other) {
                    Button(CloudAccountText.changeTitle(to: session.provider.other)) {
                        model.accountAlert = .change(to: session.provider.other)
                    }
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.changeSignIn)
                }
            } header: {
                Text(CloudAccountText.accountHeader)
            }
            .disabled(signIn.activity != nil)
            if let devices = signIn.accountInfo?.devices, !devices.isEmpty {
                Section {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        LabeledContent {
                            Text(CloudAccountText.lastUsed(device.lastUsedAt) ?? "")
                        } label: {
                            Text(signIn.name(of: device) + (device.isCurrent && signIn.name(of: device) != "This iPad" ? " (this iPad)" : ""))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.device(index))
                    }
                } header: {
                    Text(CloudAccountText.devicesHeader)
                }
            }
            Section {
                Button("Sign Out…") { model.accountAlert = .signOut }
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.signOut)
                Button("Sign Out of All Devices…") { model.accountAlert = .signOutEverywhere }
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.signOutAll)
                Button("Delete Account…", role: .destructive) { model.accountAlert = .delete }
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.deleteAccount)
            } footer: {
                Text(CloudAccountText.accountFooter)
            }
            // A backup or restore under way finishes first.
            .disabled(signIn.activity != nil || environment.backupService.isBusy)
        }
    }
}

// MARK: - The offer

private struct CloudBackupOfferView: View {
    let model: CloudBackupScreenModel
    let scene: UIScene?
    let anchor: UIWindow?

    private var subscription: BackupSubscription { model.subscription }
    private var isSignedIn: Bool { model.signIn.isSignedIn }
    private let links = CloudBackupLinks.fromInfoDictionary()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label {
                        Text(CloudServiceError.serviceName)
                            .font(Typeface.title)
                    } icon: {
                        Image(systemName: "lock.icloud")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    .accessibilityAddTraits(.isHeader)
                    Text(CloudBackupOfferText.intro)
                }
                .padding(.vertical, Space.xs)
            }
            // Signing in, then the price and Subscribe, come first, where they can be seen
            // without scrolling. Subscribing needs an account to pay for.
            if isSignedIn {
                subscribeSection
            } else {
                CloudSignInSection(model: model, anchor: anchor)
            }
            Section {
                point(CloudBackupOfferText.encryptedTitle, CloudBackupOfferText.encrypted, image: "lock.shield")
                point(CloudBackupOfferText.recoveryKeyTitle, CloudBackupOfferText.recoveryKey, image: "key")
                point(CloudBackupOfferText.endingTitle, CloudBackupOfferText.ending, image: "calendar.badge.clock")
            }
            if isSignedIn {
                CloudAccountSection(model: model)
            }
            Section {
                if isSignedIn {
                    Button("Restore Purchases") { model.restorePurchases() }
                        .disabled(model.isRestoringPurchases || model.isPurchasing)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.restorePurchases)
                }
                if let terms = links.terms {
                    Link("Terms of Use", destination: terms)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.terms)
                }
                if let privacy = links.privacy {
                    Link("Privacy Policy", destination: privacy)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.privacy)
                }
            } footer: {
                Text(CloudBackupOfferText.renewalTerms)
            }
        }
        .accessibilityIdentifier(AccessibilityID.CloudBackup.offer)
    }

    private func point(_ title: String, _ text: String, image: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: image).foregroundStyle(.tint)
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .combine)
    }

    private var subscribeSection: some View {
        Section {
            if case .storeUnavailable(let reason) = model.account.status {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.offerUnavailable)
                Button("Try Again") { Task { await model.refresh() } }
            } else if subscription.products.isEmpty {
                Text(CloudBackupOfferText.noProducts)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.offerUnavailable)
            } else {
                ForEach(subscription.products) { product in
                    Button {
                        model.subscribe(product.id, scene: scene)
                    } label: {
                        HStack {
                            Spacer(minLength: 0)
                            if model.isPurchasing { ProgressView().padding(.trailing, Space.xs) }
                            Text(CloudBackupOfferText.subscribeTitle(product, isOnlyOne: subscription.products.count == 1))
                                .font(Typeface.control)
                                .multilineTextAlignment(.center)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isPurchasing || model.isRestoringPurchases)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.subscribe(product.id))
                }
            }
            if let notice = model.notice {
                Text(notice)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.notice)
            }
        }
    }
}

// MARK: - The status page

private struct CloudBackupStatusView: View {
    let model: CloudBackupScreenModel
    @Binding var restoreRequest: RestoreRequest?
    let scene: UIScene?

    @Environment(AppEnvironment.self) private var environment

    private var account: CloudBackupAccount { model.account }
    private var status: CloudBackupAccount.Status { account.status }
    private var capabilities: CloudBackupCapabilities { CloudBackupCapabilities.make(status) }
    private var service: BackupService { environment.backupService }

    var body: some View {
        Form {
            if let job = service.job {
                Section { BackupJobProgressView(job: job) }
            }
            if let banner = CloudBackupBanner.make(status, errorMessage: account.lastError?.localizedDescription,
                                                   usage: account.usage) {
                bannerSection(banner)
            }
            accountSection
            if CloudBackupRecoveryKeyLogic.showsKey(hasKey: account.hasKeyOnThisDevice, status: status) {
                recoveryKeySection
            }
            if capabilities.listsBackups {
                BackupDestinationBackUpSection(model: model.destination, canBackUp: capabilities.canBackUp,
                                               footer: CloudBackupStatusText.backUpRefusedFooter(status)
                                                   ?? CloudBackupStatusText.backUpFooter)
                BackupDestinationSnapshotsSection(model: model.destination, restoreRequest: $restoreRequest,
                                                  allowsDelete: capabilities.canDeleteBackups)
            }
            if capabilities.canDeleteEverything || model.isDeleting {
                deleteSection
            }
            CloudAccountSection(model: model)
            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(Typeface.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.notice)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.CloudBackup.status)
    }

    // MARK: Banner

    private func bannerSection(_ banner: CloudBackupBanner) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Space.xs) {
                Label {
                    Text(banner.title).font(.headline)
                } icon: {
                    Image(systemName: banner.systemImage)
                        .foregroundStyle(banner.tone == .problem ? Color.red : Color.orange)
                }
                Text(banner.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Space.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.CloudBackup.banner)
            ForEach(banner.actions, id: \.self) { action in
                bannerButton(action)
            }
        }
    }

    @ViewBuilder
    private func bannerButton(_ action: CloudBackupBanner.Action) -> some View {
        let title = CloudBackupBanner.title(of: action, status: status)
        switch action {
        case .tryAgain:
            Button(title) { Task { await model.refresh() } }
                .disabled(account.isRefreshing)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.bannerTryAgain)
        case .enterRecoveryKey:
            Button(title) { model.sheet = .enterRecoveryKey }
                .accessibilityIdentifier(AccessibilityID.CloudBackup.bannerEnterKey)
        case .resubscribe:
            Button(title) {
                if let id = model.resubscribeProductID { model.subscribe(id, scene: scene) }
            }
            .disabled(model.resubscribeProductID == nil || model.isPurchasing)
            .accessibilityIdentifier(AccessibilityID.CloudBackup.bannerResubscribe)
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            LabeledContent("Plan") {
                VStack(alignment: .trailing, spacing: Space.xxs) {
                    Text(CloudBackupStatusText.planName(account.plan))
                    if let product = account.plan?.product {
                        Text(CloudBackupStatusText.price(product))
                            .font(Typeface.caption)
                    }
                }
                .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plan")
            .accessibilityValue([CloudBackupStatusText.planName(account.plan),
                                 account.plan?.product.map(CloudBackupStatusText.price)].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier(AccessibilityID.CloudBackup.plan)
            if let renewal = CloudBackupStatusText.renewalLine(model.subscription.state) {
                Text(renewal)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.renewal)
            }
            if let usage = account.usage {
                VStack(alignment: .leading, spacing: Space.xs) {
                    LabeledContent("Storage", value: CloudBackupStatusText.usageLine(usage))
                    ProgressView(value: CloudBackupStatusText.usageFraction(usage))
                        .tint(usage.overAllowance ? Color.orange : nil)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.usage)
            }
            if capabilities.listsBackups {
                LabeledContent("Last Backup", value: model.destination.lastSuccess.map(BackupUIText.date) ?? "None yet")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.lastBackup)
            }
            Button("Manage Subscription…") { model.isManageSubscriptionsPresented = true }
                .accessibilityIdentifier(AccessibilityID.CloudBackup.manageSubscription)
        } header: {
            Text("Subscription")
        }
    }

    // MARK: Recovery key

    private var recoveryKeySection: some View {
        Section {
            if CloudBackupRecoveryKeyLogic.showsReminder(hasKey: account.hasKeyOnThisDevice, saved: account.recoveryKeySaved,
                                                         status: status) {
                Label {
                    Text(CloudBackupRecoveryKeyText.reminder)
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(Color.orange)
                }
                .accessibilityIdentifier(AccessibilityID.CloudBackup.keyReminder)
            }
            Button("Show Recovery Key…") { model.sheet = .recoveryKey(prompt: false) }
                .accessibilityIdentifier(AccessibilityID.CloudBackup.showKey)
        } header: {
            Text("Recovery Key")
        } footer: {
            Text("Backups are encrypted on this iPad. Your recovery key opens them if the key on your devices is ever lost.")
        }
    }

    // MARK: Delete

    private var deleteSection: some View {
        Section {
            if model.isDeleting {
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("Deleting your cloud backups…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.CloudBackup.deleting)
            } else {
                Button("Delete My Cloud Backups…", role: .destructive) { model.isDeleteConfirmationPresented = true }
                    .disabled(service.isBusy)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.deleteAll)
            }
        } footer: {
            Text(CloudBackupStatusText.deleteFooter)
        }
    }
}
