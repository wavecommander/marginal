import Observation
import ReaderBackup
import SwiftUI
import UniformTypeIdentifiers

/// One destination's state: availability, its backups, the last result, and the error to show.
@Observable
@MainActor
final class BackupDestinationModel {
    enum Snapshots {
        case loading
        case loaded([BackupSnapshotInfo])
        /// Not listed: the destination can't be used, or listing failed (`message`).
        case unavailable(String)
    }

    let entryID: String
    private(set) var availability: BackupDestinationAvailability?
    private(set) var snapshots: Snapshots = .loading
    private(set) var resultLine: String?
    var failure: BackupFailure?
    var pendingDelete: BackupSnapshotInfo?
    /// Bumped after the folder changes (the live name and state are re-read).
    private(set) var revision = 0

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private weak var screenModel: BackupScreenModel?

    init(entryID: String, environment: AppEnvironment, screenModel: BackupScreenModel?) {
        self.entryID = entryID
        self.environment = environment
        self.screenModel = screenModel
    }

    var destination: (any BackupDestination)? { environment.backupDestinations.destination(id: entryID) }
    var kind: BackupDestinationKind { BackupDestinationKind(id: entryID) }
    var service: BackupService { environment.backupService }

    var name: String {
        _ = revision
        return destination?.displayName ?? "Destination"
    }

    var lastSuccess: Date? {
        _ = revision
        return service.lastSuccessfulBackup(destinationID: entryID)
    }

    var hasFolder: Bool {
        _ = revision
        return environment.backupFolderStore.hasFolder
    }

    // MARK: Refreshing

    func refresh() async {
        guard let destination else { return }
        revision += 1
        let value = await destination.availability()
        availability = value
        screenModel?.update(entryID, availability: value)
        guard value.isAvailable else {
            if case .unavailable(let reason) = value { snapshots = .unavailable(reason) }
            return
        }
        do {
            snapshots = .loaded(try await destination.listSnapshots().sorted(by: BackupSnapshotInfo.newestFirst))
        } catch {
            if let failure = BackupFailure.from(error, title: "Couldn’t List the Backups") {
                snapshots = .unavailable(failure.message)
            }
        }
    }

    // MARK: Actions

    func backUpNow(includePDFs: Bool) {
        guard let destination else { return }
        guard !service.isBusy else {
            failure = BackupFailure.from(BackupServiceError.busy, title: "Couldn’t Back Up")
            return
        }
        resultLine = nil
        let name = name
        Task {
            do {
                let result = try await service.backUp(to: destination, includePDFs: includePDFs)
                resultLine = [BackupUIText.destinationBackupDone(result, destinationName: name),
                              BackupUIText.skippedLine(result.skippedBookTitles)].compactMap { $0 }.joined(separator: " ")
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Back Up")
            }
            await refresh()
        }
    }

    func delete(_ snapshot: BackupSnapshotInfo) {
        guard let destination else { return }
        Task {
            do {
                try await destination.deleteSnapshot(snapshot)
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Delete the Backup")
            }
            await refresh()
        }
    }

    func chooseFolder(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try environment.backupFolderStore.setFolder(url)
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Use This Folder")
            }
        case .failure(let error):
            failure = BackupFailure.from(error, title: "Couldn’t Use This Folder")
        }
        Task { await refresh() }
    }
}

/// A destination: its status, Back Up Now (with its own Include PDFs), the backups there (each
/// opens the restore preview, or is deleted after a confirmation), and what only this
/// destination needs (the folder's Choose Folder…).
struct BackupDestinationScreen: View {
    let entryID: String
    let screenModel: BackupScreenModel?

    @Environment(AppEnvironment.self) private var environment
    @State private var model: BackupDestinationModel?

    var body: some View {
        Group {
            if let model {
                BackupDestinationContent(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = BackupDestinationModel(entryID: entryID, environment: environment, screenModel: screenModel) }
        }
    }
}

private struct BackupDestinationContent: View {
    @Bindable var model: BackupDestinationModel

    @Environment(AppEnvironment.self) private var environment
    @State private var isFolderPickerPresented = false
    @State private var restoreRequest: RestoreRequest?

    init(model: BackupDestinationModel) {
        self.model = model
    }

    private var service: BackupService { environment.backupService }
    private var isAvailable: Bool { model.availability?.isAvailable == true }

    var body: some View {
        Form {
            if let job = service.job {
                Section { BackupJobProgressView(job: job) }
            }
            statusSection
            if model.kind.showsFolderControls { folderSection }
            BackupDestinationBackUpSection(model: model, canBackUp: isAvailable, footer: BackupUIText.retention)
            BackupDestinationSnapshotsSection(model: model, restoreRequest: $restoreRequest)
        }
        .settingsPageMargins()
        .navigationTitle(model.name)
        .accessibilityIdentifier(AccessibilityID.Backup.destinationScreen)
        .toolbar { BackupDoneToolbarItem() }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .fileImporter(isPresented: $isFolderPickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
            model.chooseFolder($0)
        }
        .sheet(item: $restoreRequest, onDismiss: { Task { await model.refresh() } }) { RestoreFlowView(request: $0) }
        .backupFailureAlert($model.failure)
        .backupSnapshotDeleteAlert(model)
    }

    private var statusSection: some View {
        Section {
            Label {
                Text(BackupUIText.destinationStatus(availability: model.availability, lastSuccess: model.lastSuccess))
            } icon: {
                Image(systemName: isAvailable ? "checkmark.circle" : model.availability == nil ? "clock" : "exclamationmark.circle")
                    .foregroundStyle(isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Backup.destinationStatus)
        }
    }

    /// The folder's name is the screen's title, so the section holds only the button.
    private var folderSection: some View {
        Section {
            Button(model.hasFolder ? "Choose Another Folder…" : "Choose Folder…") { isFolderPickerPresented = true }
                .disabled(service.isBusy)
                .accessibilityIdentifier(AccessibilityID.Backup.chooseFolder)
        } header: {
            Text("Folder")
        } footer: {
            Text(BackupUIText.folderFooter)
                .accessibilityIdentifier(AccessibilityID.Backup.folderFooter)
        }
    }
}

// MARK: - Parts shared with Tactile Texts Cloud's screen

/// Back Up Now with the shared Include PDFs switch and the last result.
struct BackupDestinationBackUpSection: View {
    let model: BackupDestinationModel
    /// Back Up Now is enabled (and nothing else is running).
    let canBackUp: Bool
    let footer: String

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // The same Include PDFs choice as the backup-file switch and the automatic one.
        @Bindable var settings = environment.backupAutomaticSettings
        Section {
            Toggle("Include PDFs", isOn: $settings.includesPDFs)
                .accessibilityIdentifier(AccessibilityID.Backup.destinationIncludePDFs)
            Button("Back Up Now") { model.backUpNow(includePDFs: settings.includesPDFs) }
                .disabled(!canBackUp || environment.backupService.isBusy)
                .accessibilityIdentifier(AccessibilityID.Backup.backUpNow)
            if let result = model.resultLine {
                Text(result)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Backup.destinationResult)
            }
        } header: {
            Text("Back Up")
        } footer: {
            Text(footer)
        }
    }
}

/// The backups at a destination: each opens the restore preview, or is deleted after a
/// confirmation (`backupSnapshotDeleteAlert`).
struct BackupDestinationSnapshotsSection: View {
    let model: BackupDestinationModel
    @Binding var restoreRequest: RestoreRequest?
    /// Offer Delete on each backup (not while a cloud subscription only allows restoring).
    var allowsDelete = true

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Section {
            switch model.snapshots {
            case .loading:
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("Looking for backups…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Backup.snapshotsLoading)
            case .unavailable(let message):
                Text(message)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let snapshots) where snapshots.isEmpty:
                Text("No backups here yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Backup.snapshotsEmpty)
            case .loaded(let snapshots):
                ForEach(snapshots) { snapshot in
                    row(snapshot)
                }
            }
        } header: {
            Text("Backups Here")
        }
    }

    private func row(_ snapshot: BackupSnapshotInfo) -> some View {
        Button {
            guard let destination = model.destination else { return }
            restoreRequest = RestoreRequest(source: .snapshot(snapshot, destination: destination))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(BackupUIText.snapshotTitle(snapshot))
                        .foregroundStyle(Palette.ink)
                    Text(BackupUIText.snapshotDetail(snapshot))
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .disabled(environment.backupService.isBusy)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows what this backup holds before restoring")
        .accessibilityIdentifier(AccessibilityID.Backup.snapshot(snapshot.name))
        .swipeActions {
            if allowsDelete {
                Button("Delete", role: .destructive) { model.pendingDelete = snapshot }
            }
        }
        .contextMenu {
            Button("Restore…", systemImage: "arrow.counterclockwise") {
                guard let destination = model.destination else { return }
                restoreRequest = RestoreRequest(source: .snapshot(snapshot, destination: destination))
            }
            if allowsDelete {
                Button("Delete…", systemImage: "trash", role: .destructive) { model.pendingDelete = snapshot }
            }
        }
        .accessibilityActions {
            if allowsDelete {
                Button("Delete") { model.pendingDelete = snapshot }
            }
        }
    }
}

extension View {
    /// The confirmation before deleting one backup (`BackupDestinationModel.pendingDelete`).
    func backupSnapshotDeleteAlert(_ model: BackupDestinationModel) -> some View {
        @Bindable var model = model
        return alert("Delete This Backup?",
                     isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
                     presenting: model.pendingDelete) { snapshot in
            Button("Delete", role: .destructive) { model.delete(snapshot) }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            Text("The backup from \(BackupUIText.date(snapshot.createdAt)) will be deleted from \(model.name). PDFs stored with the backups are kept.")
        }
    }
}
