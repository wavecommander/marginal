import ReaderBackup
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Backup & Restore: back up to a file, the destinations (each opens its own screen
/// with Back Up Now and its backups), automatic backup, and restore from a file. The app's one
/// running backup or restore shows here in place, and every start button waits for it.
struct BackupScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: BackupScreenModel?

    var body: some View {
        Group {
            if let model {
                BackupScreenContent(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if model == nil { model = BackupScreenModel(environment: environment) } }
    }
}

/// The Done button of every Backup page: closes Settings.
struct BackupDoneToolbarItem: ToolbarContent {
    @Environment(\.closeSettings) private var closeSettings

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if let closeSettings {
                Button("Done") { closeSettings() }
                    .accessibilityIdentifier(AccessibilityID.Backup.done)
            }
        }
    }
}

private struct BackupScreenContent: View {
    @Bindable var model: BackupScreenModel

    @Environment(AppEnvironment.self) private var environment
    @State private var isRestoreImporterPresented = false
    @State private var restoreRequest: RestoreRequest?

    private var service: BackupService { environment.backupService }

    var body: some View {
        Form {
            if let job = service.job {
                Section { BackupJobProgressView(job: job) }
            }
            fileSection
            destinationsSection
            AutomaticBackupSection(model: model)
            restoreSection
            Section {} footer: {
                Text(BackupUIText.footnote(hasEncryptedDestination: environment.cloudBackup != nil))
                    .accessibilityIdentifier(AccessibilityID.Backup.footnote)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Backup.screen)
        .toolbar { BackupDoneToolbarItem() }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .onChange(of: service.isBusy) { _, busy in
            if !busy { Task { await model.refresh() } }
        }
        .fileMover(isPresented: $model.isMoverPresented, file: model.pendingFile?.url,
                   onCompletion: model.moverCompleted, onCancellation: model.moverCancelled)
        // On its own view: one document-picker modifier per view (SwiftUI may honour only one).
        .background {
            Color.clear
                .fileImporter(isPresented: $isRestoreImporterPresented, allowedContentTypes: [.tactileTextsBackup],
                              allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { restoreRequest = RestoreRequest(source: .file(url, consume: false)) }
                    case .failure(let error):
                        model.failure = BackupFailure.from(error, title: "Couldn’t Open the File")
                    }
                }
        }
        .sheet(item: $restoreRequest) { RestoreFlowView(request: $0) }
        .backupFailureAlert($model.failure)
    }

    private var fileSection: some View {
        // The same Include PDFs choice as every destination's switch and the automatic one.
        @Bindable var settings = environment.backupAutomaticSettings
        return Section {
            Toggle("Include PDFs", isOn: $settings.includesPDFs)
                .accessibilityIdentifier(AccessibilityID.Backup.fileIncludePDFs)
            Text(model.estimate.map(BackupUIText.estimateLine) ?? "Working out the size…")
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Backup.fileEstimate)
            Button("Save Backup File…") { model.saveBackupFile(includePDFs: settings.includesPDFs) }
                .disabled(service.isBusy)
                .accessibilityIdentifier(AccessibilityID.Backup.saveFile)
            if let status = model.fileStatus {
                Text(status)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Backup.fileStatus)
            }
        } header: {
            Text("Back Up to a File")
        } footer: {
            Text("Makes one backup file and lets you choose where it goes: On My iPad, iCloud Drive, another app’s storage, or a drive.")
        }
    }

    private var destinationsSection: some View {
        Section("Destinations") {
            ForEach(model.entries) { entry in
                NavigationLink {
                    if entry.id == TactileCloudBackupDestination.destinationID, let cloud = environment.cloudBackup {
                        // Its own screen: the offer, the subscription, the recovery key.
                        CloudBackupScreen(cloud: cloud, screenModel: model)
                    } else {
                        BackupDestinationScreen(entryID: entry.id, screenModel: model)
                    }
                } label: {
                    DestinationRow(name: model.name(of: entry), kind: BackupDestinationKind(id: entry.id),
                                   status: BackupUIText.destinationStatus(availability: model.availability[entry.id],
                                                                          lastSuccess: model.lastSuccess(entry.id)),
                                   isAvailable: model.availability[entry.id]?.isAvailable ?? true)
                }
                .accessibilityIdentifier(AccessibilityID.Backup.destination(entry.id))
            }
        }
    }

    private var restoreSection: some View {
        Section {
            Button("Restore from File…") { isRestoreImporterPresented = true }
                .disabled(service.isBusy)
                .accessibilityIdentifier(AccessibilityID.Backup.restoreFromFile)
        } header: {
            Text("Restore")
        } footer: {
            Text("To restore from a destination, open it above and choose one of its backups. You see what a backup holds before anything is restored.")
        }
    }
}

/// A destination in the list: icon, live name and status (the reason it can't be used, or its
/// last successful backup).
private struct DestinationRow: View {
    let name: String
    let kind: BackupDestinationKind
    let status: String
    let isAvailable: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(name)
                Text(status)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: kind.systemImage)
                .foregroundStyle(isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AutomaticBackupSection: View {
    let model: BackupScreenModel

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = environment.backupAutomaticSettings
        let entries = model.entries.map { AutomaticBackupLogic.Choice(id: $0.id, name: model.name(of: $0)) }
        let choices = AutomaticBackupLogic.choices(entries, availability: model.availability)
        let current = settings.destinationID.flatMap { id in entries.first { $0.id == id } }
        Section {
            Toggle("Back Up Automatically", isOn: Binding(get: { settings.isEnabled }, set: { on in
                settings.isEnabled = on
                if on { settings.destinationID = AutomaticBackupLogic.destination(current: settings.destinationID, choices: choices) }
            }))
            .disabled(!settings.isEnabled && choices.isEmpty)
            .accessibilityIdentifier(AccessibilityID.Backup.automaticToggle)
            if settings.isEnabled {
                Picker("Back Up To", selection: Binding(get: { settings.destinationID ?? "" },
                                                        set: { settings.destinationID = $0.isEmpty ? nil : $0 })) {
                    if current == nil { Text("Choose…").tag("") }
                    // The chosen destination stays listed while it is unavailable, so the
                    // picker never shows a blank; every other choice is available now.
                    if let current, !choices.contains(current) {
                        Text("\(current.name) (unavailable)").tag(current.id)
                    }
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier(AccessibilityID.Backup.automaticDestination)
                Toggle("Include PDFs", isOn: $settings.includesPDFs)
                    .accessibilityIdentifier(AccessibilityID.Backup.automaticIncludePDFs)
            }
            Text(AutomaticBackupLogic.statusLine(
                isEnabled: settings.isEnabled, destinationName: current?.name,
                availability: current.flatMap { model.availability[$0.id] },
                lastSuccess: current.flatMap { model.lastSuccess($0.id) },
                lastFailureMessage: settings.lastFailureMessage))
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Backup.automaticStatus)
        } header: {
            Text("Automatic Backup")
        } footer: {
            Text(choices.isEmpty && !settings.isEnabled
                 ? AutomaticBackupLogic.footer + " Set up a destination above first."
                 : AutomaticBackupLogic.footer)
        }
    }
}

// MARK: - Alerts

extension View {
    /// Shows a backup failure with its own message; "Sign In…" opens the Google sign-in when it
    /// would fix it.
    func backupFailureAlert(_ failure: Binding<BackupFailure?>, signIn: (() -> Void)? = nil) -> some View {
        alert(failure.wrappedValue?.title ?? "", isPresented: Binding(get: { failure.wrappedValue != nil },
                                                                      set: { if !$0 { failure.wrappedValue = nil } }),
              presenting: failure.wrappedValue) { value in
            if value.offersSignIn, let signIn {
                Button("Sign In…", action: signIn)
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { value in
            Text(value.message)
        }
    }
}
