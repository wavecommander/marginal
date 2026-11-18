import ReaderSync
import SwiftUI

/// The Sync section of the Tactile Texts Cloud page (signed-in subscribers): the Sync switch,
/// the status line for every state with its button, Sync Now, and Download PDFs. Every window
/// shows the one `SyncController`, so the switch and the line are the same in each. Turning the
/// switch on runs the first round; when this device and the account both have books, the join
/// sheet asks first, and Not Now leaves the switch off.
struct SyncSectionView: View {
    let sync: SyncController
    /// The account's state, for why a pull-only session cannot send.
    let accountStatus: CloudBackupAccount.Status
    /// Opens the existing Enter Recovery Key flow.
    let enterRecoveryKey: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var joinPreview: SyncJoinPreview?
    @State private var isWorking = false

    private var service: SyncService { sync.service }
    private var settings: SyncSettings { sync.settings }

    private var line: SyncStatusLine {
        SyncStatusText.line(status: service.status, isOn: settings.isEnabled, lastSyncedAt: service.lastSyncedAt,
                            pullOnlyCause: SyncPullOnlyCause.from(accountStatus), now: Date())
    }

    var body: some View {
        Section {
            Toggle(String(localized: "Sync", comment: "Tactile Texts Cloud ▸ Sync: the switch."), isOn: switchBinding)
                .disabled(isWorking || settings.accountID == nil)
                .accessibilityIdentifier(AccessibilityID.Sync.toggle)
            statusRow
            if settings.isEnabled {
                if let action = line.action { actionButton(action) }
                Button(String(localized: "Sync Now", comment: "Tactile Texts Cloud ▸ Sync: runs a round now.")) {
                    Task { await sync.syncNow() }
                }
                .disabled(service.status == .syncing || environment.backupService.isBusy)
                .accessibilityIdentifier(AccessibilityID.Sync.syncNow)
            }
            Picker(String(localized: "Download PDFs", comment: "Tactile Texts Cloud ▸ Sync: when synced books' PDFs download."),
                   selection: policyBinding) {
                ForEach(SyncPDFPolicy.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier(AccessibilityID.Sync.pdfPolicy)
            #if DEBUG
            if environment.launchOptions.syncTestFolder != nil {
                // UI tests count rounds here (no network to watch).
                Text(verbatim: "Rounds: \(service.roundsStarted)")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Sync.debugRounds)
                    .accessibilityValue(String(service.roundsStarted))
            }
            #endif
        } header: {
            Text("Sync", comment: "Tactile Texts Cloud: the Sync section's header.")
        } footer: {
            Text("Sync keeps your books, notes, highlights, bookmarks and ink the same on every device signed in to this account. Like your backups, everything is encrypted on this device first.",
                 comment: "Tactile Texts Cloud ▸ Sync: the section's footer.")
        }
        .sheet(item: joinBinding) { preview in
            SyncJoinSheet(preview: preview.value, join: {
                joinPreview = nil
                Task { await sync.confirmJoin() }
            }, notNow: {
                joinPreview = nil
                Task { await sync.turnOff() }
            })
        }
    }

    private var statusRow: some View {
        Label {
            Text(line.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            if line.isBusy {
                ProgressView()
            } else {
                Image(systemName: line.systemImage)
                    .foregroundStyle(line.tone == .problem ? Color.red : line.tone == .waiting ? Color.orange : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Sync.status)
        .accessibilityValue(Self.statusValue(service.status, isOn: settings.isEnabled))
    }

    @ViewBuilder
    private func actionButton(_ action: SyncStatusLine.Action) -> some View {
        switch action {
        case .tryAgain:
            Button(String(localized: "Try Again", comment: "Sync status: runs a round again after a failure.")) {
                Task { await sync.syncNow() }
            }
            .accessibilityIdentifier(AccessibilityID.Sync.statusAction)
        case .enterRecoveryKey:
            Button(String(localized: "Enter Recovery Key…", comment: "Sync status: opens Enter Recovery Key."), action: enterRecoveryKey)
                .accessibilityIdentifier(AccessibilityID.Sync.statusAction)
        case .reviewJoin:
            Button(String(localized: "Review…", comment: "Sync status: shows the join sheet again.")) {
                Task { await askToJoin() }
            }
            .accessibilityIdentifier(AccessibilityID.Sync.statusAction)
        }
    }

    // MARK: The switch

    private var switchBinding: Binding<Bool> {
        Binding(get: { settings.isEnabled }, set: { on in
            guard on != settings.isEnabled else { return }
            isWorking = true
            Task {
                defer { isWorking = false }
                if on {
                    if case .needsJoinConfirmation(let preview) = await sync.turnOn() { joinPreview = preview }
                } else {
                    joinPreview = nil
                    await sync.turnOff()
                }
            }
        })
    }

    private func askToJoin() async {
        if case .needsJoinConfirmation(let preview) = await sync.joinOrPreview() { joinPreview = preview }
    }

    private var policyBinding: Binding<SyncPDFPolicy> {
        Binding(get: { settings.pdfPolicy }, set: { policy in
            settings.pdfPolicy = policy
            sync.pdfPolicyChanged()
        })
    }

    /// The sheet's item: swiping it away counts as Not Now.
    private var joinBinding: Binding<IdentifiedPreview?> {
        Binding(get: { joinPreview.map(IdentifiedPreview.init) }, set: { value in
            if value == nil, joinPreview != nil {
                joinPreview = nil
                Task { await sync.turnOff() }
            }
        })
    }

    private struct IdentifiedPreview: Identifiable {
        let value: SyncJoinPreview
        var id: String { "\(value.onlyHere)-\(value.onlyInAccount)-\(value.inBoth)" }
    }

    /// The status line's accessibility value: a stable word per state, for UI tests.
    nonisolated static func statusValue(_ status: SyncStatus, isOn: Bool) -> String {
        guard isOn else { return "off" }
        switch status {
        case .idle: return "idle"
        case .syncing: return "syncing"
        case .upToDate: return "upToDate"
        case .waiting(let reason): return "waiting.\(reason)"
        case .needsJoinConfirmation: return "needsJoin"
        case .needsKey: return "needsKey"
        case .failed: return "failed"
        }
    }
}

/// Before this device first syncs with an account that has books, while it has books too: how
/// many books are only here, only in the account, and on both; that books on both are merged and
/// nothing is removed from either side. Join, or Not Now (the switch stays off).
struct SyncJoinSheet: View {
    let preview: SyncJoinPreview
    let join: () -> Void
    let notNow: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    count(SyncJoinLogic.onlyHereLabel, preview.onlyHere, id: AccessibilityID.Sync.joinOnlyHere)
                    count(SyncJoinLogic.onlyInAccountLabel, preview.onlyInAccount, id: AccessibilityID.Sync.joinOnlyInAccount)
                    count(SyncJoinLogic.inBothLabel, preview.inBoth, id: AccessibilityID.Sync.joinInBoth)
                } header: {
                    Text("Books", comment: "Join sheet: the counts' header.")
                } footer: {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(SyncJoinLogic.explanation)
                        Text(SyncJoinLogic.pdfNote)
                    }
                }
                Section {
                    Button(action: join) {
                        Text(SyncJoinLogic.joinButton).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier(AccessibilityID.Sync.joinConfirm)
                }
            }
            .navigationTitle(SyncJoinLogic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SyncJoinLogic.notNowButton, action: notNow)
                        .accessibilityIdentifier(AccessibilityID.Sync.joinNotNow)
                }
            }
        }
    }

    private func count(_ label: String, _ value: Int, id: String) -> some View {
        LabeledContent(label, value: value.formatted(.number))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
            .accessibilityValue(String(value))
    }
}
